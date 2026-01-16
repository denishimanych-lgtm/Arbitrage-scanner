# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Analyzes WHY spread converged - which venue moved, was there arbitrage activity
      class ConvergenceAnalyzer
        # Thresholds for classifying convergence reason
        SIGNIFICANT_MOVE_PCT = 1.0      # >1% is significant
        DOMINANT_MOVE_RATIO = 2.0       # One side moved 2x more than other
        DEPTH_DROP_THRESHOLD = 0.3      # 30% depth drop suggests arb activity
        FAST_CONVERGENCE_MINUTES = 15   # <15 min is fast

        REASON_BUY_UP = 'buy_up'
        REASON_SELL_DOWN = 'sell_down'
        REASON_BOTH = 'both'
        REASON_ARB_ACTIVITY = 'arb_activity'
        REASON_UNKNOWN = 'unknown'

        def initialize
          @logger = ArbitrageBot.logger
          @snapshot_collector = ConvergenceSnapshotCollector.new
        end

        # Analyze a converged signal to determine reason
        # @param signal_id [String] UUID of the signal
        # @return [Hash] analysis results
        def analyze_convergence(signal_id:)
          # Get bookend snapshots
          bookends = @snapshot_collector.get_bookend_snapshots(signal_id)

          if bookends.nil? || bookends[:count] < 2
            @logger.warn("[ConvergenceAnalyzer] Not enough snapshots for #{signal_id}")
            return nil
          end

          first_snapshot = bookends[:first]
          last_snapshot = bookends[:last]

          # Calculate price changes
          buy_venue_change = calculate_price_change(
            first_snapshot[:buy_venue_ask],
            last_snapshot[:buy_venue_ask]
          )

          sell_venue_change = calculate_price_change(
            first_snapshot[:sell_venue_bid],
            last_snapshot[:sell_venue_bid]
          )

          # Calculate depth changes (if available)
          buy_depth_change = calculate_depth_change(
            first_snapshot[:buy_venue_ask_depth_usd],
            last_snapshot[:buy_venue_ask_depth_usd]
          )

          sell_depth_change = calculate_depth_change(
            first_snapshot[:sell_venue_bid_depth_usd],
            last_snapshot[:sell_venue_bid_depth_usd]
          )

          # Calculate convergence duration
          duration_minutes = calculate_duration_minutes(
            first_snapshot[:snapshot_at],
            last_snapshot[:snapshot_at]
          )

          # Determine reason
          reason = determine_reason(
            buy_change: buy_venue_change,
            sell_change: sell_venue_change,
            buy_depth_change: buy_depth_change,
            sell_depth_change: sell_depth_change,
            duration_minutes: duration_minutes
          )

          analysis = {
            signal_id: signal_id,
            initial_buy_price: first_snapshot[:buy_venue_ask],
            initial_sell_price: first_snapshot[:sell_venue_bid],
            initial_spread_pct: first_snapshot[:spread_pct],
            final_buy_price: last_snapshot[:buy_venue_ask],
            final_sell_price: last_snapshot[:sell_venue_bid],
            final_spread_pct: last_snapshot[:spread_pct],
            buy_venue_change_pct: buy_venue_change,
            sell_venue_change_pct: sell_venue_change,
            buy_depth_change_pct: buy_depth_change,
            sell_depth_change_pct: sell_depth_change,
            convergence_reason: reason,
            convergence_duration_minutes: duration_minutes,
            snapshots_count: bookends[:count]
          }

          # Store analysis
          store_analysis(analysis)

          analysis
        rescue StandardError => e
          @logger.error("[ConvergenceAnalyzer] analyze_convergence error: #{e.message}")
          nil
        end

        # Determine convergence reason based on price/depth changes
        # @param buy_change [Float] buy venue price change %
        # @param sell_change [Float] sell venue price change %
        # @param buy_depth_change [Float, nil] buy venue depth change %
        # @param sell_depth_change [Float, nil] sell venue depth change %
        # @param duration_minutes [Float] how long convergence took
        # @return [String] reason classification
        def determine_reason(buy_change:, sell_change:, buy_depth_change:, sell_depth_change:, duration_minutes:)
          # Check for arbitrage activity indicators
          if arb_activity_detected?(buy_depth_change, sell_depth_change, duration_minutes)
            return REASON_ARB_ACTIVITY
          end

          buy_abs = buy_change.abs
          sell_abs = sell_change.abs

          # Both insignificant
          if buy_abs < SIGNIFICANT_MOVE_PCT && sell_abs < SIGNIFICANT_MOVE_PCT
            return REASON_UNKNOWN
          end

          # Buy venue moved up significantly more
          if buy_change > SIGNIFICANT_MOVE_PCT && (sell_abs < buy_abs / DOMINANT_MOVE_RATIO)
            return REASON_BUY_UP
          end

          # Sell venue moved down significantly more
          if sell_change < -SIGNIFICANT_MOVE_PCT && (buy_abs < sell_abs / DOMINANT_MOVE_RATIO)
            return REASON_SELL_DOWN
          end

          # Both moved significantly toward each other
          if buy_abs >= SIGNIFICANT_MOVE_PCT || sell_abs >= SIGNIFICANT_MOVE_PCT
            return REASON_BOTH
          end

          REASON_UNKNOWN
        end

        # Format analysis for display
        # @param signal_id [String]
        # @return [String, nil] formatted analysis text
        def format_analysis(signal_id:)
          # Try to get from database
          analysis = get_analysis(signal_id)
          return nil unless analysis

          reason_text = case analysis[:convergence_reason]
                        when REASON_BUY_UP then 'BUY VENUE PRICE UP'
                        when REASON_SELL_DOWN then 'SELL VENUE PRICE DOWN'
                        when REASON_BOTH then 'BOTH MOVED'
                        when REASON_ARB_ACTIVITY then 'ARBITRAGE ACTIVITY'
                        else 'UNKNOWN'
                        end

          lines = ['📈 АНАЛИЗ СХОДИМОСТИ:']
          lines << "   Начало: buy $#{format_price(analysis[:initial_buy_price])}, sell $#{format_price(analysis[:initial_sell_price])} (#{analysis[:initial_spread_pct]&.round(2)}%)"
          lines << "   Конец: buy $#{format_price(analysis[:final_buy_price])}, sell $#{format_price(analysis[:final_sell_price])} (#{analysis[:final_spread_pct]&.round(2)}%)"
          lines << ''
          lines << "   Причина: #{reason_text}"
          lines << "   • Buy venue: #{format_change(analysis[:buy_venue_change_pct])}"
          lines << "   • Sell venue: #{format_change(analysis[:sell_venue_change_pct])}"

          if analysis[:buy_depth_change_pct] || analysis[:sell_depth_change_pct]
            lines << ''
            lines << '   Ликвидность:'
            lines << "   • Buy depth: #{format_change(analysis[:buy_depth_change_pct])}" if analysis[:buy_depth_change_pct]
            lines << "   • Sell depth: #{format_change(analysis[:sell_depth_change_pct])}" if analysis[:sell_depth_change_pct]
          end

          lines.join("\n")
        rescue StandardError => e
          @logger.error("[ConvergenceAnalyzer] format_analysis error: #{e.message}")
          nil
        end

        private

        def calculate_price_change(initial, final)
          return 0 unless initial && final && initial.to_f > 0

          ((final.to_f - initial.to_f) / initial.to_f * 100).round(4)
        end

        def calculate_depth_change(initial, final)
          return nil unless initial && final && initial.to_f > 0

          ((final.to_f - initial.to_f) / initial.to_f * 100).round(4)
        end

        def calculate_duration_minutes(start_time, end_time)
          return nil unless start_time && end_time

          start_t = start_time.is_a?(Time) ? start_time : Time.parse(start_time.to_s)
          end_t = end_time.is_a?(Time) ? end_time : Time.parse(end_time.to_s)

          ((end_t - start_t) / 60).round(2)
        rescue StandardError
          nil
        end

        def arb_activity_detected?(buy_depth_change, sell_depth_change, duration_minutes)
          return false unless duration_minutes

          # Fast convergence + significant depth drop = likely arb activity
          fast_convergence = duration_minutes < FAST_CONVERGENCE_MINUTES

          depth_dropped = (buy_depth_change && buy_depth_change < -DEPTH_DROP_THRESHOLD * 100) ||
                          (sell_depth_change && sell_depth_change < -DEPTH_DROP_THRESHOLD * 100)

          fast_convergence && depth_dropped
        end

        def store_analysis(analysis)
          sql = <<~SQL
            INSERT INTO convergence_analysis (
              signal_id,
              initial_buy_price, initial_sell_price, initial_spread_pct,
              final_buy_price, final_sell_price, final_spread_pct,
              buy_venue_change_pct, sell_venue_change_pct,
              convergence_reason,
              buy_depth_change_pct, sell_depth_change_pct,
              convergence_duration_minutes, snapshots_count,
              analyzed_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW())
            ON CONFLICT (signal_id) DO UPDATE SET
              final_buy_price = EXCLUDED.final_buy_price,
              final_sell_price = EXCLUDED.final_sell_price,
              final_spread_pct = EXCLUDED.final_spread_pct,
              buy_venue_change_pct = EXCLUDED.buy_venue_change_pct,
              sell_venue_change_pct = EXCLUDED.sell_venue_change_pct,
              convergence_reason = EXCLUDED.convergence_reason,
              buy_depth_change_pct = EXCLUDED.buy_depth_change_pct,
              sell_depth_change_pct = EXCLUDED.sell_depth_change_pct,
              convergence_duration_minutes = EXCLUDED.convergence_duration_minutes,
              snapshots_count = EXCLUDED.snapshots_count,
              analyzed_at = NOW()
          SQL

          DatabaseConnection.execute(sql, [
            analysis[:signal_id],
            analysis[:initial_buy_price],
            analysis[:initial_sell_price],
            analysis[:initial_spread_pct],
            analysis[:final_buy_price],
            analysis[:final_sell_price],
            analysis[:final_spread_pct],
            analysis[:buy_venue_change_pct],
            analysis[:sell_venue_change_pct],
            analysis[:convergence_reason],
            analysis[:buy_depth_change_pct],
            analysis[:sell_depth_change_pct],
            analysis[:convergence_duration_minutes],
            analysis[:snapshots_count]
          ])
        end

        def get_analysis(signal_id)
          sql = 'SELECT * FROM convergence_analysis WHERE signal_id = $1'
          DatabaseConnection.query_one(sql, [signal_id])
        rescue StandardError
          nil
        end

        def format_price(price)
          return '?' unless price

          price.to_f.round(4)
        end

        def format_change(change)
          return '?' unless change

          sign = change >= 0 ? '+' : ''
          "#{sign}#{change.round(2)}%"
        end
      end
    end
  end
end
