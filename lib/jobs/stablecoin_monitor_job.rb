# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Periodic job to monitor stablecoin prices for depegging
    class StablecoinMonitorJob
      REDIS_LAST_RUN_KEY = 'stablecoin:last_run'
      REDIS_STATS_KEY = 'stablecoin:stats'
      CURVE_STRESS_COOLDOWN_KEY = 'curve:stress_cooldown:'

      DEFAULT_INTERVAL_SECONDS = 30  # 30 seconds
      CURVE_STRESS_THRESHOLD = 70    # >70% of one asset = stress
      CURVE_CRITICAL_THRESHOLD = 80  # >80% = critical
      CURVE_COOLDOWN_SECONDS = 1800  # 30 min between stress alerts

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @monitor = Services::Stablecoin::DepegMonitor.new
        @alerter = Services::Stablecoin::DepegAlerter.new(settings)
        @notifier = Services::Telegram::TelegramNotifier.new
        @interval = settings[:stablecoin_interval_seconds] || DEFAULT_INTERVAL_SECONDS
        @running = false
      end

      # Run once
      def perform
        log('Checking stablecoin prices...')

        prices = @monitor.fetch_all
        log("Fetched #{prices.size} stablecoin prices")

        # Check for depegs and alert
        depegged = prices.select { |p| @monitor.depegged?(p[:price]) }
        if depegged.any?
          log("Found #{depegged.size} depegged stablecoins: #{depegged.map { |p| p[:symbol] }.join(', ')}")
        end

        alerts = @alerter.check_and_alert(prices)
        log("Generated #{alerts.size} alerts") if alerts.any?

        # Check Curve 3pool stress (early warning)
        curve_alerts = check_curve_stress
        alerts.concat(curve_alerts)

        # Update stats
        update_stats(prices, alerts)

        {
          prices_count: prices.size,
          depegged_count: depegged.size,
          alerts_count: alerts.size,
          curve_stress: curve_alerts.any?,
          checked_at: Time.now
        }
      rescue StandardError => e
        @logger.error("[StablecoinMonitorJob] perform error: #{e.message}")
        @logger.error(e.backtrace.first(5).join("\n"))
        nil
      end

      # Run continuously
      def run_loop
        @running = true
        log("Starting stablecoin monitor loop (interval: #{@interval}s)")

        while @running
          begin
            perform
            ArbitrageBot.redis.set(REDIS_LAST_RUN_KEY, Time.now.to_i)
            sleep @interval
          rescue StandardError => e
            @logger.error("[StablecoinMonitorJob] loop error: #{e.message}")
            sleep 10
          end
        end
      end

      def stop
        @running = false
      end

      # Get current prices from cache
      def current_prices
        @monitor.current_prices
      end

      # Get stats
      def stats
        stored = ArbitrageBot.redis.hgetall(REDIS_STATS_KEY)
        last_run = ArbitrageBot.redis.get(REDIS_LAST_RUN_KEY)

        {
          total_checks: stored['checks'].to_i,
          total_alerts: stored['alerts'].to_i,
          total_depegs: stored['depegs'].to_i,
          last_run: last_run ? Time.at(last_run.to_i) : nil,
          interval_seconds: @interval,
          stablecoins: Services::Stablecoin::DepegMonitor::STABLECOINS
        }
      end

      # Format prices for Telegram /stables command
      def format_for_telegram
        prices = current_prices
        prices = @monitor.fetch_all if prices.empty?
        @alerter.format_prices_message(prices)
      end

      private

      # Check Curve 3pool for stress (>70% imbalance)
      # This is an early warning before actual depeg
      def check_curve_stress
        alerts = []

        pool = Adapters::Defi::CurveAdapter.get_3pool
        return alerts unless pool && pool[:balances]

        pool[:balances].each do |token, data|
          pct = data[:pct]
          next unless pct

          is_critical = pct >= CURVE_CRITICAL_THRESHOLD
          is_stressed = pct >= CURVE_STRESS_THRESHOLD

          next unless is_stressed
          next if curve_on_cooldown?(token)

          alert = create_curve_stress_alert(token, pct, pool, is_critical)
          if alert && send_curve_alert(alert)
            alerts << alert
            set_curve_cooldown(token)
          end
        end

        alerts
      rescue StandardError => e
        @logger.error("[StablecoinMonitorJob] check_curve_stress error: #{e.message}")
        []
      end

      def create_curve_stress_alert(token, pct, pool, is_critical)
        emoji = is_critical ? "🚨🚨" : "⚠️"
        severity = is_critical ? "CRITICAL" : "WARNING"
        tvl_m = pool[:tvl] ? (pool[:tvl] / 1_000_000).round(1) : 0

        # Format all balances
        balance_lines = pool[:balances].map do |t, d|
          marker = t == token ? " ← STRESS!" : ""
          "   #{t}: #{d[:pct]&.round(1)}%#{marker}"
        end.join("\n")

        # Get current price for the stressed token
        prices = @monitor.current_prices
        stressed_price = prices.find { |p| p[:symbol] == token }
        price_str = stressed_price ? "$#{stressed_price[:price].round(4)}" : "N/A"

        message = <<~MSG
          #{emoji} CURVE 3POOL #{severity} | #{token}
          ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

          ⚠️ POOL IMBALANCE DETECTED

          📊 3POOL COMPOSITION:
          #{balance_lines}

             TVL: $#{tvl_m}M
             #{token}: #{pct.round(1)}% (threshold: #{CURVE_STRESS_THRESHOLD}%)

          💰 #{token} PRICE: #{price_str}

          🔮 ЗНАЧЕНИЕ:
          • Высокая доля #{token} = давление на продажу
          • Участники меняют #{token} на другие стейблы
          • Возможный ранний сигнал депега

          📝 РЕКОМЕНДАЦИЯ:
          • Следить за ценой #{token}
          • Готовиться к возможному депегу
          • #{is_critical ? 'СРОЧНО проверить позиции!' : 'Мониторить ситуацию'}

          ⏰ Следующий чек: #{@interval}s
        MSG

        {
          type: is_critical ? :curve_critical : :curve_stress,
          token: token,
          pct: pct,
          tvl: pool[:tvl],
          pool_data: pool[:balances],
          message: message.strip
        }
      end

      def send_curve_alert(alert)
        # Create signal in database
        db_signal = Services::Analytics::SignalRepository.create(
          strategy: 'curve_stress',
          class: 'speculative',
          symbol: alert[:token],
          details: alert.except(:message)
        )

        signal_id = db_signal ? Services::Analytics::SignalRepository.short_id(db_signal[:id], 'curve_stress') : nil
        message = alert[:message]
        message = "#{message}\n\nID: `#{signal_id}`" if signal_id

        @notifier.send_alert(message)
      rescue StandardError => e
        @logger.error("[StablecoinMonitorJob] send_curve_alert error: #{e.message}")
        nil
      end

      def curve_on_cooldown?(token)
        key = "#{CURVE_STRESS_COOLDOWN_KEY}#{token}"
        ArbitrageBot.redis.exists?(key)
      rescue StandardError
        false
      end

      def set_curve_cooldown(token)
        key = "#{CURVE_STRESS_COOLDOWN_KEY}#{token}"
        ArbitrageBot.redis.setex(key, CURVE_COOLDOWN_SECONDS, '1')
      rescue StandardError => e
        @logger.error("[StablecoinMonitorJob] set_curve_cooldown error: #{e.message}")
      end

      def update_stats(prices, alerts)
        redis = ArbitrageBot.redis
        redis.hincrby(REDIS_STATS_KEY, 'checks', 1)
        redis.hincrby(REDIS_STATS_KEY, 'alerts', alerts.size)

        depegged = prices.count { |p| @monitor.depegged?(p[:price]) }
        redis.hincrby(REDIS_STATS_KEY, 'depegs', depegged) if depegged > 0

        curve_alerts = alerts.count { |a| a[:type].to_s.start_with?('curve') }
        redis.hincrby(REDIS_STATS_KEY, 'curve_stress', curve_alerts) if curve_alerts > 0

        redis.hset(REDIS_STATS_KEY, 'last_prices_count', prices.size)
      end

      def log(message)
        @logger.info("[StablecoinMonitorJob] #{message}")
      end
    end
  end
end
