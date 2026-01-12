# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Stablecoin
      # Generates alerts for stablecoin depegging events
      class DepegAlerter
        COOLDOWN_KEY = 'stablecoin:alert_cooldown:'
        DEFAULT_COOLDOWN_SECONDS = 1800  # 30 minutes between alerts for same coin

        # Alert thresholds
        ALERT_THRESHOLD = 0.99        # Alert when < $0.99
        ENTRY_HINT_THRESHOLD = 0.97   # Entry hint when < $0.97

        def initialize(settings = {})
          @logger = ArbitrageBot.logger
          @notifier = Telegram::TelegramNotifier.new
          @cooldown_seconds = settings[:stablecoin_alert_cooldown] || DEFAULT_COOLDOWN_SECONDS
          @alert_threshold = settings[:stablecoin_alert_threshold] || ALERT_THRESHOLD
        end

        # Check prices and generate alerts
        # @param prices [Array<Hash>] price data from DepegMonitor
        # @return [Array<Hash>] generated alerts
        def check_and_alert(prices)
          alerts = []

          prices.each do |price_data|
            next unless should_alert?(price_data)
            next if on_cooldown?(price_data[:symbol])

            alert = create_alert(price_data)
            if alert && send_alert(alert)
              alerts << alert
              set_cooldown(price_data[:symbol])
            end
          end

          alerts
        end

        # Format prices for /stables command
        # @param prices [Array<Hash>]
        # @return [String]
        def format_prices_message(prices)
          if prices.empty?
            return "No stablecoin data available. Waiting for price collection."
          end

          lines = [
            "💵 STABLECOIN MONITOR",
            "━" * 30,
            ""
          ]

          prices.each do |p|
            emoji = status_emoji(p[:status])
            deviation = p[:deviation_pct]
            dev_str = deviation >= 0 ? "+#{deviation}%" : "#{deviation}%"

            lines << "#{emoji} #{p[:symbol]}: $#{p[:price].round(4)} (#{dev_str})"
          end

          lines << ""
          lines << "Threshold: Alert < $#{@alert_threshold}"
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end

        private

        def should_alert?(price_data)
          return false unless price_data[:price]

          # Alert on depeg (below threshold or above 1.01)
          price_data[:price] < @alert_threshold || price_data[:price] > 1.01
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
          @logger.error("[DepegAlerter] set_cooldown error: #{e.message}")
        end

        def create_alert(price_data)
          symbol = price_data[:symbol]
          price = price_data[:price]
          deviation = price_data[:deviation_pct]
          is_severe = price < ENTRY_HINT_THRESHOLD

          emoji = is_severe ? "🚨🚨" : "🚨"
          severity = is_severe ? "SEVERE DEPEG" : "DEPEG"

          direction = price < 1.0 ? "BELOW PEG" : "ABOVE PEG"
          dev_str = deviation >= 0 ? "+#{deviation}%" : "#{deviation}%"

          # Get Curve 3pool status
          curve_section = get_curve_section(symbol)

          message = <<~MSG
            #{emoji} #{severity} | #{symbol} | $#{price.round(4)}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📉 STATUS: #{direction}
               Price: $#{price.round(6)}
               Deviation: #{dev_str}
               Source: #{price_data[:source]}

            #{curve_section}
            💡 СТРАТЕГИЯ:
               #{strategy_text(symbol, price, is_severe)}

            ⚠️ КЛАСС: Speculative (event-driven)
               Risk: Complete collapse possible
               #{is_severe ? '🛑 EXTREME CAUTION' : '⚠️ High risk'}

            📍 ВЫХОД:
               • Price returns to $0.995+
               • Or cut loss at -#{is_severe ? '5' : '3'}%
          MSG

          {
            type: is_severe ? :severe_depeg : :depeg,
            symbol: symbol,
            price: price,
            deviation_pct: deviation,
            source: price_data[:source],
            message: message.strip
          }
        end

        def strategy_text(symbol, price, is_severe)
          if price < 1.0
            if is_severe
              "BUY #{symbol} at discount (#{((1.0 - price) * 100).round(2)}% below peg)\n" \
                "   ⚠️ Only with size you can afford to lose"
            else
              "Consider BUY #{symbol} if confidence in re-peg\n" \
                "   Wait for further weakness or re-peg confirmation"
            end
          else
            "SELL #{symbol} at premium (#{((price - 1.0) * 100).round(2)}% above peg)\n" \
              "   Or arbitrage vs other stables"
          end
        end

        def send_alert(alert)
          # Create signal in database
          db_signal = Analytics::SignalRepository.create(
            strategy: 'stablecoin_depeg',
            class: 'speculative',
            symbol: alert[:symbol],
            details: alert.except(:message)
          )

          signal_id = db_signal ? Analytics::SignalRepository.short_id(db_signal[:id], 'stablecoin_depeg') : nil
          message = alert[:message]
          message = "#{message}\n\nID: `#{signal_id}`\n/taken #{signal_id}" if signal_id

          result = @notifier.send_alert(message)

          if result && db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          result
        rescue StandardError => e
          @logger.error("[DepegAlerter] send_alert error: #{e.message}")
          nil
        end

        def status_emoji(status)
          case status
          when :stable then "✅"
          when :minor_deviation then "📊"
          when :depegged then "⚠️"
          when :severe_depeg then "🚨"
          else "❓"
          end
        end

        def get_curve_section(symbol)
          # Only show Curve for 3pool stablecoins
          return "" unless %w[USDC USDT DAI].include?(symbol.upcase)

          curve_status = Adapters::Defi::CurveAdapter.format_3pool_status
          return "" unless curve_status

          "#{curve_status}\n\n"
        rescue StandardError => e
          @logger.debug("[DepegAlerter] get_curve_section error: #{e.message}")
          ""
        end
      end
    end
  end
end
