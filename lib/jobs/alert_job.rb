# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class AlertJob
      SIGNAL_QUEUE_KEY = 'signals:pending'
      PROCESSED_KEY = 'alerts:processed'
      STATS_KEY = 'alerts:stats'

      attr_reader :logger, :redis, :settings

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @redis = ArbitrageBot.redis
        @settings_loader = Services::SettingsLoader.new
        @settings = @settings_loader.load

        # Initialize components
        @signal_builder = Services::Safety::SignalBuilder.new(
          liquidity: @settings_loader.for_component(:liquidity),
          lagging: @settings_loader.for_component(:lagging)
        )

        @formatter = Services::Alerts::AlertFormatter.new(
          @settings_loader.for_component(:alerts)
        )

        @notifier = Services::Telegram::TelegramNotifier.new

        @cooldown = Services::Alerts::CooldownManager.new(
          default_cooldown: @settings[:alert_cooldown_seconds]
        )

        @blacklist = Services::Alerts::Blacklist.new

        log('AlertJob initialized')
      end

      # Process single signal from queue
      def perform(signal_data)
        raw_signal = signal_data.is_a?(String) ? JSON.parse(signal_data) : signal_data
        symbol = raw_signal['symbol'] || raw_signal[:symbol]

        log("Processing signal: #{symbol}")

        # 1. Check blacklist
        if @blacklist.blocked?(raw_signal)
          log("  Blocked by blacklist: #{symbol}")
          record_stat(:blacklist_blocked)
          log_rejected_signal(raw_signal, 'blacklisted')
          return nil
        end

        # 2. Check cooldown
        unless @cooldown.can_alert?(symbol, pair_id: raw_signal['pair_id'])
          remaining = @cooldown.remaining_cooldown(symbol, pair_id: raw_signal['pair_id'])
          log("  On cooldown: #{symbol} (#{remaining}s remaining)")
          @cooldown.record_blocked
          record_stat(:cooldown_blocked)
          log_rejected_signal(raw_signal, 'cooldown')
          return nil
        end

        # 3. Build validated signal
        validated_signal = @signal_builder.build(raw_signal)

        # 4. Check signal type settings
        unless signal_type_enabled?(validated_signal.signal_type)
          log("  Signal type disabled: #{validated_signal.signal_type}")
          record_stat(:type_disabled)
          log_rejected_signal(raw_signal, "signal_type_disabled:#{validated_signal.signal_type}", validated_signal)
          return nil
        end

        # 5. Check if passed safety checks
        unless validated_signal.status == :valid || validated_signal.signal_type == :lagging
          rejection_reason = validated_signal.safety_checks[:messages]&.first || 'safety_check_failed'
          log("  Failed safety checks: #{validated_signal.safety_checks[:messages]&.join(', ')}")
          record_stat(:safety_failed)
          log_rejected_signal(raw_signal, rejection_reason, validated_signal)
          return nil
        end

        # 6. Check minimum spread
        if validated_signal.spread[:real_pct] < @settings[:min_spread_pct]
          log("  Spread too low: #{validated_signal.spread[:real_pct]}% < #{@settings[:min_spread_pct]}%")
          record_stat(:spread_too_low)
          log_rejected_signal(raw_signal, "spread_too_low:#{validated_signal.spread[:real_pct]}%", validated_signal)
          return nil
        end

        # 7. Create signal in PostgreSQL
        db_signal = create_db_signal(validated_signal, raw_signal)
        strategy = infer_strategy(validated_signal, raw_signal)
        signal_id = db_signal ? Services::Analytics::SignalRepository.short_id(db_signal[:id], strategy) : nil

        # 8. Format alert (with signal ID)
        formatted_message = @formatter.format(validated_signal)
        formatted_message = append_signal_id(formatted_message, signal_id) if signal_id

        # 9. Send to Telegram
        result = @notifier.send_alert(formatted_message)

        if result
          # 10. Update signal with telegram message ID
          if db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Services::Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          # 11. Log spread to PostgreSQL
          log_spread_to_db(validated_signal, raw_signal, db_signal)

          # 12. Set cooldown
          cooldown_duration = validated_signal.signal_type == :lagging ?
            @settings[:lagging_alert_cooldown_seconds] :
            @settings[:alert_cooldown_seconds]

          @cooldown.set_cooldown(symbol, pair_id: raw_signal['pair_id'], seconds: cooldown_duration)

          # 13. Record success
          record_processed(validated_signal)
          record_stat(:alerts_sent)

          log("  Alert sent: #{signal_id || validated_signal.id} (#{validated_signal.signal_type})")

          validated_signal
        else
          log('  Failed to send alert')
          record_stat(:send_failed)
          nil
        end
      end

      # Process queue continuously
      def run_loop
        log('Starting alert job loop')

        loop do
          begin
            # Pop from queue (blocking with timeout)
            _, data = @redis.brpop(SIGNAL_QUEUE_KEY, timeout: 5)

            if data
              perform(data)
            end
          rescue StandardError => e
            @logger.error("Alert job error: #{e.message}")
            @logger.error(e.backtrace.first(5).join("\n"))
            sleep 1
          end
        end
      end

      # Get current statistics
      def stats
        stored = @redis.hgetall(STATS_KEY)
        processed_today = @redis.zcount(
          PROCESSED_KEY,
          Time.now.to_i - 86_400,
          Time.now.to_i
        )

        {
          alerts_sent: stored['alerts_sent'].to_i,
          blacklist_blocked: stored['blacklist_blocked'].to_i,
          cooldown_blocked: stored['cooldown_blocked'].to_i,
          safety_failed: stored['safety_failed'].to_i,
          spread_too_low: stored['spread_too_low'].to_i,
          type_disabled: stored['type_disabled'].to_i,
          send_failed: stored['send_failed'].to_i,
          processed_24h: processed_today,
          queue_size: @redis.llen(SIGNAL_QUEUE_KEY)
        }
      end

      # Get recent alerts
      def recent_alerts(limit: 20)
        @redis.zrevrange(PROCESSED_KEY, 0, limit - 1, with_scores: true).map do |data, score|
          alert = JSON.parse(data)
          alert['sent_at'] = Time.at(score.to_i)
          alert
        end
      end

      # Reload settings
      def reload_settings
        @settings = @settings_loader.load
        @cooldown = Services::Alerts::CooldownManager.new(
          default_cooldown: @settings[:alert_cooldown_seconds]
        )
        log('Settings reloaded')
      end

      private

      def log(message)
        @logger.info("[AlertJob] #{message}")
      end

      def signal_type_enabled?(signal_type)
        case signal_type
        when :auto
          @settings[:enable_auto_signals]
        when :manual
          @settings[:enable_manual_signals]
        when :lagging
          @settings[:enable_lagging_signals]
        when :invalid
          false
        else
          true
        end
      end

      def record_processed(signal)
        data = {
          id: signal.id,
          symbol: signal.symbol,
          signal_type: signal.signal_type,
          strategy_type: signal.strategy_type,
          spread_pct: signal.spread[:real_pct],
          position_usd: signal.suggested_position_usd
        }.to_json

        @redis.zadd(PROCESSED_KEY, Time.now.to_i, data)

        # Keep only last 1000 processed alerts
        @redis.zremrangebyrank(PROCESSED_KEY, 0, -1001)
      end

      def record_stat(stat)
        @redis.hincrby(STATS_KEY, stat.to_s, 1)
      end

      def create_db_signal(validated_signal, raw_signal)
        strategy = infer_strategy(validated_signal, raw_signal)
        signal_class = infer_signal_class(strategy)

        Services::Analytics::SignalRepository.create(
          strategy: strategy,
          class: signal_class,
          symbol: validated_signal.symbol,
          details: {
            spread_pct: validated_signal.spread[:real_pct],
            buy_venue: validated_signal.buy[:venue],
            sell_venue: validated_signal.sell[:venue],
            buy_price: validated_signal.buy[:price],
            sell_price: validated_signal.sell[:price],
            signal_type: validated_signal.signal_type,
            suggested_position_usd: validated_signal.suggested_position_usd
          }
        )
      rescue StandardError => e
        @logger.error("[AlertJob] Failed to create DB signal: #{e.message}")
        nil
      end

      def infer_strategy(validated_signal, raw_signal)
        # Determine strategy based on venues and signal characteristics
        buy_venue = validated_signal.buy[:venue].to_s.downcase
        sell_venue = validated_signal.sell[:venue].to_s.downcase

        # Check if it involves perpetual futures (hedged)
        is_perp = buy_venue.include?('perp') || buy_venue.include?('futures') ||
                  sell_venue.include?('perp') || sell_venue.include?('futures')

        if is_perp
          'spatial_hedged'
        else
          'spatial_manual'
        end
      end

      def infer_signal_class(strategy)
        case strategy
        when 'spatial_hedged', 'funding', 'funding_spread'
          'risk_premium'
        else
          'speculative'
        end
      end

      def append_signal_id(message, signal_id)
        "#{message}\n\nID: `#{signal_id}`\n/taken #{signal_id}"
      end

      def log_spread_to_db(validated_signal, raw_signal, db_signal)
        Services::Analytics::PostgresLogger.log_spread(
          symbol: validated_signal.symbol,
          strategy: infer_strategy(validated_signal, raw_signal),
          low_venue: validated_signal.buy[:venue],
          high_venue: validated_signal.sell[:venue],
          low_price: validated_signal.buy[:price],
          high_price: validated_signal.sell[:price],
          spread_pct: validated_signal.spread[:real_pct],
          net_spread_pct: validated_signal.spread[:net_pct],
          liquidity_usd: validated_signal.suggested_position_usd,
          passed_validation: true,
          signal_id: db_signal&.dig(:id)
        )
      rescue StandardError => e
        @logger.error("[AlertJob] Failed to log spread to DB: #{e.message}")
      end

      def log_rejected_signal(raw_signal, rejection_reason, validated_signal = nil)
        symbol = raw_signal['symbol'] || raw_signal[:symbol]

        if validated_signal
          Services::Analytics::PostgresLogger.log_spread(
            symbol: symbol,
            strategy: infer_strategy(validated_signal, raw_signal),
            low_venue: validated_signal.buy[:venue],
            high_venue: validated_signal.sell[:venue],
            low_price: validated_signal.buy[:price],
            high_price: validated_signal.sell[:price],
            spread_pct: validated_signal.spread[:real_pct],
            net_spread_pct: validated_signal.spread[:net_pct],
            liquidity_usd: validated_signal.suggested_position_usd,
            passed_validation: false,
            rejection_reason: rejection_reason[0..99],  # Truncate to 100 chars
            signal_id: nil
          )
        else
          # Log minimal info for early rejections (blacklist, cooldown)
          buy_venue = raw_signal['buy_venue'] || raw_signal[:buy_venue] || 'unknown'
          sell_venue = raw_signal['sell_venue'] || raw_signal[:sell_venue] || 'unknown'
          spread_pct = raw_signal['spread_pct'] || raw_signal[:spread_pct] || 0

          Services::Analytics::PostgresLogger.log_spread(
            symbol: symbol,
            strategy: 'unknown',
            low_venue: buy_venue,
            high_venue: sell_venue,
            low_price: 0,
            high_price: 0,
            spread_pct: spread_pct.to_f,
            net_spread_pct: nil,
            liquidity_usd: nil,
            passed_validation: false,
            rejection_reason: rejection_reason[0..99],
            signal_id: nil
          )
        end
      rescue StandardError => e
        @logger.debug("[AlertJob] Failed to log rejected signal: #{e.message}")
      end
    end
  end
end
