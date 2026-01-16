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
          @settings_loader = SettingsLoader.new
          @flip_detector = FundingFlipDetector.new
        end

        # Check rates and generate alerts
        # @param rates [Array<Hash>] funding rates from FundingCollector
        # @return [Array<Hash>] generated alerts
        def check_and_alert(rates)
          # Check if funding alerts are enabled
          settings = @settings_loader.load
          unless settings[:enable_funding_alerts] != false
            @logger.debug("[FundingAlerter] Funding alerts disabled in settings")
            return []
          end

          alerts = []

          # Record all rates to history for flip detection
          rates.each { |r| @flip_detector.record_rate(r) }

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

          # Check for funding flips (exit signals)
          exit_signals = @flip_detector.check_for_exits(rates)
          exit_signals.each do |signal|
            alert = create_exit_alert(signal)
            if alert && send_exit_alert(alert)
              alerts << alert
              # Deactivate position after exit alert
              @flip_detector.deactivate_position(signal[:symbol], signal[:venue])
            end
          end

          alerts
        end

        # Activate position tracking (call after user enters position)
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        def activate_position(symbol, venue)
          @flip_detector.activate_position(symbol, venue)
        end

        # Get funding history analysis
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @return [String] formatted history
        def funding_history(symbol, venue)
          @flip_detector.format_history(symbol, venue)
        end

        # Get active positions list
        # @return [Array<String>] position keys
        def active_positions
          @flip_detector.get_active_positions
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
              # Auto-activate position tracking for this symbol/venue
              @flip_detector.activate_position(symbol, rate[:venue])
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

        def create_exit_alert(signal)
          symbol = signal[:symbol]
          venue = signal[:venue]
          current_rate = signal[:current_rate]
          consecutive = signal[:consecutive_negatives]
          avg_negative = signal[:avg_negative_rate]
          history = signal[:history] || []

          # Get current price
          price = get_current_price(symbol)

          # Format history section
          history_lines = history.first(5).map.with_index do |h, i|
            rate_pct = (h[:rate].to_f * 100).round(4)
            emoji = h[:positive] ? '🟢' : '🔴'
            "   #{emoji} #{rate_pct}%"
          end.join("\n")

          message = <<~MSG
            🚨 FUNDING EXIT | #{symbol} | #{venue}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            ⚠️ #{consecutive} CONSECUTIVE NEGATIVE PERIODS

            📊 ТЕКУЩИЙ RATE:
               #{format_rate(current_rate)}/8h (негативный)
               Среднее за период: #{format_rate(avg_negative)}/8h

            📈 ПОСЛЕДНИЕ ПЕРИОДЫ:
            #{history_lines}

            💰 РЕКОМЕНДАЦИЯ:
            • Закрыть позицию #{symbol} на #{venue}
            • Spot LONG → продать
            • Perp SHORT → закрыть

            ⏰ СРОЧНОСТЬ: ВЫСОКАЯ
               Продолжение негативного funding = потери

            📝 После закрытия отметьте:
               /result [id] +X% или -X%
          MSG

          {
            type: :funding_exit,
            symbol: symbol,
            venue: venue,
            current_rate: current_rate,
            consecutive_negatives: consecutive,
            avg_negative_rate: avg_negative,
            message: message.strip
          }
        end

        def send_exit_alert(alert)
          # Create signal in database
          db_signal = Analytics::SignalRepository.create(
            strategy: 'funding_exit',
            class: 'risk_premium',
            symbol: alert[:symbol],
            details: alert.except(:message)
          )

          signal_id = db_signal ? Analytics::SignalRepository.short_id(db_signal[:id], 'funding_exit') : nil
          message = alert[:message]
          message = "#{message}\n\nID: `#{signal_id}`" if signal_id

          result = @notifier.send_alert(message)

          if result && db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          result
        rescue StandardError => e
          @logger.error("[FundingAlerter] send_exit_alert error: #{e.message}")
          nil
        end

        def create_high_funding_alert(symbol, rate, all_rates)
          sorted = all_rates.sort_by { |r| -r[:rate].to_f }

          # Get funding history
          history = get_funding_history(symbol, rate[:venue])
          history_section = format_history_section(history)

          # Get current price and calculate position
          position_usd = 10_000
          price = get_current_price(symbol)
          position_tokens = price && price > 0 ? (position_usd / price).round(4) : 0

          # Calculate expected daily profit
          rate_per_period = rate[:rate].to_f
          periods_per_day = 3  # 8h periods
          daily_profit_pct = rate_per_period * periods_per_day * 100
          daily_profit_usd = (position_usd * daily_profit_pct / 100).round(2)

          # Get liquidity info
          liquidity = get_liquidity(symbol, rate[:venue])
          liquidity_section = format_liquidity_section(liquidity, position_usd)

          message = <<~MSG
            💰 FUNDING | #{symbol} | #{format_rate(rate[:rate])}/8h
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📊 RATES:
            #{sorted.first(4).map { |r| "   #{r[:venue]}: #{format_rate(r[:rate])} (#{r[:annualized_pct]}% APR)" }.join("\n")}

            #{history_section}
            💰 ПОЗИЦИЯ ($#{format_number(position_usd)}):
            • #{format_tokens(position_tokens)} #{symbol} @ $#{format_price(price)}
            • LONG #{symbol} Spot + SHORT #{symbol} Perp (#{rate[:venue]})

            💹 ОЖИДАЕМАЯ ПРИБЫЛЬ:
            • ~#{daily_profit_pct.round(3)}%/день ($#{daily_profit_usd})
            • ~#{rate[:annualized_pct]}% APR

            #{liquidity_section}
            📝 ИНСТРУКЦИЯ:
            1. Купить #{format_tokens(position_tokens)} #{symbol} на споте
            2. Открыть SHORT #{format_tokens(position_tokens)} #{symbol} на #{rate[:venue]}
            3. Собирать funding каждые 8 часов
            4. Выход при funding < 0.01% или 3 отрицательных периода
          MSG

          {
            type: :high_funding,
            symbol: symbol,
            venue: rate[:venue],
            rate: rate[:rate],
            annualized_pct: rate[:annualized_pct],
            history: history,
            position_usd: position_usd,
            message: message.strip
          }
        end

        def create_spread_alert(symbol, high_rate, low_rate, spread)
          spread_apr = annualize_spread(spread)

          # Get current price and calculate position
          position_usd = 10_000
          price = get_current_price(symbol)
          position_tokens = price && price > 0 ? (position_usd / price).round(4) : 0

          # Calculate expected daily profit
          spread_per_period = spread.to_f
          periods_per_day = 3  # 8h periods
          daily_profit_pct = spread_per_period * periods_per_day * 100
          daily_profit_usd = (position_usd * daily_profit_pct / 100).round(2)

          message = <<~MSG
            🔥 FUNDING SPREAD | #{symbol} | #{format_rate(spread)}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📊 CROSS-VENUE:
               #{high_rate[:venue]}: #{format_rate(high_rate[:rate])}/8h (HIGH)
               #{low_rate[:venue]}: #{format_rate(low_rate[:rate])}/8h (LOW)
               Spread: #{format_rate(spread)}/8h (#{spread_apr}% APR)

            💰 ПОЗИЦИЯ ($#{format_number(position_usd)}):
            • #{format_tokens(position_tokens)} #{symbol} @ $#{format_price(price)}
            • LONG на #{low_rate[:venue]} + SHORT на #{high_rate[:venue]}

            💹 ОЖИДАЕМАЯ ПРИБЫЛЬ:
            • ~#{daily_profit_pct.round(3)}%/день ($#{daily_profit_usd})
            • ~#{spread_apr}% APR

            📝 ИНСТРУКЦИЯ:
            1. Открыть LONG #{format_tokens(position_tokens)} #{symbol} на #{low_rate[:venue]}
            2. Открыть SHORT #{format_tokens(position_tokens)} #{symbol} на #{high_rate[:venue]}
            3. Собирать funding spread каждые 8 часов
            4. Выход при spread < 0.01%
          MSG

          {
            type: :funding_spread,
            symbol: symbol,
            high_venue: high_rate[:venue],
            low_venue: low_rate[:venue],
            spread: spread,
            spread_apr: spread_apr,
            position_usd: position_usd,
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

          lines = ["📈 HISTORY (#{history[:days]}d):"]
          lines << "   Average: #{format_rate(history[:avg_rate])}"

          if history[:consecutive_positive] > 0
            lines << "   Consecutive positive: #{history[:consecutive_positive]} periods"
          end

          lines.join("\n") + "\n\n"
        end

        def get_current_price(symbol)
          # Try to get price from Redis cache
          prices_data = ArbitrageBot.redis.get('prices:latest')
          return nil unless prices_data

          prices = JSON.parse(prices_data)

          # Try different key formats
          ['binance_futures', 'bybit_futures', 'okx_futures'].each do |exchange|
            key = "#{exchange}:#{symbol}"
            if prices[key] && prices[key]['last']
              return prices[key]['last'].to_f
            end
          end

          nil
        rescue StandardError => e
          @logger.debug("[FundingAlerter] get_current_price error: #{e.message}")
          nil
        end

        def get_liquidity(symbol, venue)
          # Get orderbook depth from cache
          key = "orderbook:#{venue}:#{symbol}"
          data = ArbitrageBot.redis.get(key)
          return nil unless data

          JSON.parse(data, symbolize_names: true)
        rescue StandardError
          nil
        end

        def format_liquidity_section(liquidity, position_usd)
          return "" unless liquidity

          bids_usd = liquidity[:bids_usd].to_f
          asks_usd = liquidity[:asks_usd].to_f
          min_liq = [bids_usd, asks_usd].min
          ratio = position_usd > 0 ? ((min_liq / position_usd) * 100).round(0) : 0

          <<~LIQ
            💧 ЛИКВИДНОСТЬ:
            • Bids: $#{format_number(bids_usd)}
            • Asks: $#{format_number(asks_usd)}
            • Позиция vs ликвидность: #{ratio}% #{ratio >= 100 ? "✅" : "⚠️"}

          LIQ
        end

        def format_tokens(tokens)
          tokens = tokens.to_f
          if tokens >= 1_000_000
            "#{(tokens / 1_000_000).round(2)}M"
          elsif tokens >= 1_000
            "#{(tokens / 1_000).round(2)}K"
          elsif tokens >= 1
            tokens.round(2).to_s
          else
            tokens.round(6).to_s
          end
        end

        def format_price(price)
          return '0' unless price
          price = price.to_f
          if price < 0.0001
            sprintf('%.8f', price)
          elsif price < 1
            sprintf('%.4f', price)
          else
            sprintf('%.2f', price)
          end
        end

        def format_number(num)
          return '0' unless num
          num = num.to_f
          if num >= 1_000_000
            "#{(num / 1_000_000).round(1)}M"
          elsif num >= 1_000
            "#{(num / 1_000).round(1)}K"
          else
            num.round(0).to_s
          end
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
