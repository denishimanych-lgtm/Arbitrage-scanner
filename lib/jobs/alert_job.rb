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
        @convergence_tracker = Services::Analytics::SpreadConvergenceTracker.new
        @signal_grouper = Services::Alerts::SignalGrouper.new
        @spread_history_tracker = Services::Analytics::SpreadHistoryTracker.new

        # Digest mode components
        @digest_accumulator = Services::Alerts::DigestAccumulator.new
        @coin_mode_manager = Services::Alerts::CoinModeManager.new

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

        # 6. Check minimum spread (reload from Redis for real-time UI changes)
        current_min_spread = reload_min_spread_setting
        if validated_signal.spread[:real_pct] < current_min_spread
          log("  Spread too low: #{validated_signal.spread[:real_pct]}% < #{current_min_spread}%")
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

          # 12. Start convergence tracking
          start_convergence_tracking(validated_signal, raw_signal, db_signal)

          # 13. Set cooldown
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

      # Process queue continuously with signal grouping
      def run_loop
        log('Starting alert job loop (with grouping)')

        loop do
          begin
            # Collect signals for grouping window (2 seconds)
            signals = collect_signals_for_grouping(timeout: 2)

            if signals.any?
              process_grouped_signals(signals)
            end
          rescue StandardError => e
            @logger.error("Alert job error: #{e.message}")
            @logger.error(e.backtrace.first(5).join("\n"))
            sleep 1
          end
        end
      end

      # Collect signals from queue within a time window
      # @param timeout [Integer] seconds to collect
      # @return [Array<Hash>] collected raw signals
      def collect_signals_for_grouping(timeout: 2)
        signals = []
        deadline = Time.now + timeout

        loop do
          remaining = (deadline - Time.now).to_i
          break if remaining <= 0

          _, data = @redis.brpop(SIGNAL_QUEUE_KEY, timeout: [remaining, 1].max)
          if data
            raw = data.is_a?(String) ? JSON.parse(data) : data
            signals << raw
          end

          break if Time.now >= deadline
        end

        signals
      end

      # Process signals grouped by symbol
      # @param raw_signals [Array<Hash>] raw signals from queue
      def process_grouped_signals(raw_signals)
        log("Processing #{raw_signals.size} signals for grouping")

        # Group by symbol
        grouped = @signal_grouper.best_with_alternatives(raw_signals)

        grouped.each do |group|
          process_symbol_group(group)
        end
      end

      # Process a group of signals for one symbol
      # Routes to real-time alert or digest accumulator based on coin mode
      # @param group [Hash] { symbol:, best:, others: }
      def process_symbol_group(group)
        symbol = group[:symbol]
        all_raws = [group[:best]] + (group[:others] || [])

        log("Processing group: #{symbol} with #{all_raws.size} signals")

        # Validate ALL signals and collect valid ones with their raw data
        validated_pairs = all_raws.filter_map do |raw|
          next nil unless raw

          validated = validate_signal_for_grouping(raw)
          next nil unless validated

          spread = validated.spread[:real_pct] || 0
          { validated: validated, raw: raw, spread: spread }
        end

        if validated_pairs.empty?
          log("  No valid signals in group for #{symbol}")
          return
        end

        # Sort by spread (highest first) and pick the best
        sorted = validated_pairs.sort_by { |p| -p[:spread].abs }
        best_pair = sorted.first
        other_validated = sorted[1..4].map { |p| p[:validated] }

        log("  Best valid signal: #{best_pair[:spread].round(1)}% (#{sorted.size} valid of #{all_raws.size} total)")

        # Check coin mode: real-time or digest
        if @coin_mode_manager.realtime?(symbol)
          # Real-time mode: send alert immediately
          log("  #{symbol} in REAL-TIME mode, sending alert")
          send_grouped_alert(best_pair[:validated], other_validated, best_pair[:raw])

          # Record observation for convergence tracking
          @coin_mode_manager.record_observation(symbol, {
            spread_pct: best_pair[:spread],
            pair_id: best_pair[:raw]['pair_id'] || best_pair[:raw][:pair_id],
            category: determine_category(best_pair[:raw])
          })
        else
          # Digest mode: accumulate signal
          log("  #{symbol} in DIGEST mode, accumulating")
          accumulate_for_digest(best_pair[:validated], best_pair[:raw])
        end
      end

      # Accumulate validated signal for digest
      def accumulate_for_digest(validated_signal, raw_signal)
        # Build signal data for accumulator
        signal_data = {
          symbol: validated_signal.symbol,
          pair_id: raw_signal['pair_id'] || raw_signal[:pair_id],
          low_venue: validated_signal.low_venue,
          high_venue: validated_signal.high_venue,
          spread: validated_signal.spread,
          liquidity: validated_signal.liquidity,
          prices: validated_signal.prices
        }

        @digest_accumulator.add(signal_data)
      end

      # Determine pair category for tracking
      def determine_category(raw_signal)
        low_venue = raw_signal[:low_venue] || raw_signal['low_venue'] || {}
        high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}

        low_type = (low_venue[:type] || low_venue['type']).to_s.downcase
        high_type = (high_venue[:type] || high_venue['type']).to_s.downcase

        if low_type.include?('spot') && high_type.include?('futures')
          :sf
        elsif low_type.include?('spot') && high_type.include?('spot')
          :ss
        else
          :other
        end
      end

      # Validate signal for grouping - checks blacklist, cooldown, type, safety, spread
      # @return [ValidatedSignal, nil]
      def validate_signal_for_grouping(raw_signal)
        symbol = raw_signal['symbol'] || raw_signal[:symbol]
        pair_id = raw_signal['pair_id'] || raw_signal[:pair_id]

        # 1. Check blacklist
        if @blacklist.blocked?(raw_signal)
          log("  Skipped blacklisted: #{pair_id}")
          return nil
        end

        # 2. Check cooldown (per pair_id)
        unless @cooldown.can_alert?(symbol, pair_id: pair_id)
          log("  Skipped on cooldown: #{pair_id}")
          return nil
        end

        # 3. Build validated signal
        validated_signal = @signal_builder.build(raw_signal)

        # 4. Check signal type settings
        unless signal_type_enabled?(validated_signal.signal_type)
          log("  Skipped type disabled: #{validated_signal.signal_type}")
          return nil
        end

        # 5. Check if passed safety checks (allow fallback signals through)
        is_fallback = (raw_signal[:type] || raw_signal['type']) == :fallback ||
                      (raw_signal[:type] || raw_signal['type']) == 'fallback' ||
                      raw_signal[:fallback_signal] || raw_signal['fallback_signal']

        unless validated_signal.status == :valid || validated_signal.signal_type == :lagging || is_fallback
          log("  Skipped safety failed: #{validated_signal.safety_checks[:messages]&.first}")
          return nil
        end

        # 6. Check minimum spread
        current_min_spread = reload_min_spread_setting
        if validated_signal.spread[:real_pct] < current_min_spread
          log("  Skipped spread too low: #{validated_signal.spread[:real_pct]}%")
          return nil
        end

        validated_signal
      rescue StandardError => e
        @logger.debug("[AlertJob] validate_signal_for_grouping error: #{e.message}")
        nil
      end

      # Validate a signal with all checks
      # @return [ValidatedSignal, nil]
      def validate_signal(raw_signal)
        symbol = raw_signal['symbol'] || raw_signal[:symbol]
        pair_id = raw_signal['pair_id'] || raw_signal[:pair_id]

        # 1. Check blacklist
        if @blacklist.blocked?(raw_signal)
          log("  Blocked by blacklist: #{symbol}")
          record_stat(:blacklist_blocked)
          log_rejected_signal(raw_signal, 'blacklisted')
          return nil
        end

        # 2. Check cooldown (per pair_id)
        unless @cooldown.can_alert?(symbol, pair_id: pair_id)
          remaining = @cooldown.remaining_cooldown(symbol, pair_id: pair_id)
          log("  On cooldown: #{symbol} pair:#{pair_id} (#{remaining}s remaining)")
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
        current_min_spread = reload_min_spread_setting
        if validated_signal.spread[:real_pct] < current_min_spread
          log("  Spread too low: #{validated_signal.spread[:real_pct]}% < #{current_min_spread}%")
          record_stat(:spread_too_low)
          log_rejected_signal(raw_signal, "spread_too_low:#{validated_signal.spread[:real_pct]}%", validated_signal)
          return nil
        end

        validated_signal
      end

      # Minimal validation for alternative signals (just build, no cooldown/blacklist)
      # @return [ValidatedSignal, nil]
      def validate_signal_minimal(raw_signal)
        validated_signal = @signal_builder.build(raw_signal)
        return nil unless validated_signal.status == :valid || validated_signal.signal_type == :lagging

        validated_signal
      rescue StandardError => e
        @logger.debug("[AlertJob] validate_signal_minimal error: #{e.message}")
        nil
      end

      # Send a grouped alert
      def send_grouped_alert(best_validated, other_validated, raw_signal)
        symbol = best_validated.symbol

        # 1. Create signal in PostgreSQL
        db_signal = create_db_signal(best_validated, raw_signal)
        strategy = infer_strategy(best_validated, raw_signal)
        signal_id = db_signal ? Services::Analytics::SignalRepository.short_id(db_signal[:id], strategy) : nil

        # 2. Format grouped alert
        formatted_message = @formatter.format_grouped_signal(best_validated, other_validated)
        formatted_message = append_signal_id(formatted_message, signal_id) if signal_id

        # 3. Build keyboard with position tracking button
        keyboard = nil
        if db_signal
          keyboard = Services::Telegram::Keyboards::AlertKeyboard.new(
            signal_id: db_signal[:id]
          ).to_reply_markup
        end

        # 4. Send to Telegram with keyboard
        result = @notifier.send_alert(formatted_message, reply_markup: keyboard)

        if result
          # 4. Update signal with telegram message ID
          if db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Services::Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          # 5. Log spread to PostgreSQL
          log_spread_to_db(best_validated, raw_signal, db_signal)

          # 6. Start convergence tracking
          start_convergence_tracking(best_validated, raw_signal, db_signal)

          # 7. Set cooldown
          cooldown_duration = best_validated.signal_type == :lagging ?
            @settings[:lagging_alert_cooldown_seconds] :
            @settings[:alert_cooldown_seconds]

          @cooldown.set_cooldown(symbol, pair_id: raw_signal['pair_id'], seconds: cooldown_duration)

          # 8. Record success
          record_processed(best_validated)
          record_stat(:alerts_sent)

          log("  Grouped alert sent: #{signal_id || best_validated.id} (#{best_validated.signal_type}) +#{other_validated.size} alternatives")
        else
          log('  Failed to send grouped alert')
          record_stat(:send_failed)
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

      # Reload just min_spread_pct from Redis for real-time UI changes
      # More efficient than full reload_settings
      def reload_min_spread_setting
        stored_value = @redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_spread_pct')
        if stored_value
          stored_value.to_f
        else
          @settings[:min_spread_pct] || 2.0
        end
      rescue StandardError
        @settings[:min_spread_pct] || 2.0
      end

      def signal_type_enabled?(signal_type)
        # Reload signal type settings from Redis for real-time UI changes
        setting_key = case signal_type
                      when :auto then 'enable_auto_signals'
                      when :manual then 'enable_manual_signals'
                      when :lagging then 'enable_lagging_signals'
                      when :invalid then return false
                      else return true
                      end

        stored = @redis.hget(Services::SettingsLoader::REDIS_KEY, setting_key)
        return @settings[setting_key.to_sym] if stored.nil?

        %w[true 1 yes].include?(stored.to_s.downcase)
      rescue StandardError
        @settings[setting_key.to_sym]
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

        low_venue = validated_signal.low_venue || {}
        high_venue = validated_signal.high_venue || {}
        liquidity = validated_signal.liquidity || {}

        Services::Analytics::SignalRepository.create(
          strategy: strategy,
          class: signal_class,
          symbol: validated_signal.symbol,
          details: {
            spread_pct: validated_signal.spread[:real_pct],
            net_spread_pct: validated_signal.spread[:net_pct],
            buy_venue: venue_display_name(low_venue),
            sell_venue: venue_display_name(high_venue),
            buy_price: validated_signal.prices[:buy_price],
            sell_price: validated_signal.prices[:sell_price],
            signal_type: validated_signal.signal_type,
            suggested_position_usd: validated_signal.suggested_position_usd,
            # Orderbook liquidity limits
            liquidity: {
              max_entry_usd: liquidity[:max_entry_usd],
              max_buy_usd: liquidity[:max_buy_usd],
              max_sell_usd: liquidity[:max_sell_usd],
              exit_usd: liquidity[:exit_usd],
              low_bids_usd: liquidity[:low_bids_usd],
              high_asks_usd: liquidity[:high_asks_usd]
            }
          }
        )
      rescue StandardError => e
        @logger.error("[AlertJob] Failed to create DB signal: #{e.message}")
        nil
      end

      def infer_strategy(validated_signal, raw_signal)
        # Determine strategy based on venues and signal characteristics
        low_venue = validated_signal.low_venue || {}
        high_venue = validated_signal.high_venue || {}

        low_type = (low_venue[:type] || low_venue['type']).to_s.downcase
        high_type = (high_venue[:type] || high_venue['type']).to_s.downcase

        # Check if it involves perpetual futures (hedged)
        is_perp = low_type.include?('perp') || low_type.include?('futures') ||
                  high_type.include?('perp') || high_type.include?('futures')

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
        low_venue = validated_signal.low_venue || {}
        high_venue = validated_signal.high_venue || {}

        Services::Analytics::PostgresLogger.log_spread(
          symbol: validated_signal.symbol,
          strategy: infer_strategy(validated_signal, raw_signal),
          low_venue: venue_display_name(low_venue),
          high_venue: venue_display_name(high_venue),
          low_price: validated_signal.prices[:buy_price],
          high_price: validated_signal.prices[:sell_price],
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
          low_venue = validated_signal.low_venue || {}
          high_venue = validated_signal.high_venue || {}

          Services::Analytics::PostgresLogger.log_spread(
            symbol: symbol,
            strategy: infer_strategy(validated_signal, raw_signal),
            low_venue: venue_display_name(low_venue),
            high_venue: venue_display_name(high_venue),
            low_price: validated_signal.prices[:buy_price],
            high_price: validated_signal.prices[:sell_price],
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

      def venue_display_name(venue)
        type = (venue[:type] || venue['type'])&.to_sym
        exchange = venue[:exchange] || venue['exchange']
        dex = venue[:dex] || venue['dex']

        case type
        when :cex_futures
          "#{exchange&.upcase} Futures"
        when :cex_spot
          "#{exchange&.upcase} Spot"
        when :perp_dex
          "#{dex&.capitalize} Perp"
        when :dex_spot
          "#{dex&.capitalize} DEX"
        else
          'Unknown'
        end
      end

      def start_convergence_tracking(validated_signal, raw_signal, db_signal)
        return unless db_signal && validated_signal.spread[:real_pct]

        pair_id = raw_signal['pair_id'] || raw_signal[:pair_id] || "#{validated_signal.symbol}_unknown"
        symbol = validated_signal.symbol

        @convergence_tracker.start_tracking(
          signal_id: db_signal[:id],
          symbol: symbol,
          pair_id: pair_id,
          initial_spread_pct: validated_signal.spread[:real_pct]
        )

        # Start spread history tracking for ALL pairs of this symbol
        @spread_history_tracker.start_tracking(symbol)
      rescue StandardError => e
        @logger.error("[AlertJob] Failed to start convergence tracking: #{e.message}")
      end

      # Extract spread percentage from signal
      # Handles both nested format (spread: { real_pct: }) and top-level (spread_pct:)
      # @param signal [Hash]
      # @return [Float]
      def extract_spread_pct(signal)
        # Try nested format first (from orderbook analysis)
        nested = signal['spread'] || signal[:spread]
        if nested.is_a?(Hash)
          return (nested['real_pct'] || nested[:real_pct]).to_f.abs
        end

        # Fall back to top-level spread_pct (from price monitor)
        (signal['spread_pct'] || signal[:spread_pct]).to_f.abs
      end

      # Get max spread available for a symbol from spreads:latest
      # @param symbol [String]
      # @return [Float, nil] max spread percentage
      def get_max_spread_for_symbol(symbol)
        spreads_json = @redis.get('spreads:latest')
        return nil unless spreads_json

        spreads = JSON.parse(spreads_json)
        symbol_spreads = spreads.select do |s|
          s_symbol = (s['symbol'] || s[:symbol]).to_s.upcase
          s_symbol == symbol.to_s.upcase
        end

        return nil if symbol_spreads.empty?

        # Get max absolute spread
        max_spread = symbol_spreads.map do |s|
          (s['spread_pct'] || s[:spread_pct]).to_f.abs
        end.max

        max_spread
      rescue StandardError => e
        @logger.debug("[AlertJob] get_max_spread_for_symbol error: #{e.message}")
        nil
      end

      # Re-queue a signal for later processing (to wait for better signal)
      # Track requeue count to prevent infinite loops
      # @param raw_signal [Hash]
      def requeue_signal(raw_signal)
        requeue_count = (raw_signal['requeue_count'] || raw_signal[:requeue_count] || 0).to_i

        # Max 3 requeues to prevent infinite loops
        if requeue_count >= 3
          log("  Max requeues reached, processing anyway")
          return false
        end

        raw_signal['requeue_count'] = requeue_count + 1
        @redis.lpush(SIGNAL_QUEUE_KEY, raw_signal.to_json)
        true
      rescue StandardError => e
        @logger.debug("[AlertJob] requeue_signal error: #{e.message}")
        false
      end
    end
  end
end
