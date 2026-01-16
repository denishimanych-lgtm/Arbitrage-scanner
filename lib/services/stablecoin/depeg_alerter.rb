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

        # Exchange trading URLs
        EXCHANGE_URLS = {
          'binance' => {
            spot: 'https://www.binance.com/en/trade/%{symbol}_USDT'
          },
          'bybit' => {
            spot: 'https://www.bybit.com/en/trade/spot/%{symbol}/USDT'
          },
          'okx' => {
            spot: 'https://www.okx.com/trade-spot/%{symbol}-usdt'
          },
          'gate' => {
            spot: 'https://www.gate.io/trade/%{symbol}_USDT'
          },
          'kucoin' => {
            spot: 'https://www.kucoin.com/trade/%{symbol}-USDT'
          }
        }.freeze

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

          # Price should always be valid at this point - if not, it's a bug
          if price.nil? || price <= 0
            @logger.error("[DepegAlerter] BUG: Invalid price for #{symbol}: #{price} - check price fetching!")
            return nil
          end

          is_severe = price < ENTRY_HINT_THRESHOLD

          emoji = is_severe ? "🚨🚨" : "🚨"
          severity = is_severe ? "SEVERE DEPEG" : "DEPEG"

          direction = price < 1.0 ? "BELOW PEG" : "ABOVE PEG"
          dev_str = deviation >= 0 ? "+#{deviation}%" : "#{deviation}%"

          # Position sizing
          position_usd = 10_000
          position_tokens = price > 0 ? (position_usd / price).round(2) : 0

          # Expected profit if re-peg
          discount_pct = ((1.0 - price) * 100).abs.round(2)
          expected_profit = (position_usd * discount_pct / 100).round(0)

          # Get liquidity info
          liquidity = get_stablecoin_liquidity(symbol)
          liquidity_section = format_liquidity_section(liquidity, position_usd)

          # Get Curve 3pool status
          curve_section = get_curve_section(symbol)

          # Get trading links
          links_section = format_trading_links(symbol)

          message = <<~MSG
            #{emoji} #{severity} | #{symbol} | $#{price.round(4)}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📉 СТАТУС: #{direction}
               Цена: $#{price.round(6)}
               Отклонение: #{dev_str}
               Источник: #{price_data[:source]}

            #{curve_section}
            💰 ПОЗИЦИЯ ($#{format_number(position_usd)}):
            • #{format_tokens(position_tokens)} #{symbol} @ $#{format_price(price)}

            💹 ОЖИДАЕМАЯ ПРИБЫЛЬ (при re-peg):
            • Discount: #{discount_pct}%
            • Profit: ~$#{expected_profit}

            #{liquidity_section}
            📝 ИНСТРУКЦИЯ:
            #{strategy_instructions(symbol, price, is_severe, position_tokens)}

            📍 ВЫХОД:
            • Take profit: цена > $0.995
            • Stop loss: -#{is_severe ? '5' : '3'}% от входа
            #{is_severe ? '⚠️ EXTREME CAUTION - возможен полный коллапс!' : ''}

            #{links_section}
          MSG

          {
            type: is_severe ? :severe_depeg : :depeg,
            symbol: symbol,
            price: price,
            deviation_pct: deviation,
            source: price_data[:source],
            position_usd: position_usd,
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

        def strategy_instructions(symbol, price, is_severe, position_tokens)
          if price < 1.0
            if is_severe
              <<~INST.strip
                1. Купить #{format_tokens(position_tokens)} #{symbol} @ $#{format_price(price)}
                2. ⚠️ ТОЛЬКО на сумму, которую готов потерять!
                3. Ждать re-peg или stop loss
              INST
            else
              <<~INST.strip
                1. Рассмотреть покупку #{format_tokens(position_tokens)} #{symbol}
                2. Дождаться подтверждения re-peg или доп. слабости
                3. Выход при $0.995+ или stop loss
              INST
            end
          else
            <<~INST.strip
              1. Продать #{format_tokens(position_tokens)} #{symbol} @ $#{format_price(price)}
              2. Или арбитраж vs другие стейблкоины
            INST
          end
        end

        def get_stablecoin_liquidity(symbol)
          # Try to get liquidity from major exchanges
          liquidity = { total_bids: 0, total_asks: 0 }

          %w[binance bybit okx].each do |exchange|
            key = "orderbook:#{exchange}_spot:#{symbol}"
            data = ArbitrageBot.redis.get(key)
            next unless data

            ob = JSON.parse(data, symbolize_names: true)
            liquidity[:total_bids] += ob[:bids_usd].to_f if ob[:bids_usd]
            liquidity[:total_asks] += ob[:asks_usd].to_f if ob[:asks_usd]
          rescue StandardError
            next
          end

          liquidity[:total_bids] > 0 || liquidity[:total_asks] > 0 ? liquidity : nil
        rescue StandardError
          nil
        end

        def format_liquidity_section(liquidity, position_usd)
          return "" unless liquidity

          bids_usd = liquidity[:total_bids].to_f
          asks_usd = liquidity[:total_asks].to_f
          min_liq = [bids_usd, asks_usd].min
          ratio = position_usd > 0 && min_liq > 0 ? ((min_liq / position_usd) * 100).round(0) : 0

          return "" if bids_usd == 0 && asks_usd == 0

          <<~LIQ
            💧 ЛИКВИДНОСТЬ ВЫХОДА:
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
          else
            tokens.round(2).to_s
          end
        end

        def format_price(price)
          return '0' unless price
          price = price.to_f
          sprintf('%.4f', price)
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

        def format_trading_links(symbol)
          # Show only one exchange link (Binance preferred)
          exchange = 'binance'
          url_template = EXCHANGE_URLS.dig(exchange, :spot)
          return "" unless url_template

          url = url_template.gsub('%{symbol}', symbol.upcase)
          "🔗 ТОРГОВАТЬ: #{url}"
        end
      end
    end
  end
end
