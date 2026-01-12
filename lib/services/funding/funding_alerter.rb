# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Funding
      # Generates alerts for high funding rates and cross-venue spreads
      class FundingAlerter
        # Alert thresholds (configurable)
        MIN_FUNDING_RATE = 0.0003       # 0.03% per 8h for high funding alert
        MIN_FUNDING_SPREAD = 0.0002     # 0.02% spread between venues
        MIN_ANNUALIZED_PCT = 30.0       # 30% APR minimum for alert

        COOLDOWN_KEY = 'funding:alert_cooldown:'
        DEFAULT_COOLDOWN_SECONDS = 3600  # 1 hour between alerts for same symbol

        def initialize(settings = {})
          @min_rate = settings[:min_funding_rate] || MIN_FUNDING_RATE
          @min_spread = settings[:min_funding_spread] || MIN_FUNDING_SPREAD
          @min_apr = settings[:min_annualized_pct] || MIN_ANNUALIZED_PCT
          @cooldown_seconds = settings[:funding_alert_cooldown] || DEFAULT_COOLDOWN_SECONDS
          @logger = ArbitrageBot.logger
          @notifier = Telegram::TelegramNotifier.new
        end

        # Check rates and generate alerts
        # @param rates [Array<Hash>] funding rates from FundingCollector
        # @return [Array<Hash>] generated alerts
        def check_and_alert(rates)
          alerts = []

          # Group by symbol
          by_symbol = rates.group_by { |r| r[:symbol] }

          by_symbol.each do |symbol, symbol_rates|
            # Check for high funding on any venue
            high_alerts = check_high_funding(symbol, symbol_rates)
            alerts.concat(high_alerts)

            # Check for cross-venue spread
            spread_alert = check_funding_spread(symbol, symbol_rates)
            alerts << spread_alert if spread_alert
          end

          alerts
        end

        # Format all funding rates for display (menu view)
        # @return [String] formatted message
        def format_funding_message
          collector = FundingCollector.new
          all_rates = collector.all_rates

          if all_rates.empty?
            return "No funding data available. Waiting for rate collection."
          end

          lines = [
            "💰 FUNDING RATES",
            "━" * 30,
            ""
          ]

          # Get highest rates by symbol
          by_symbol = all_rates.group_by { |r| r[:symbol] }
          top_symbols = by_symbol.map do |sym, rates|
            max = rates.max_by { |r| r[:rate].to_f }
            { symbol: sym, rate: max[:rate], venue: max[:venue], annualized: max[:annualized_pct] }
          end

          # Sort by rate descending
          top_symbols.sort_by! { |s| -s[:rate].to_f }

          # Show top 15
          top_symbols.first(15).each do |s|
            emoji = s[:rate].to_f >= MIN_FUNDING_RATE ? "🔥" : "💰"
            lines << "#{emoji} #{s[:symbol]}: #{format_rate(s[:rate])}/8h"
            lines << "   #{s[:venue]} (#{s[:annualized]}% APR)"
            lines << ""
          end

          if top_symbols.size > 15
            lines << "... +#{top_symbols.size - 15} more symbols"
          end

          lines << "Min alert: #{format_rate(MIN_FUNDING_RATE)}/8h (#{MIN_ANNUALIZED_PCT}% APR)"
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end

        # Format funding rates for display
        # @param rates [Array<Hash>] rates for a symbol
        # @return [String] formatted message
        def format_rates_message(symbol, rates)
          return "No funding data for #{symbol}" if rates.empty?

          sorted = rates.sort_by { |r| -r[:rate].to_f }
          max_rate = sorted.first

          lines = [
            "💰 FUNDING | #{symbol}",
            "━" * 30,
            ""
          ]

          sorted.first(5).each do |r|
            emoji = r == max_rate ? " ← MAX" : ""
            lines << "#{r[:venue]}: #{format_rate(r[:rate])} (#{r[:annualized_pct]}% APR)#{emoji}"
          end

          if sorted.size > 5
            lines << "... +#{sorted.size - 5} more"
          end

          lines << ""
          lines << "Spread: #{format_rate(sorted.first[:rate] - sorted.last[:rate])}"
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end

        private

        def check_high_funding(symbol, rates)
          alerts = []

          rates.each do |rate|
            next unless rate[:rate].to_f >= @min_rate
            next unless rate[:annualized_pct].to_f >= @min_apr

            alert = create_high_funding_alert(symbol, rate, rates)
            if alert && send_alert(alert)
              alerts << alert
              log_alert(alert)
            end
          end

          alerts
        end

        def check_funding_spread(symbol, rates)
          return nil if rates.size < 2

          sorted = rates.sort_by { |r| r[:rate].to_f }
          min_rate = sorted.first
          max_rate = sorted.last

          spread = max_rate[:rate].to_f - min_rate[:rate].to_f
          return nil if spread < @min_spread

          alert = create_spread_alert(symbol, max_rate, min_rate, spread)
          if send_alert(alert)
            log_alert(alert)
            alert
          end
        end

        def create_high_funding_alert(symbol, rate, all_rates)
          sorted = all_rates.sort_by { |r| -r[:rate].to_f }

          # Get funding history
          history = get_funding_history(symbol, rate[:venue])
          history_section = format_history_section(history)

          message = <<~MSG
            💰 FUNDING | #{symbol} | #{format_rate(rate[:rate])}/8h
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📊 RATES:
            #{sorted.first(4).map { |r| "   #{r[:venue]}: #{format_rate(r[:rate])} (#{r[:annualized_pct]}% APR)" }.join("\n")}

            #{history_section}
            💡 СТРАТЕГИЯ:
               LONG #{symbol} Spot + SHORT #{symbol} Perp (#{rate[:venue]})

            ⚠️ КЛАСС: Risk-premium capture
               Риск: funding flip

            📍 ВЫХОД:
               • Funding < 0.01%
               • 3 периода отрицательный
          MSG

          {
            type: :high_funding,
            symbol: symbol,
            venue: rate[:venue],
            rate: rate[:rate],
            annualized_pct: rate[:annualized_pct],
            history: history,
            message: message.strip
          }
        end

        def create_spread_alert(symbol, high_rate, low_rate, spread)
          spread_apr = annualize_spread(spread)

          message = <<~MSG
            🔥 FUNDING SPREAD | #{symbol} | #{format_rate(spread)}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📊 CROSS-VENUE:
               #{high_rate[:venue]}: #{format_rate(high_rate[:rate])}/8h (HIGH)
               #{low_rate[:venue]}: #{format_rate(low_rate[:rate])}/8h (LOW)
               Spread: #{format_rate(spread)}/8h (#{spread_apr}% APR)

            💡 СТРАТЕГИЯ:
               LONG #{low_rate[:venue]} Perp + SHORT #{high_rate[:venue]} Perp

            ⚠️ КЛАСС: Risk-premium + #{high_rate[:venue_type] == 'dex_perp' ? 'Smart contract risk' : 'Counterparty risk'}
          MSG

          {
            type: :funding_spread,
            symbol: symbol,
            high_venue: high_rate[:venue],
            low_venue: low_rate[:venue],
            spread: spread,
            spread_apr: spread_apr,
            message: message.strip
          }
        end

        def send_alert(alert)
          # Create signal in database
          strategy = alert[:type] == :high_funding ? 'funding' : 'funding_spread'
          db_signal = Analytics::SignalRepository.create(
            strategy: strategy,
            class: 'risk_premium',
            symbol: alert[:symbol],
            details: alert.except(:message)
          )

          signal_id = db_signal ? Analytics::SignalRepository.short_id(db_signal[:id], strategy) : nil
          message = alert[:message]
          message = "#{message}\n\nID: `#{signal_id}`\n/taken #{signal_id}" if signal_id

          result = @notifier.send_alert(message)

          if result && db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          result
        rescue StandardError => e
          @logger.error("[FundingAlerter] send_alert error: #{e.message}")
          nil
        end

        def log_alert(alert)
          Analytics::PostgresLogger.log_funding(
            symbol: alert[:symbol],
            venue: alert[:venue] || alert[:high_venue],
            venue_type: 'cex_perp',
            rate: alert[:rate] || alert[:spread],
            period_hours: 8,
            next_funding_ts: nil
          )
        rescue StandardError => e
          @logger.error("[FundingAlerter] log_alert error: #{e.message}")
        end

        def format_rate(rate)
          pct = (rate.to_f * 100).round(4)
          "#{pct}%"
        end

        def annualize_spread(spread)
          periods_per_year = (365.0 * 24) / 8
          (spread.to_f * periods_per_year * 100).round(0)
        end

        def get_funding_history(symbol, venue, days: 7)
          sql = <<~SQL
            SELECT
              rate,
              ts
            FROM funding_log
            WHERE symbol = $1 AND venue = $2
              AND ts > NOW() - INTERVAL '#{days} days'
            ORDER BY ts DESC
            LIMIT 100
          SQL

          rows = Analytics::DatabaseConnection.query_all(sql, [symbol, venue])

          return nil if rows.nil? || rows.empty?

          rates = rows.map { |r| r['rate'].to_f }
          avg_rate = rates.sum / rates.size

          # Count consecutive positive periods
          consecutive_positive = 0
          rows.each do |r|
            if r['rate'].to_f > 0
              consecutive_positive += 1
            else
              break
            end
          end

          {
            avg_rate: avg_rate,
            count: rows.size,
            consecutive_positive: consecutive_positive,
            days: days
          }
        rescue StandardError => e
          @logger.debug("[FundingAlerter] get_funding_history error: #{e.message}")
          nil
        end

        def format_history_section(history)
          return "" unless history && history[:count] > 0

          lines = ["📈 ИСТОРИЯ (#{history[:days]}д):"]
          lines << "   Средний: #{format_rate(history[:avg_rate])}"

          if history[:consecutive_positive] > 0
            lines << "   Подряд положительный: #{history[:consecutive_positive]} периодов"
          end

          lines.join("\n") + "\n"
        end

        def on_cooldown?(symbol)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{symbol}"
          redis.exists?(key)
        rescue StandardError
          false
        end

        def set_cooldown(symbol)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{symbol}"
          redis.setex(key, @cooldown_seconds, '1')
        rescue StandardError => e
          @logger.error("[FundingAlerter] set_cooldown error: #{e.message}")
        end
      end
    end
  end
end
