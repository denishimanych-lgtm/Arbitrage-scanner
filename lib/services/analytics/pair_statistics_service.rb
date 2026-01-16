# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Aggregated statistics service for exchange pairs
      # Tracks max/min spreads, convergence rates, timing
      class PairStatisticsService
        def initialize
          @logger = ArbitrageBot.logger
        end

        # Get comprehensive statistics for a specific pair
        # @param pair_id [String] e.g. "binance_spot:bybit_futures"
        # @param symbol [String] e.g. "FLOW"
        # @return [Hash, nil] statistics or nil if no data
        def get_statistics(pair_id:, symbol:)
          # First check if we have aggregated stats
          stats = get_aggregated_stats(pair_id, symbol)

          # Get recent outcomes from spread_convergence
          recent = recent_outcomes(pair_id: pair_id, symbol: symbol, limit: 5)

          return nil unless stats || recent.any?

          {
            pair_id: pair_id,
            symbol: symbol,
            max_spread_pct: stats&.dig(:max_spread_pct),
            min_spread_pct: stats&.dig(:min_spread_pct),
            total_signals: stats&.dig(:total_signals) || recent.size,
            converged_count: stats&.dig(:converged_count) || recent.count { |r| r[:converged] },
            diverged_count: stats&.dig(:diverged_count) || recent.count { |r| r[:diverged] },
            success_rate_pct: stats&.dig(:success_rate_pct) || calculate_success_rate(recent),
            avg_convergence_minutes: stats&.dig(:avg_convergence_minutes),
            fastest_convergence_minutes: stats&.dig(:fastest_convergence_minutes),
            recent_outcomes: recent
          }
        end

        # Get recent signal outcomes for a pair
        # @param pair_id [String]
        # @param symbol [String]
        # @param limit [Integer]
        # @return [Array<Hash>] outcomes with spread, duration, result
        def recent_outcomes(pair_id:, symbol:, limit: 5)
          sql = <<~SQL
            SELECT
              sc.signal_id,
              sc.initial_spread_pct,
              sc.min_spread_pct,
              sc.converged,
              sc.diverged,
              sc.started_at,
              sc.converged_at,
              sc.closed_at,
              ca.convergence_reason
            FROM spread_convergence sc
            LEFT JOIN convergence_analysis ca ON ca.signal_id = sc.signal_id
            WHERE sc.pair_id = $1
              AND sc.symbol = $2
              AND sc.closed_at IS NOT NULL
            ORDER BY sc.started_at DESC
            LIMIT $3
          SQL

          results = DatabaseConnection.query_all(sql, [pair_id, symbol, limit])

          results.map do |r|
            duration_min = calculate_duration_minutes(r[:started_at], r[:converged_at] || r[:closed_at])

            {
              signal_id: r[:signal_id],
              spread_pct: r[:initial_spread_pct]&.to_f,
              min_spread_pct: r[:min_spread_pct]&.to_f,
              converged: r[:converged],
              diverged: r[:diverged],
              duration_min: duration_min,
              reason: r[:convergence_reason],
              started_at: r[:started_at],
              converged_at: r[:converged_at]
            }
          end
        rescue StandardError => e
          @logger.error("[PairStatisticsService] recent_outcomes error: #{e.message}")
          []
        end

        # Get statistics for a specific time window
        # @param pair_id [String]
        # @param symbol [String]
        # @param hours [Integer] 24 for 24h, 168 for 7 days
        # @return [Hash, nil] statistics for the time window
        def get_time_window_stats(pair_id:, symbol:, hours:)
          sql = <<~SQL
            SELECT
              COUNT(*) as signal_count,
              MAX(initial_spread_pct) as max_spread,
              MIN(min_spread_pct) as min_spread,
              COUNT(*) FILTER (WHERE converged = true) as converged_count
            FROM spread_convergence
            WHERE pair_id = $1
              AND symbol = $2
              AND started_at > NOW() - INTERVAL '1 hour' * $3
          SQL

          result = DatabaseConnection.query_one(sql, [pair_id, symbol, hours])
          return nil unless result && result[:signal_count].to_i > 0

          {
            signal_count: result[:signal_count].to_i,
            max_spread_pct: result[:max_spread]&.to_f,
            min_spread_pct: result[:min_spread]&.to_f,
            converged_count: result[:converged_count].to_i
          }
        rescue StandardError => e
          @logger.debug("[PairStatisticsService] get_time_window_stats error: #{e.message}")
          nil
        end

        # Update statistics after a signal closes (converges/diverges/expires)
        # @param signal_id [String]
        def update_after_close(signal_id:)
          # Get the signal's convergence record
          sql = <<~SQL
            SELECT pair_id, symbol, initial_spread_pct, min_spread_pct,
                   converged, diverged, started_at, converged_at, closed_at
            FROM spread_convergence
            WHERE signal_id = $1
          SQL

          record = DatabaseConnection.query_one(sql, [signal_id])
          return unless record

          pair_id = record[:pair_id]
          symbol = record[:symbol]

          # Recalculate aggregates for this pair
          refresh_pair_statistics(pair_id: pair_id, symbol: symbol)
        rescue StandardError => e
          @logger.error("[PairStatisticsService] update_after_close error: #{e.message}")
        end

        # Refresh aggregated statistics for a specific pair
        # @param pair_id [String]
        # @param symbol [String]
        def refresh_pair_statistics(pair_id:, symbol:)
          sql = <<~SQL
            INSERT INTO pair_statistics (
              pair_id, symbol,
              max_spread_pct, min_spread_pct,
              total_signals, converged_count, diverged_count, expired_count,
              avg_convergence_minutes, median_convergence_minutes,
              fastest_convergence_minutes, slowest_convergence_minutes,
              success_rate_pct,
              first_signal_at, last_signal_at, updated_at
            )
            SELECT
              $1 as pair_id,
              $2 as symbol,
              MAX(initial_spread_pct) as max_spread_pct,
              MIN(initial_spread_pct) as min_spread_pct,
              COUNT(*) as total_signals,
              COUNT(*) FILTER (WHERE converged) as converged_count,
              COUNT(*) FILTER (WHERE diverged) as diverged_count,
              COUNT(*) FILTER (WHERE NOT converged AND NOT diverged AND closed_at IS NOT NULL) as expired_count,
              ROUND(AVG(
                EXTRACT(EPOCH FROM (converged_at - started_at)) / 60
              ) FILTER (WHERE converged)::numeric, 2) as avg_convergence_minutes,
              ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (converged_at - started_at)) / 60
              ) FILTER (WHERE converged)::numeric, 2) as median_convergence_minutes,
              ROUND(MIN(
                EXTRACT(EPOCH FROM (converged_at - started_at)) / 60
              ) FILTER (WHERE converged)::numeric, 2) as fastest_convergence_minutes,
              ROUND(MAX(
                EXTRACT(EPOCH FROM (converged_at - started_at)) / 60
              ) FILTER (WHERE converged)::numeric, 2) as slowest_convergence_minutes,
              ROUND(
                (COUNT(*) FILTER (WHERE converged))::numeric /
                NULLIF(COUNT(*) FILTER (WHERE closed_at IS NOT NULL), 0) * 100,
              2) as success_rate_pct,
              MIN(started_at) as first_signal_at,
              MAX(started_at) as last_signal_at,
              NOW() as updated_at
            FROM spread_convergence
            WHERE pair_id = $1::text AND symbol = $2::text
            ON CONFLICT (pair_id, symbol) DO UPDATE SET
              max_spread_pct = EXCLUDED.max_spread_pct,
              min_spread_pct = EXCLUDED.min_spread_pct,
              total_signals = EXCLUDED.total_signals,
              converged_count = EXCLUDED.converged_count,
              diverged_count = EXCLUDED.diverged_count,
              expired_count = EXCLUDED.expired_count,
              avg_convergence_minutes = EXCLUDED.avg_convergence_minutes,
              median_convergence_minutes = EXCLUDED.median_convergence_minutes,
              fastest_convergence_minutes = EXCLUDED.fastest_convergence_minutes,
              slowest_convergence_minutes = EXCLUDED.slowest_convergence_minutes,
              success_rate_pct = EXCLUDED.success_rate_pct,
              first_signal_at = EXCLUDED.first_signal_at,
              last_signal_at = EXCLUDED.last_signal_at,
              updated_at = EXCLUDED.updated_at
          SQL

          DatabaseConnection.execute(sql, [pair_id, symbol])
          @logger.debug("[PairStatisticsService] Refreshed stats for #{pair_id}:#{symbol}")
        rescue StandardError => e
          @logger.error("[PairStatisticsService] refresh_pair_statistics error: #{e.message}")
        end

        # Format statistics for alert display
        # @param pair_id [String]
        # @param symbol [String]
        # @return [String, nil] formatted section or nil if no data
        def format_for_alert(pair_id:, symbol:)
          # Get time-windowed stats
          stats_24h = get_time_window_stats(pair_id: pair_id, symbol: symbol, hours: 24)
          stats_7d = get_time_window_stats(pair_id: pair_id, symbol: symbol, hours: 168)

          # Get recent outcomes
          recent = recent_outcomes(pair_id: pair_id, symbol: symbol, limit: 5)

          # Return nil if no data at all
          return nil unless stats_24h || stats_7d || recent.any?

          pair_display = format_pair_display(pair_id)
          lines = ["📊 ИСТОРИЯ ПАРЫ #{pair_display}:"]
          lines << ""

          # 24h stats
          if stats_24h
            max = stats_24h[:max_spread_pct]&.round(1) || '?'
            min = stats_24h[:min_spread_pct]&.round(1) || '?'
            count = stats_24h[:signal_count]
            lines << "   24ч: Max #{max}% | Min #{min}% | Сигналов: #{count}"
          end

          # 7d stats
          if stats_7d
            max = stats_7d[:max_spread_pct]&.round(1) || '?'
            min = stats_7d[:min_spread_pct]&.round(1) || '?'
            count = stats_7d[:signal_count]
            converged = stats_7d[:converged_count]
            rate = count > 0 ? ((converged.to_f / count) * 100).round(0) : 0
            lines << "   7д:  Max #{max}% | Min #{min}% | Сигналов: #{count}"
            lines << ""
            lines << "   Успешность: #{rate}% (#{converged}/#{count} сошлись до <50%)"
          elsif stats_24h
            converged = stats_24h[:converged_count]
            count = stats_24h[:signal_count]
            rate = count > 0 ? ((converged.to_f / count) * 100).round(0) : 0
            lines << ""
            lines << "   Успешность: #{rate}% (#{converged}/#{count} сошлись до <50%)"
          end

          # Recent convergence examples - show only ACTUALLY converged (spread reduced by >10%)
          converged_examples = recent.select do |r|
            next false unless r[:converged]
            initial = r[:spread_pct].to_f
            final = r[:min_spread_pct].to_f
            # Only show if spread actually reduced by at least 10%
            initial > 0 && final < initial * 0.9
          end.first(3)

          if converged_examples.any?
            lines << ""
            lines << "   Примеры схождения:"
            converged_examples.each do |outcome|
              lines << format_outcome_line(outcome)
            end
          elsif recent.any?
            lines << ""
            lines << "   Последние сигналы:"
            recent.first(3).each do |outcome|
              lines << format_outcome_line(outcome)
            end
          end

          lines.join("\n")
        rescue StandardError => e
          @logger.error("[PairStatisticsService] format_for_alert error: #{e.message}")
          nil
        end

        private

        def get_aggregated_stats(pair_id, symbol)
          sql = <<~SQL
            SELECT * FROM pair_statistics
            WHERE pair_id = $1 AND symbol = $2
          SQL

          DatabaseConnection.query_one(sql, [pair_id, symbol])
        rescue StandardError => e
          @logger.debug("[PairStatisticsService] get_aggregated_stats error: #{e.message}")
          nil
        end

        def calculate_success_rate(outcomes)
          return 0 if outcomes.empty?

          converged = outcomes.count { |o| o[:converged] }
          (converged.to_f / outcomes.size * 100).round(1)
        end

        def calculate_duration_minutes(start_time, end_time)
          return nil unless start_time && end_time

          start_t = start_time.is_a?(Time) ? start_time : Time.parse(start_time.to_s)
          end_t = end_time.is_a?(Time) ? end_time : Time.parse(end_time.to_s)

          ((end_t - start_t) / 60).round(1)
        rescue StandardError
          nil
        end

        def format_pair_display(pair_id)
          return pair_id unless pair_id.include?(':')

          parts = pair_id.split(':')
          return pair_id if parts.size != 2

          low = format_venue_short(parts[0])
          high = format_venue_short(parts[1])

          "#{low}↔#{high}"
        end

        def format_venue_short(venue_key)
          exchange = venue_key.gsub(/_spot$|_futures$|_perp$|_dex$/, '').capitalize
          suffix = if venue_key.end_with?('_futures')
                     '-Fut'
                   elsif venue_key.end_with?('_spot')
                     '-Spot'
                   elsif venue_key.end_with?('_perp')
                     '-Perp'
                   else
                     '-DEX'
                   end

          "#{exchange}#{suffix}"
        end

        def format_duration(minutes)
          return '?' unless minutes

          if minutes < 60
            "#{minutes.round(0)}мин"
          elsif minutes < 1440
            hours = (minutes / 60).round(1)
            "#{hours}ч"
          else
            days = (minutes / 1440).round(1)
            "#{days}д"
          end
        end

        def format_outcome_line(outcome)
          initial = outcome[:spread_pct]&.round(1) || '?'
          final = outcome[:min_spread_pct]&.round(1) || '?'
          duration = format_duration_hm(outcome[:duration_min])

          # Format times
          start_time = format_time_hm(outcome[:started_at])
          end_time = format_time_hm(outcome[:converged_at])

          if outcome[:converged]
            # Show: "12.5% (10:15) → 4.1% (16:30) за 6ч15м ✅"
            if start_time && end_time
              "   • #{initial}% (#{start_time}) → #{final}% (#{end_time}) за #{duration} ✅"
            else
              "   • #{initial}% → #{final}% за #{duration} ✅"
            end
          elsif outcome[:diverged]
            "   • #{initial}% → ❌ разошелся до #{final}%"
          else
            "   • #{initial}% → #{final}% (expired)"
          end
        end

        def format_time_hm(time)
          return nil unless time

          t = time.is_a?(Time) ? time : Time.parse(time.to_s)
          t.strftime('%H:%M')
        rescue StandardError
          nil
        end

        def format_duration_hm(minutes)
          return '?' unless minutes

          if minutes < 60
            "#{minutes.round(0)}м"
          else
            hours = (minutes / 60).floor
            mins = (minutes % 60).round(0)
            mins > 0 ? "#{hours}ч#{mins}м" : "#{hours}ч"
          end
        end
      end
    end
  end
end
