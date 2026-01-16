# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Periodically checks spread convergence for active signals
    # Uses adaptive scheduling: frequent checks for new signals, less frequent for old ones
    class ConvergenceCheckJob
      # Base loop interval - adaptive scheduler determines actual check frequency per signal
      LOOP_INTERVAL_SECONDS = 5  # Check scheduler every 5 seconds
      MAX_TRACKING_HOURS = 168   # 7 days

      # Divergence alert threshold (spread expanded by 50%+)
      DIVERGENCE_ALERT_THRESHOLD_PCT = 150.0
      DIVERGENCE_ALERT_COOLDOWN_KEY = 'convergence:divergence_alert:'
      DIVERGENCE_ALERT_COOLDOWN_SECONDS = 3600  # 1 hour

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @tracker = Services::Analytics::SpreadConvergenceTracker.new
        @notifier = Services::Telegram::TelegramNotifier.new
        @scheduler = Services::Analytics::AdaptiveTrackingScheduler.new
        @snapshot_collector = Services::Analytics::ConvergenceSnapshotCollector.new
        @convergence_analyzer = Services::Analytics::ConvergenceAnalyzer.new
        @pair_stats_service = Services::Analytics::PairStatisticsService.new
        @settings = settings
        log('ConvergenceCheckJob initialized with adaptive scheduling')
      end

      # Run once
      def perform
        active = @tracker.active_trackings

        checked = 0
        skipped = 0
        expired = 0
        converged = 0
        diverged = 0
        alerts_sent = 0
        snapshots = 0

        active.each do |record|
          # Check if tracking expired
          started = record[:started_at]
          # Handle nil or string timestamps
          started = Time.parse(started.to_s) if started.is_a?(String)
          next unless started

          hours_elapsed = (Time.now - started) / 3600.0

          if hours_elapsed > MAX_TRACKING_HOURS
            @tracker.close_tracking(signal_id: record[:signal_id], reason: 'expired')
            # Update pair statistics after close
            @pair_stats_service.update_after_close(signal_id: record[:signal_id])
            expired += 1
            next
          end

          # Adaptive scheduling: check if this signal is due for check
          unless @scheduler.due_for_check?(record)
            skipped += 1
            next
          end

          # Get current spread for this pair
          details = parse_details(record[:details])
          current_spread = fetch_current_spread(
            symbol: record[:symbol],
            pair_id: record[:pair_id],
            buy_venue: details['buy_venue'],
            sell_venue: details['sell_venue']
          )

          next unless current_spread

          initial_spread = record[:initial_spread_pct].to_f
          was_diverged = record[:diverged] == true || record[:diverged] == 't'

          # Capture snapshot for convergence analysis
          snapshot_captured = capture_snapshot(record, details, current_spread)
          snapshots += 1 if snapshot_captured

          result = @tracker.update_tracking(
            signal_id: record[:signal_id],
            current_spread_pct: current_spread
          )

          if result
            checked += 1

            # Handle convergence
            if result[:converged]
              converged += 1
              handle_convergence(record)
            end

            # Check for new divergence (spread expansion)
            if result[:diverged] && !was_diverged
              diverged += 1
              # Send divergence alert
              if send_divergence_alert(record, current_spread, initial_spread, details)
                alerts_sent += 1
              end
            end
          end
        end

        if checked > 0 || expired > 0 || converged > 0
          log("Active: #{active.size}, Checked: #{checked}, Skipped: #{skipped}, Expired: #{expired}, Converged: #{converged}, Diverged: #{diverged}, Snapshots: #{snapshots}")
        end
      end

      # Run continuously with adaptive scheduling
      def run_loop
        log('Starting convergence check loop with adaptive scheduling')

        loop do
          begin
            perform
          rescue StandardError => e
            @logger.error("[ConvergenceCheckJob] Error: #{e.message}")
            @logger.error(e.backtrace.first(5).join("\n"))
          end

          sleep LOOP_INTERVAL_SECONDS
        end
      end

      private

      def log(message)
        @logger.info("[ConvergenceCheckJob] #{message}")
      end

      # Capture price snapshot for convergence analysis
      # @param record [Hash] tracking record
      # @param details [Hash] parsed details
      # @param current_spread [Float] current spread percentage
      # @return [Boolean] success
      def capture_snapshot(record, details, current_spread)
        buy_venue = build_venue_hash(details['buy_venue'])
        sell_venue = build_venue_hash(details['sell_venue'])

        @snapshot_collector.capture_snapshot(
          signal_id: record[:signal_id],
          symbol: record[:symbol],
          buy_venue: buy_venue,
          sell_venue: sell_venue,
          current_spread: current_spread
        )
      rescue StandardError => e
        @logger.debug("[ConvergenceCheckJob] capture_snapshot error: #{e.message}")
        false
      end

      # Build venue hash from display name
      # "BINANCE Futures" -> { exchange: 'binance', type: 'cex_futures' }
      def build_venue_hash(venue_name)
        return nil unless venue_name

        parts = venue_name.to_s.split(' ')
        return nil if parts.size < 2

        exchange = parts[0].downcase
        market_type = parts[1].downcase

        venue_type = case market_type
                     when 'futures' then 'cex_futures'
                     when 'spot' then 'cex_spot'
                     when 'perp' then 'perp_dex'
                     else 'cex_futures'
                     end

        {
          exchange: exchange,
          type: venue_type,
          venue_id: "#{exchange}_#{market_type}"
        }
      end

      # Handle convergence: analyze reason and update statistics
      # @param record [Hash] tracking record
      def handle_convergence(record)
        signal_id = record[:signal_id]

        # Analyze why spread converged
        Thread.new do
          begin
            analysis = @convergence_analyzer.analyze_convergence(signal_id: signal_id)
            if analysis
              log("Convergence analyzed for #{record[:symbol]}: #{analysis[:convergence_reason]}")
            end

            # Update pair statistics
            @pair_stats_service.update_after_close(signal_id: signal_id)
          rescue StandardError => e
            @logger.error("[ConvergenceCheckJob] handle_convergence error: #{e.message}")
          end
        end
      end

      # Send alert when spread expands instead of converging
      def send_divergence_alert(record, current_spread, initial_spread, details)
        signal_id = record[:signal_id]
        symbol = record[:symbol]

        # Check cooldown
        return false if divergence_on_cooldown?(signal_id)

        # Calculate expansion
        expansion_pct = initial_spread > 0 ? ((current_spread / initial_spread) * 100).round(1) : 0
        spread_change = (current_spread - initial_spread).round(2)

        # Get hours elapsed
        started = record[:started_at]
        hours_elapsed = started ? ((Time.now - started) / 3600.0).round(1) : 0

        buy_venue = details['buy_venue'] || 'Unknown'
        sell_venue = details['sell_venue'] || 'Unknown'

        message = <<~MSG
          ⚠️ SPREAD EXPANSION | #{symbol}
          ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

          📈 СПРЕД РАСШИРИЛСЯ ВМЕСТО СХОЖДЕНИЯ!

          📊 ИЗМЕНЕНИЕ СПРЕДА:
             Начальный: #{initial_spread.round(2)}%
             Текущий: #{current_spread.round(2)}%
             Изменение: +#{spread_change}%
             Расширение: #{expansion_pct}% от начального

          ⏰ Время отслеживания: #{hours_elapsed}h

          🏦 ПАРА:
             BUY: #{buy_venue}
             SELL: #{sell_venue}

          ⚠️ РИСК:
          • Позиция может быть в убытке
          • Рекомендуется пересмотреть или закрыть

          📝 ДЕЙСТВИЯ:
          1. Проверить текущие цены на биржах
          2. Оценить, продолжать ли держать
          3. При дальнейшем расширении - закрыть с убытком
        MSG

        # Get short signal ID
        short_id = Services::Analytics::SignalRepository.short_id(signal_id, 'spatial')
        message = "#{message}\n\nСигнал ID: `#{short_id}`" if short_id

        result = @notifier.send_alert(message.strip)

        if result
          set_divergence_cooldown(signal_id)
          log("Sent divergence alert for #{symbol}: #{initial_spread}% -> #{current_spread}%")
        end

        result
      rescue StandardError => e
        @logger.error("[ConvergenceCheckJob] send_divergence_alert error: #{e.message}")
        false
      end

      def divergence_on_cooldown?(signal_id)
        key = "#{DIVERGENCE_ALERT_COOLDOWN_KEY}#{signal_id}"
        ArbitrageBot.redis.exists?(key)
      rescue StandardError
        false
      end

      def set_divergence_cooldown(signal_id)
        key = "#{DIVERGENCE_ALERT_COOLDOWN_KEY}#{signal_id}"
        ArbitrageBot.redis.setex(key, DIVERGENCE_ALERT_COOLDOWN_SECONDS, '1')
      rescue StandardError => e
        @logger.error("[ConvergenceCheckJob] set_divergence_cooldown error: #{e.message}")
      end

      def parse_details(details)
        return {} unless details

        if details.is_a?(String)
          JSON.parse(details)
        else
          details.transform_keys(&:to_s)
        end
      rescue StandardError
        {}
      end

      def fetch_current_spread(symbol:, pair_id:, buy_venue:, sell_venue:)
        # Parse venue info from display names
        buy_exchange, buy_type = parse_venue_name(buy_venue)
        sell_exchange, sell_type = parse_venue_name(sell_venue)

        return nil unless buy_exchange && sell_exchange

        # Get current prices from Redis cache
        buy_price = get_cached_price(buy_exchange, buy_type, symbol)
        sell_price = get_cached_price(sell_exchange, sell_type, symbol)

        return nil unless buy_price && sell_price && buy_price > 0

        # Calculate spread (sell - buy) / buy * 100
        spread_pct = ((sell_price - buy_price) / buy_price * 100).round(4)
        spread_pct
      rescue StandardError => e
        @logger.debug("[ConvergenceCheckJob] fetch_current_spread error: #{e.message}")
        nil
      end

      def parse_venue_name(venue_name)
        return [nil, nil] unless venue_name

        # "BINANCE Futures" -> ["binance", "futures"]
        # "BINANCE Spot" -> ["binance", "spot"]
        parts = venue_name.to_s.split(' ')
        return [nil, nil] if parts.size < 2

        exchange = parts[0].downcase
        market_type = parts[1].downcase

        [exchange, market_type]
      end

      def get_cached_price(exchange, market_type, symbol)
        redis = ArbitrageBot.redis

        # Get prices from prices:latest cache (used by PriceMonitorJob)
        # Format: "exchange_markettype:BASE_SYMBOL" e.g. "binance_futures:ETH" (NOT "ETHUSDT"!)
        data = redis.get('prices:latest')
        return nil unless data

        prices = JSON.parse(data)

        # IMPORTANT: Price cache uses BASE symbol (ETH), not full symbol (ETHUSDT)
        base_symbol = extract_base_symbol(symbol)
        key = "#{exchange}_#{market_type}:#{base_symbol}"
        venue_data = prices[key]

        return nil unless venue_data

        # Use last price or mid price
        if venue_data['last']
          venue_data['last'].to_f
        elsif venue_data['bid'] && venue_data['ask']
          (venue_data['bid'].to_f + venue_data['ask'].to_f) / 2
        end
      rescue StandardError => e
        @logger.debug("[ConvergenceCheckJob] get_cached_price error: #{e.message}")
        nil
      end

      # Extract base symbol from full trading pair
      # "ETHUSDT" -> "ETH", "BTC-USDT" -> "BTC", "SOLPERP" -> "SOL"
      def extract_base_symbol(symbol)
        symbol.to_s.upcase
              .gsub(/USDT$|USDC$|USD$|BUSD$/, '')
              .gsub(/[-_]/, '')
              .gsub(/PERP$/, '')
      end
    end
  end
end
