# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Handles /taken and /result commands for trade tracking
      class TradeTracker
        class << self
          # Mark a signal as taken by user
          # @param signal_id [String] signal ID (full or short)
          # @param user_id [Integer] Telegram user ID
          # @return [Hash] result with :success and :message
          def take(signal_id, user_id)
            signal = SignalRepository.find(signal_id)

            return error_response("Signal `#{signal_id}` not found") unless signal

            if signal[:status] == 'taken'
              return error_response("Signal already taken at #{format_time(signal[:taken_at])}")
            end

            if signal[:status] == 'closed'
              return error_response('Signal already closed')
            end

            updated = SignalRepository.mark_taken(signal_id)
            return error_response('Failed to update signal') unless updated

            short_id = SignalRepository.short_id(updated[:id], updated[:strategy])

            success_response(
              "Signal `#{short_id}` marked as taken.\n" \
              "Use `/result #{short_id} +X%` to record the result."
            )
          end

          # Record trade result
          # @param signal_id [String] signal ID
          # @param pnl_str [String] PnL string like "+2.5%" or "-1.2%"
          # @param user_id [Integer] Telegram user ID
          # @param notes [String, nil] optional notes
          # @return [Hash] result with :success and :message
          def record_result(signal_id, pnl_str, user_id, notes: nil)
            signal = SignalRepository.find(signal_id)

            return error_response("Signal `#{signal_id}` not found") unless signal

            pnl_pct = parse_pnl(pnl_str)
            return error_response("Invalid PnL format: `#{pnl_str}`. Use +X% or -X%") unless pnl_pct

            # Calculate hold time
            hold_hours = if signal[:taken_at]
                           ((Time.now - Time.parse(signal[:taken_at].to_s)) / 3600.0).round(2)
                         end

            # Insert trade result
            sql = <<~SQL
              INSERT INTO trade_results (signal_id, user_id, pnl_pct, hold_hours, notes)
              VALUES ($1, $2, $3, $4, $5)
              RETURNING *
            SQL

            result = DatabaseConnection.query_one(sql, [
              signal[:id],
              user_id,
              pnl_pct,
              hold_hours,
              notes
            ])

            return error_response('Failed to record result') unless result

            # Mark signal as closed
            SignalRepository.mark_closed(signal_id)

            short_id = SignalRepository.short_id(signal[:id], signal[:strategy])
            emoji = pnl_pct >= 0 ? '🟢' : '🔴'

            success_response(
              "#{emoji} Result recorded for `#{short_id}`\n" \
              "PnL: #{format_pnl(pnl_pct)}\n" \
              "#{hold_hours ? "Hold: #{hold_hours}h" : ''}"
            )
          rescue StandardError => e
            ArbitrageBot.logger.error("[TradeTracker] record_result error: #{e.message}")
            error_response('Failed to record result')
          end

          # Get trading statistics
          # @param user_id [Integer, nil] optional user filter
          # @param strategy [String, nil] optional strategy filter
          # @param days [Integer] lookback period
          # @return [Hash] statistics
          def stats(user_id: nil, strategy: nil, days: 30)
            cutoff = Time.now - (days * 86_400)

            conditions = ['tr.recorded_at >= $1']
            params = [cutoff]

            if user_id
              params << user_id
              conditions << "tr.user_id = $#{params.size}"
            end

            if strategy
              params << strategy
              conditions << "s.strategy = $#{params.size}"
            end

            sql = <<~SQL
              SELECT
                COUNT(*) as total_trades,
                COUNT(*) FILTER (WHERE tr.pnl_pct > 0) as winning_trades,
                COUNT(*) FILTER (WHERE tr.pnl_pct < 0) as losing_trades,
                COUNT(*) FILTER (WHERE tr.pnl_pct = 0) as breakeven_trades,
                ROUND(AVG(tr.pnl_pct)::numeric, 2) as avg_pnl,
                ROUND(SUM(tr.pnl_pct)::numeric, 2) as total_pnl,
                ROUND(MAX(tr.pnl_pct)::numeric, 2) as best_trade,
                ROUND(MIN(tr.pnl_pct)::numeric, 2) as worst_trade,
                ROUND(AVG(tr.hold_hours)::numeric, 1) as avg_hold_hours
              FROM trade_results tr
              JOIN signals s ON tr.signal_id = s.id
              WHERE #{conditions.join(' AND ')}
            SQL

            DatabaseConnection.query_one(sql, params) || empty_stats
          rescue StandardError => e
            ArbitrageBot.logger.error("[TradeTracker] stats error: #{e.message}")
            empty_stats
          end

          # Get stats grouped by strategy
          # @param days [Integer] lookback period
          # @return [Array<Hash>] stats per strategy
          def stats_by_strategy(days: 30)
            cutoff = Time.now - (days * 86_400)

            sql = <<~SQL
              SELECT
                s.strategy,
                COUNT(*) as total_trades,
                COUNT(*) FILTER (WHERE tr.pnl_pct > 0) as winning_trades,
                ROUND(AVG(tr.pnl_pct)::numeric, 2) as avg_pnl,
                ROUND(SUM(tr.pnl_pct)::numeric, 2) as total_pnl,
                ROUND(MIN(tr.pnl_pct)::numeric, 2) as worst_trade
              FROM trade_results tr
              JOIN signals s ON tr.signal_id = s.id
              WHERE tr.recorded_at >= $1
              GROUP BY s.strategy
              ORDER BY total_trades DESC
            SQL

            DatabaseConnection.query_all(sql, [cutoff])
          rescue StandardError => e
            ArbitrageBot.logger.error("[TradeTracker] stats_by_strategy error: #{e.message}")
            []
          end

          # Format stats for Telegram
          # @param days [Integer] lookback period
          # @return [String] formatted message
          def format_stats_message(days: 30)
            overall = stats(days: days)
            by_strategy = stats_by_strategy(days: days)

            lines = [
              "📊 СТАТИСТИКА (#{days}д)",
              "━" * 30,
              ""
            ]

            if overall[:total_trades].to_i.zero?
              lines << "Нет записанных результатов."
              return lines.join("\n")
            end

            # Overall stats
            win_rate = calculate_win_rate(overall[:winning_trades], overall[:total_trades])
            lines << "📈 ОБЩИЕ:"
            lines << "  Сделок: #{overall[:total_trades]}"
            lines << "  Win rate: #{win_rate}"
            lines << "  Avg PnL: #{format_pnl(overall[:avg_pnl])}"
            lines << "  Total PnL: #{format_pnl(overall[:total_pnl])}"
            lines << "  Best: #{format_pnl(overall[:best_trade])}"
            lines << "  Worst: #{format_pnl(overall[:worst_trade])}"
            lines << ""

            # Per-strategy stats
            by_strategy.each do |strat|
              name = format_strategy_name(strat[:strategy])
              win_rate = calculate_win_rate(strat[:winning_trades], strat[:total_trades])

              lines << "#{name}:"
              lines << "  Сделок: #{strat[:total_trades]} | Win: #{win_rate}"
              lines << "  Avg: #{format_pnl(strat[:avg_pnl])} | Total: #{format_pnl(strat[:total_pnl])}"
              lines << ""
            end

            lines << "⚠️ Данные из ручного /result"

            lines.join("\n")
          end

          private

          def parse_pnl(str)
            return nil unless str

            # Match patterns like "+2.5%", "-1.2%", "2.5", "+2.5"
            if str =~ /^([+-])?(\d+(?:\.\d+)?)\s*%?$/
              sign = $1 == '-' ? -1 : 1
              value = $2.to_f
              sign * value
            end
          end

          def format_pnl(value)
            return 'N/A' unless value

            pnl = value.to_f
            sign = pnl >= 0 ? '+' : ''
            "#{sign}#{pnl.round(2)}%"
          end

          def format_time(time)
            return 'N/A' unless time

            Time.parse(time.to_s).strftime('%Y-%m-%d %H:%M')
          end

          def format_strategy_name(strategy)
            case strategy
            when 'spatial_hedged' then '🔥 SPATIAL HEDGED'
            when 'spatial_manual' then '⚠️ SPATIAL MANUAL'
            when 'funding' then '💰 FUNDING'
            when 'funding_spread' then '🔥 FUNDING SPREAD'
            when 'zscore' then '📊 STAT ARB'
            when 'depeg' then '🚨 DEPEG'
            else strategy.upcase
            end
          end

          def calculate_win_rate(wins, total)
            return '0%' if total.to_i.zero?

            rate = (wins.to_f / total.to_f * 100).round(0)
            "#{rate}% (#{wins}/#{total})"
          end

          def success_response(message)
            { success: true, message: message }
          end

          def error_response(message)
            { success: false, message: "❌ #{message}" }
          end

          def empty_stats
            {
              total_trades: 0,
              winning_trades: 0,
              losing_trades: 0,
              breakeven_trades: 0,
              avg_pnl: nil,
              total_pnl: nil,
              best_trade: nil,
              worst_trade: nil,
              avg_hold_hours: nil
            }
          end
        end
      end
    end
  end
end
