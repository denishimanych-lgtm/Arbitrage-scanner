# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Tracks spread convergence after signals are sent
      # Monitors whether spreads converge (profitable) or diverge (loss)
      class SpreadConvergenceTracker
        # Consider spread "converged" when it drops below this % of initial
        CONVERGENCE_THRESHOLD_PCT = 50.0  # Spread reduced by 50%
        # OR when spread drops below this absolute value
        CONVERGENCE_ABSOLUTE_PCT = 3.0    # Spread < 3% is always "converged"
        # Consider spread "diverged" when it expands beyond this % of initial
        DIVERGENCE_THRESHOLD_PCT = 150.0  # Spread expanded by 50%
        # Stop tracking after this many hours
        MAX_TRACKING_HOURS = 168  # 7 days
        # Check interval
        CHECK_INTERVAL_SECONDS = 60

        def initialize
          @logger = ArbitrageBot.logger
          @redis = ArbitrageBot.redis
        end

        # Start tracking a new signal
        # @param signal_id [String] UUID of the signal
        # @param symbol [String] trading symbol
        # @param pair_id [String] venue pair identifier
        # @param initial_spread_pct [Float] spread at signal time
        def start_tracking(signal_id:, symbol:, pair_id:, initial_spread_pct:)
          # Check if there's already an active tracking for this pair+symbol
          existing = active_tracking_for_pair(pair_id: pair_id, symbol: symbol)
          if existing
            @logger.debug("[ConvergenceTracker] Already tracking #{symbol} #{pair_id}, skipping new signal")
            return nil
          end

          sql = <<~SQL
            INSERT INTO spread_convergence (
              signal_id, symbol, pair_id, initial_spread_pct,
              current_spread_pct, min_spread_pct, max_spread_pct, started_at
            ) VALUES ($1, $2, $3, $4, $4, $4, $4, NOW())
            ON CONFLICT (signal_id) DO NOTHING
            RETURNING id
          SQL

          result = DatabaseConnection.query_one(sql, [signal_id, symbol, pair_id, initial_spread_pct])
          if result
            @logger.info("[ConvergenceTracker] Started tracking: #{symbol} #{pair_id} @ #{initial_spread_pct}%")
          end
          result
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] start_tracking error: #{e.message}")
          nil
        end

        # Check if there's an active tracking for a specific pair+symbol
        # @param pair_id [String]
        # @param symbol [String]
        # @return [Hash, nil] existing tracking record or nil
        def active_tracking_for_pair(pair_id:, symbol:)
          sql = <<~SQL
            SELECT * FROM spread_convergence
            WHERE pair_id = $1 AND symbol = $2 AND closed_at IS NULL
            ORDER BY started_at DESC
            LIMIT 1
          SQL

          DatabaseConnection.query_one(sql, [pair_id, symbol])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] active_tracking_for_pair error: #{e.message}")
          nil
        end

        # Update tracking with current spread
        # @param signal_id [String] UUID of the signal
        # @param current_spread_pct [Float] current spread
        def update_tracking(signal_id:, current_spread_pct:)
          record = get_tracking(signal_id)
          return unless record && record[:closed_at].nil?

          initial = record[:initial_spread_pct].to_f
          min_spread = [record[:min_spread_pct].to_f, current_spread_pct].min
          max_spread = [record[:max_spread_pct].to_f, current_spread_pct].max

          # Check convergence (spread reduced significantly OR below absolute threshold)
          convergence_target = initial * (CONVERGENCE_THRESHOLD_PCT / 100.0)
          converged = current_spread_pct <= convergence_target || current_spread_pct <= CONVERGENCE_ABSOLUTE_PCT

          # Check divergence (spread expanded significantly)
          divergence_target = initial * (DIVERGENCE_THRESHOLD_PCT / 100.0)
          diverged = current_spread_pct >= divergence_target

          sql = <<~SQL
            UPDATE spread_convergence SET
              current_spread_pct = $1,
              min_spread_pct = $2,
              max_spread_pct = $3,
              checks_count = checks_count + 1,
              last_checked_at = NOW(),
              converged = CASE WHEN NOT converged AND $4 THEN TRUE ELSE converged END,
              converged_at = CASE WHEN NOT converged AND $4 THEN NOW() ELSE converged_at END,
              diverged = CASE WHEN NOT diverged AND $5 THEN TRUE ELSE diverged END,
              diverged_at = CASE WHEN NOT diverged AND $5 THEN NOW() ELSE diverged_at END
            WHERE signal_id = $6
          SQL

          DatabaseConnection.execute(sql, [
            current_spread_pct, min_spread, max_spread,
            converged, diverged, signal_id
          ])

          # Log significant events and auto-close completed trackings
          if converged && !record[:converged]
            @logger.info("[ConvergenceTracker] CONVERGED: #{record[:symbol]} #{initial}% -> #{current_spread_pct}%")
            # Auto-close converged signals
            close_tracking(signal_id: signal_id, reason: 'converged')
          elsif diverged && !record[:diverged]
            @logger.warn("[ConvergenceTracker] DIVERGED: #{record[:symbol]} #{initial}% -> #{current_spread_pct}%")
            # Auto-close diverged signals so they appear in statistics
            close_tracking(signal_id: signal_id, reason: 'diverged')
          end

          { converged: converged, diverged: diverged }
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] update_tracking error: #{e.message}")
          nil
        end

        # Close tracking (expired, manually closed, etc)
        # @param signal_id [String] UUID of the signal
        # @param reason [String] close reason
        def close_tracking(signal_id:, reason:)
          sql = <<~SQL
            UPDATE spread_convergence SET
              closed_at = NOW(),
              close_reason = $1
            WHERE signal_id = $2 AND closed_at IS NULL
          SQL

          DatabaseConnection.execute(sql, [reason, signal_id])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] close_tracking error: #{e.message}")
        end

        # Get tracking record
        def get_tracking(signal_id)
          sql = 'SELECT * FROM spread_convergence WHERE signal_id = $1'
          DatabaseConnection.query_one(sql, [signal_id])
        end

        # Get all active (open) tracking records
        def active_trackings
          sql = <<~SQL
            SELECT sc.*, s.details
            FROM spread_convergence sc
            JOIN signals s ON s.id = sc.signal_id
            WHERE sc.closed_at IS NULL
            ORDER BY sc.started_at DESC
          SQL

          DatabaseConnection.query_all(sql, [])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] active_trackings error: #{e.message}")
          []
        end

        # Get convergence statistics
        # @param days [Integer] lookback period in days
        # @param strategy [String] optional strategy filter
        def statistics(days: 30, strategy: nil)
          strategy_filter = strategy ? "AND s.strategy = $2" : ""
          params = strategy ? [days, strategy] : [days]

          sql = <<~SQL
            SELECT
              COUNT(*) as total_signals,
              COUNT(*) FILTER (WHERE sc.converged) as converged_count,
              COUNT(*) FILTER (WHERE sc.diverged) as diverged_count,
              COUNT(*) FILTER (WHERE sc.closed_at IS NULL) as active_count,
              ROUND(AVG(sc.initial_spread_pct)::numeric, 2) as avg_initial_spread,
              ROUND(AVG(sc.min_spread_pct)::numeric, 2) as avg_min_spread,
              ROUND(AVG(sc.checks_count)::numeric, 0) as avg_checks,
              ROUND(
                100.0 * COUNT(*) FILTER (WHERE sc.converged) / NULLIF(COUNT(*), 0),
                1
              ) as convergence_rate_pct,
              ROUND(
                100.0 * COUNT(*) FILTER (WHERE sc.diverged) / NULLIF(COUNT(*), 0),
                1
              ) as divergence_rate_pct,
              ROUND(
                (AVG(EXTRACT(EPOCH FROM (sc.converged_at - sc.started_at)) / 3600) FILTER (WHERE sc.converged))::numeric,
                1
              ) as avg_convergence_hours
            FROM spread_convergence sc
            JOIN signals s ON s.id = sc.signal_id
            WHERE sc.started_at > NOW() - INTERVAL '#{days} days'
            #{strategy_filter}
          SQL

          DatabaseConnection.query_one(sql, params)
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] statistics error: #{e.message}")
          nil
        end

        # Get per-symbol statistics
        def symbol_statistics(days: 30, limit: 20)
          sql = <<~SQL
            SELECT
              sc.symbol,
              COUNT(*) as total,
              COUNT(*) FILTER (WHERE sc.converged) as converged,
              COUNT(*) FILTER (WHERE sc.diverged) as diverged,
              ROUND(AVG(sc.initial_spread_pct)::numeric, 2) as avg_spread,
              ROUND(
                100.0 * COUNT(*) FILTER (WHERE sc.converged) / NULLIF(COUNT(*), 0),
                1
              ) as conv_rate_pct
            FROM spread_convergence sc
            WHERE sc.started_at > NOW() - INTERVAL '#{days} days'
            GROUP BY sc.symbol
            ORDER BY total DESC
            LIMIT $1
          SQL

          DatabaseConnection.query_all(sql, [limit])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] symbol_statistics error: #{e.message}")
          []
        end

        # Get historical statistics for a specific pair (venue combo + symbol)
        # Used to show in alerts
        # @param pair_id [String] venue pair like "binance_spot:bybit_futures"
        # @param symbol [String] trading symbol
        # @param days [Integer] lookback period
        # @return [Hash] pair history stats
        def get_pair_history(pair_id:, symbol:, days: 30)
          sql = <<~SQL
            SELECT
              COUNT(*) as total_signals,
              COUNT(*) FILTER (WHERE sc.converged) as converged_count,
              COUNT(*) FILTER (WHERE sc.diverged) as diverged_count,
              COUNT(*) FILTER (WHERE sc.closed_at IS NULL) as active_count,
              ROUND(AVG(sc.initial_spread_pct)::numeric, 2) as avg_initial_spread,
              ROUND(AVG(sc.min_spread_pct)::numeric, 2) as avg_min_spread,
              ROUND(
                100.0 * COUNT(*) FILTER (WHERE sc.converged) / NULLIF(COUNT(*), 0),
                1
              ) as convergence_rate_pct,
              ROUND(
                (AVG(EXTRACT(EPOCH FROM (sc.converged_at - sc.started_at)) / 3600) FILTER (WHERE sc.converged))::numeric,
                1
              ) as avg_convergence_hours,
              MAX(sc.started_at) as last_signal_at
            FROM spread_convergence sc
            WHERE sc.pair_id = $1
              AND sc.symbol = $2
              AND sc.started_at > NOW() - INTERVAL '#{days} days'
          SQL

          result = DatabaseConnection.query_one(sql, [pair_id, symbol])
          return nil unless result && result[:total_signals].to_i > 0

          {
            pair_id: pair_id,
            symbol: symbol,
            total_signals: result[:total_signals].to_i,
            converged_count: result[:converged_count].to_i,
            diverged_count: result[:diverged_count].to_i,
            active_count: result[:active_count].to_i,
            avg_initial_spread: result[:avg_initial_spread]&.to_f,
            avg_min_spread: result[:avg_min_spread]&.to_f,
            convergence_rate_pct: result[:convergence_rate_pct]&.to_f || 0,
            avg_convergence_hours: result[:avg_convergence_hours]&.to_f,
            last_signal_at: result[:last_signal_at],
            days: days
          }
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] get_pair_history error: #{e.message}")
          nil
        end

        # Get recent signals for a specific pair with their outcomes
        # @param pair_id [String] venue pair like "binance_spot:bybit_futures"
        # @param symbol [String] trading symbol
        # @param limit [Integer] max records
        # @return [Array<Hash>] recent signals
        def recent_signals_for_pair(pair_id:, symbol:, limit: 5)
          sql = <<~SQL
            SELECT
              sc.signal_id,
              sc.initial_spread_pct,
              sc.min_spread_pct,
              sc.converged,
              sc.diverged,
              sc.started_at,
              sc.converged_at,
              EXTRACT(EPOCH FROM (COALESCE(sc.converged_at, sc.closed_at, NOW()) - sc.started_at)) / 3600 as duration_hours
            FROM spread_convergence sc
            WHERE sc.pair_id = $1
              AND sc.symbol = $2
            ORDER BY sc.started_at DESC
            LIMIT $3
          SQL

          DatabaseConnection.query_all(sql, [pair_id, symbol, limit])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] recent_signals_for_pair error: #{e.message}")
          []
        end

        # Backward compatibility - get by symbol only (deprecated)
        def get_symbol_history(symbol, days: 30)
          @logger.debug("[ConvergenceTracker] get_symbol_history called without pair_id - results may mix different pairs")
          sql = <<~SQL
            SELECT
              COUNT(*) as total_signals,
              COUNT(*) FILTER (WHERE sc.converged) as converged_count,
              COUNT(*) FILTER (WHERE sc.diverged) as diverged_count,
              COUNT(*) FILTER (WHERE sc.closed_at IS NULL) as active_count,
              ROUND(AVG(sc.initial_spread_pct)::numeric, 2) as avg_initial_spread,
              ROUND(AVG(sc.min_spread_pct)::numeric, 2) as avg_min_spread,
              ROUND(
                100.0 * COUNT(*) FILTER (WHERE sc.converged) / NULLIF(COUNT(*), 0),
                1
              ) as convergence_rate_pct,
              ROUND(
                (AVG(EXTRACT(EPOCH FROM (sc.converged_at - sc.started_at)) / 3600) FILTER (WHERE sc.converged))::numeric,
                1
              ) as avg_convergence_hours,
              MAX(sc.started_at) as last_signal_at
            FROM spread_convergence sc
            WHERE sc.symbol = $1
              AND sc.started_at > NOW() - INTERVAL '#{days} days'
          SQL

          result = DatabaseConnection.query_one(sql, [symbol])
          return nil unless result && result[:total_signals].to_i > 0

          {
            symbol: symbol,
            total_signals: result[:total_signals].to_i,
            converged_count: result[:converged_count].to_i,
            diverged_count: result[:diverged_count].to_i,
            active_count: result[:active_count].to_i,
            avg_initial_spread: result[:avg_initial_spread]&.to_f,
            avg_min_spread: result[:avg_min_spread]&.to_f,
            convergence_rate_pct: result[:convergence_rate_pct]&.to_f || 0,
            avg_convergence_hours: result[:avg_convergence_hours]&.to_f,
            last_signal_at: result[:last_signal_at],
            days: days
          }
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] get_symbol_history error: #{e.message}")
          nil
        end

        # Backward compatibility (deprecated)
        def recent_signals_for_symbol(symbol, limit: 5)
          sql = <<~SQL
            SELECT
              sc.signal_id,
              sc.initial_spread_pct,
              sc.min_spread_pct,
              sc.converged,
              sc.diverged,
              sc.started_at,
              sc.converged_at,
              EXTRACT(EPOCH FROM (COALESCE(sc.converged_at, sc.closed_at, NOW()) - sc.started_at)) / 3600 as duration_hours
            FROM spread_convergence sc
            WHERE sc.symbol = $1
            ORDER BY sc.started_at DESC
            LIMIT $2
          SQL

          DatabaseConnection.query_all(sql, [symbol, limit])
        rescue StandardError => e
          @logger.error("[ConvergenceTracker] recent_signals_for_symbol error: #{e.message}")
          []
        end

        # Format pair history for inclusion in alerts (pair-specific)
        # @param pair_id [String] venue pair like "binance_spot:bybit_futures"
        # @param symbol [String] trading symbol
        # @return [String] formatted history section
        def format_pair_history_for_alert(pair_id:, symbol:)
          history = get_pair_history(pair_id: pair_id, symbol: symbol)
          return nil unless history && history[:total_signals] > 0

          recent = recent_signals_for_pair(pair_id: pair_id, symbol: symbol, limit: 3)

          # Format pair name for display
          pair_display = format_pair_display(pair_id)

          lines = ["📊 ИСТОРИЯ ПАРЫ #{pair_display} (#{history[:days]}d):"]
          lines << "   Сигналов: #{history[:total_signals]}"
          lines << "   Сошлось: #{history[:converged_count]} (#{history[:convergence_rate_pct]}%)"
          lines << "   Разошлось: #{history[:diverged_count]}"

          if history[:avg_convergence_hours]
            lines << "   Среднее время сходимости: #{history[:avg_convergence_hours]}h"
          end

          if history[:avg_min_spread]
            lines << "   Средний мин. спред: #{history[:avg_min_spread]}%"
          end

          # Show recent signals outcomes
          if recent.any?
            lines << ""
            lines << "   Последние сигналы:"
            recent.each do |r|
              outcome = if r[:converged] == true || r[:converged] == 't'
                          "✅ сошелся за #{r[:duration_hours]&.to_f&.round(1)}h"
                        elsif r[:diverged] == true || r[:diverged] == 't'
                          "❌ разошелся"
                        else
                          "⏳ активен"
                        end
              spread = r[:initial_spread_pct]&.to_f&.round(2)
              lines << "   • #{spread}% → #{outcome}"
            end
          end

          lines.join("\n")
        end

        # Format pair_id for display
        # "binance_spot:bybit_futures" -> "Binance-Spot↔Bybit-Fut"
        def format_pair_display(pair_id)
          parts = pair_id.to_s.split(':')
          return pair_id if parts.size != 2

          format_venue_short(parts[0]) + '↔' + format_venue_short(parts[1])
        end

        def format_venue_short(venue)
          parts = venue.split('_')
          return venue.capitalize if parts.size != 2

          exchange = parts[0].capitalize
          type_suffix = case parts[1]
                        when 'spot' then '-Spot'
                        when 'futures' then '-Fut'
                        when 'perp' then '-Perp'
                        else "-#{parts[1].capitalize}"
                        end
          "#{exchange}#{type_suffix}"
        end

        # Backward compatibility - format by symbol only (deprecated, mixes pairs)
        def format_symbol_history_for_alert(symbol)
          history = get_symbol_history(symbol)
          return nil unless history && history[:total_signals] > 0

          recent = recent_signals_for_symbol(symbol, limit: 3)

          lines = ["📊 ИСТОРИЯ ПО #{symbol} (#{history[:days]}d):"]
          lines << "   Сигналов: #{history[:total_signals]}"
          lines << "   Сошлось: #{history[:converged_count]} (#{history[:convergence_rate_pct]}%)"
          lines << "   Разошлось: #{history[:diverged_count]}"

          if history[:avg_convergence_hours]
            lines << "   Среднее время сходимости: #{history[:avg_convergence_hours]}h"
          end

          if history[:avg_min_spread]
            lines << "   Средний мин. спред: #{history[:avg_min_spread]}%"
          end

          # Show recent signals outcomes
          if recent.any?
            lines << ""
            lines << "   Последние сигналы:"
            recent.each do |r|
              outcome = if r[:converged] == true || r[:converged] == 't'
                          "✅ сошелся за #{r[:duration_hours]&.to_f&.round(1)}h"
                        elsif r[:diverged] == true || r[:diverged] == 't'
                          "❌ разошелся"
                        else
                          "⏳ активен"
                        end
              spread = r[:initial_spread_pct]&.to_f&.round(2)
              lines << "   • #{spread}% → #{outcome}"
            end
          end

          lines.join("\n")
        end

        # Format statistics for Telegram
        def format_stats_message(days: 30)
          stats = statistics(days: days)
          return "No convergence data available." unless stats

          symbol_stats = symbol_statistics(days: days, limit: 10)

          lines = [
            "📈 SPREAD CONVERGENCE (#{days}d)",
            "━" * 30,
            "",
            "📊 ОБЩАЯ СТАТИСТИКА:",
            "   Сигналов: #{stats[:total_signals]}",
            "   Сошлось: #{stats[:converged_count]} (#{stats[:convergence_rate_pct] || 0}%)",
            "   Разошлось: #{stats[:diverged_count]} (#{stats[:divergence_rate_pct] || 0}%)",
            "   Активных: #{stats[:active_count]}",
            "",
            "📉 СПРЕДЫ:",
            "   Средний начальный: #{stats[:avg_initial_spread]}%",
            "   Средний минимум: #{stats[:avg_min_spread]}%",
            "   Среднее время сходимости: #{stats[:avg_convergence_hours] || 'N/A'}h",
            ""
          ]

          if symbol_stats.any?
            lines << "🏆 ТОП СИМВОЛЫ:"
            symbol_stats.first(5).each do |s|
              lines << "   #{s[:symbol]}: #{s[:converged]}/#{s[:total]} (#{s[:conv_rate_pct]}%)"
            end
          end

          lines << ""
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end
      end
    end
  end
end
