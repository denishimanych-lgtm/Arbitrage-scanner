# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Periodic job to monitor stablecoin prices for depegging
    class StablecoinMonitorJob
      REDIS_LAST_RUN_KEY = 'stablecoin:last_run'
      REDIS_STATS_KEY = 'stablecoin:stats'

      DEFAULT_INTERVAL_SECONDS = 30  # 30 seconds

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @monitor = Services::Stablecoin::DepegMonitor.new
        @alerter = Services::Stablecoin::DepegAlerter.new(settings)
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

        # Update stats
        update_stats(prices, alerts)

        {
          prices_count: prices.size,
          depegged_count: depegged.size,
          alerts_count: alerts.size,
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

      def update_stats(prices, alerts)
        redis = ArbitrageBot.redis
        redis.hincrby(REDIS_STATS_KEY, 'checks', 1)
        redis.hincrby(REDIS_STATS_KEY, 'alerts', alerts.size)

        depegged = prices.count { |p| @monitor.depegged?(p[:price]) }
        redis.hincrby(REDIS_STATS_KEY, 'depegs', depegged) if depegged > 0

        redis.hset(REDIS_STATS_KEY, 'last_prices_count', prices.size)
      end

      def log(message)
        @logger.info("[StablecoinMonitorJob] #{message}")
      end
    end
  end
end
