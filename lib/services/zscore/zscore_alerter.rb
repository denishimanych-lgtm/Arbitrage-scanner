# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Generates alerts for z-score deviations
      class ZScoreAlerter
        COOLDOWN_KEY = 'zscore:alert_cooldown:'
        DEFAULT_COOLDOWN_SECONDS = 3600  # 1 hour between alerts for same pair

        # Exchange trading URLs for futures
        EXCHANGE_URLS = {
          'binance' => 'https://www.binance.com/en/futures/%{symbol}USDT',
          'bybit' => 'https://www.bybit.com/trade/usdt/%{symbol}USDT',
          'okx' => 'https://www.okx.com/trade-swap/%{symbol}-usdt-swap',
          'hyperliquid' => 'https://app.hyperliquid.xyz/trade/%{symbol}'
        }.freeze

        def initialize(settings = {})
          @logger = ArbitrageBot.logger
          @notifier = Telegram::TelegramNotifier.new
          @cooldown_seconds = settings[:zscore_alert_cooldown] || DEFAULT_COOLDOWN_SECONDS
          @settings_loader = SettingsLoader.new
        end

        # Check z-scores and generate alerts
        # @param zscores [Array<Hash>] z-score data from ZScoreTracker
        # @return [Array<Hash>] generated alerts
        def check_and_alert(zscores)
          # Check if zscore alerts are enabled
          settings = @settings_loader.load
          unless settings[:enable_zscore_alerts] != false
            @logger.debug("[ZScoreAlerter] Z-Score alerts disabled in settings")
            return []
          end

          alerts = []

          zscores.each do |zscore_data|
            next unless should_alert?(zscore_data)
            next if on_cooldown?(zscore_data[:pair])

            alert = create_alert(zscore_data)
            if alert && send_alert(alert)
              alerts << alert
              set_cooldown(zscore_data[:pair])
            end
          end

          alerts
        end

        # Format z-scores for /zscores command
        # @param zscores [Array<Hash>]
        # @return [String]
        def format_zscores_message(zscores)
          if zscores.empty?
            return "No z-score data available. Waiting for price data collection."
          end

          lines = [
            "📊 Z-SCORE MONITOR",
            "━" * 30,
            ""
          ]

          # Sort by absolute z-score descending
          sorted = zscores.sort_by { |z| -(z[:zscore]&.abs || 0) }

          sorted.each do |z|
            if z[:zscore]
              emoji = status_emoji(z[:status])
              zscore_str = format_zscore(z[:zscore])
              lines << "#{emoji} #{z[:pair]}: Z = #{zscore_str}"
              lines << "   Ratio: #{z[:ratio].round(4)} | μ: #{z[:mean]&.round(4)} | σ: #{z[:std]&.round(4)}"
            else
              lines << "⏳ #{z[:pair]}: Collecting data (#{z[:count]}/#{z[:required]})"
            end
            lines << ""
          end

          thresholds = PairsConfig.thresholds
          lines << "Thresholds: Entry |z|>#{thresholds[:entry]} | Stop |z|>#{thresholds[:stop]}"
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end

        private

        def should_alert?(zscore_data)
          return false unless zscore_data[:zscore]
          return false if zscore_data[:status] == :insufficient_data

          zscore_data[:status] == :entry_signal || zscore_data[:status] == :stop_loss
        end

        def on_cooldown?(pair_str)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{pair_str}"
          redis.exists?(key)
        rescue StandardError
          false
        end

        def set_cooldown(pair_str)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{pair_str}"
          redis.setex(key, @cooldown_seconds, '1')
        rescue StandardError => e
          @logger.error("[ZScoreAlerter] set_cooldown error: #{e.message}")
        end

        def create_alert(zscore_data)
          pair = zscore_data[:pair]
          base, quote = pair.split('/')
          zscore = zscore_data[:zscore]
          is_stop = zscore_data[:status] == :stop_loss

          # Get prices
          base_price = get_current_price(base)
          quote_price = get_current_price(quote)

          # Both prices should be valid - if not, it's a bug in price collection
          if (base_price.nil? || base_price <= 0) || (quote_price.nil? || quote_price <= 0)
            @logger.error("[ZScoreAlerter] BUG: Invalid prices for #{pair}: base=#{base_price}, quote=#{quote_price} - check price fetching!")
            return nil
          end

          # Position sizing - $10K total, split between base and quote
          position_usd = 10_000
          half_position = position_usd / 2

          # Calculate token amounts
          base_tokens = base_price && base_price > 0 ? (half_position / base_price) : 0
          quote_tokens = quote_price && quote_price > 0 ? (half_position / quote_price) : 0

          # Determine direction based on zscore sign
          # Positive Z = ratio HIGH = base overvalued relative to quote
          # Negative Z = ratio LOW = base undervalued relative to quote
          if zscore > 0
            direction = "↑ HIGH"
            # Entry: SHORT base (overvalued) / LONG quote (undervalued)
            entry_base_action = "SHORT"
            entry_quote_action = "LONG"
            # Exit (close position): BUY base / SELL quote
            close_base_action = "BUY"
            close_quote_action = "SELL"
          else
            direction = "↓ LOW"
            # Entry: LONG base (undervalued) / SHORT quote (overvalued)
            entry_base_action = "LONG"
            entry_quote_action = "SHORT"
            # Exit (close position): SELL base / BUY quote
            close_base_action = "SELL"
            close_quote_action = "BUY"
          end

          # Expected move calculation
          expected_move_pct = (zscore.abs * zscore_data[:std] / zscore_data[:mean] * 100).round(2)
          expected_profit_usd = (position_usd * expected_move_pct / 100 / 2).round(0)

          # Get liquidity info
          base_liquidity = get_orderbook_liquidity(base)
          quote_liquidity = get_orderbook_liquidity(quote)
          liquidity_section = format_liquidity_section(base, quote, base_liquidity, quote_liquidity, half_position)

          # Get trading links
          links_section = format_trading_links(base, quote)

          emoji = is_stop ? "🚨" : "📊"
          alert_type = is_stop ? "STOP LOSS" : "STAT ARB"

          if is_stop
            # STOP LOSS: Show how to CLOSE the position (opposite actions)
            message = <<~MSG
              #{emoji} #{alert_type} | #{pair} | Z = #{format_zscore(zscore)}
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

              📈 RATIO: #{zscore_data[:ratio].round(6)} #{direction}
                 Mean: #{zscore_data[:mean].round(6)}
                 Std: #{zscore_data[:std].round(6)}

              ⚠️ ПОЗИЦИЯ В УБЫТКЕ:
              Открытая позиция была: #{entry_base_action} #{base} / #{entry_quote_action} #{quote}
              Z ушёл за стоп (#{PairsConfig.thresholds[:stop]}) → mean reversion не работает

              💸 ПОТЕНЦИАЛЬНЫЙ УБЫТОК:
              • При текущем Z: ~#{expected_move_pct}% (~$#{expected_profit_usd})

              #{liquidity_section}
              📝 ДЕЙСТВИЕ - ЗАКРЫТЬ ПОЗИЦИЮ:
              1. #{close_base_action} #{format_tokens(base_tokens)} #{base} @ $#{format_price(base_price)}
              2. #{close_quote_action} #{format_tokens(quote_tokens)} #{quote} @ $#{format_price(quote_price)}

              ⚠️ РИСК: Возможна смена режима (regime change).
              Ratio может не вернуться к старому mean.

              #{links_section}
            MSG
          else
            # ENTRY SIGNAL: Show how to OPEN the position
            message = <<~MSG
              #{emoji} #{alert_type} | #{pair} | Z = #{format_zscore(zscore)}
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

              📈 RATIO: #{zscore_data[:ratio].round(6)} #{direction}
                 Mean: #{zscore_data[:mean].round(6)}
                 Std: #{zscore_data[:std].round(6)}

              💰 ПОЗИЦИЯ ($#{format_number(position_usd)}):
              • #{entry_base_action} #{format_tokens(base_tokens)} #{base} @ $#{format_price(base_price)} ($#{format_number(half_position)})
              • #{entry_quote_action} #{format_tokens(quote_tokens)} #{quote} @ $#{format_price(quote_price)} ($#{format_number(half_position)})

              💹 ОЖИДАЕМАЯ ПРИБЫЛЬ:
              • При возврате к mean: ~#{expected_move_pct}% (~$#{expected_profit_usd})

              #{liquidity_section}
              📝 ИНСТРУКЦИЯ:
              1. #{entry_base_action} #{format_tokens(base_tokens)} #{base} на perp/futures
              2. #{entry_quote_action} #{format_tokens(quote_tokens)} #{quote} на perp/futures
              3. Ждать возврата Z к 0 (mean reversion)
              4. Закрыть при |Z| < #{PairsConfig.thresholds[:exit]}

              📍 ВЫХОД:
              • Profit: |Z| < #{PairsConfig.thresholds[:exit]}
              • Stop loss: |Z| > #{PairsConfig.thresholds[:stop]}

              #{links_section}
            MSG
          end

          {
            type: is_stop ? :zscore_stop : :zscore_entry,
            pair: pair,
            zscore: zscore,
            ratio: zscore_data[:ratio],
            mean: zscore_data[:mean],
            std: zscore_data[:std],
            direction: zscore > 0 ? :short_base : :long_base,
            position_usd: position_usd,
            message: message.strip
          }
        end

        def send_alert(alert)
          # Create signal in database
          db_signal = Analytics::SignalRepository.create(
            strategy: 'zscore',
            class: 'speculative',
            symbol: alert[:pair],
            details: alert.except(:message)
          )

          signal_id = db_signal ? Analytics::SignalRepository.short_id(db_signal[:id], 'zscore') : nil
          message = alert[:message]
          message = "#{message}\n\nID: `#{signal_id}`\n/taken #{signal_id}" if signal_id

          result = @notifier.send_alert(message)

          if result && db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          result
        rescue StandardError => e
          @logger.error("[ZScoreAlerter] send_alert error: #{e.message}")
          nil
        end

        def format_zscore(zscore)
          sign = zscore >= 0 ? '+' : ''
          "#{sign}#{zscore.round(2)}"
        end

        def status_emoji(status)
          case status
          when :stop_loss then "🚨"
          when :entry_signal then "📊"
          when :exit_zone then "✅"
          else "📈"
          end
        end

        def get_current_price(symbol)
          # Try to get price from Redis cache
          prices_data = ArbitrageBot.redis.get('prices:latest')
          return nil unless prices_data

          prices = JSON.parse(prices_data)

          # Try all possible key formats - futures first (preferred for pair trading), then spot
          possible_prefixes = %w[
            binance_futures bybit_futures okx_futures gate_futures
            binance_spot bybit_spot okx_spot gate_spot kucoin_spot
          ]

          possible_prefixes.each do |prefix|
            key = "#{prefix}:#{symbol}"
            next unless prices[key]

            price_data = prices[key]
            # Handle both hash and simple value formats
            price = if price_data.is_a?(Hash)
                      price_data['last']&.to_f || price_data['bid']&.to_f
                    else
                      price_data.to_f
                    end

            return price if price && price > 0
          end

          @logger.warn("[ZScoreAlerter] No price found for #{symbol} in cache")
          nil
        rescue StandardError => e
          @logger.debug("[ZScoreAlerter] get_current_price error: #{e.message}")
          nil
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

        def get_orderbook_liquidity(symbol)
          liquidity = { bids_usd: 0, asks_usd: 0 }

          %w[binance bybit okx].each do |exchange|
            key = "orderbook:#{exchange}_futures:#{symbol}"
            data = ArbitrageBot.redis.get(key)
            next unless data

            ob = JSON.parse(data, symbolize_names: true)
            liquidity[:bids_usd] += ob[:bids_usd].to_f if ob[:bids_usd]
            liquidity[:asks_usd] += ob[:asks_usd].to_f if ob[:asks_usd]
          rescue StandardError
            next
          end

          liquidity[:bids_usd] > 0 || liquidity[:asks_usd] > 0 ? liquidity : nil
        rescue StandardError
          nil
        end

        def format_liquidity_section(base, quote, base_liq, quote_liq, position_per_leg)
          lines = []

          if base_liq || quote_liq
            lines << "💧 ЛИКВИДНОСТЬ:"

            if base_liq
              min_base = [base_liq[:bids_usd], base_liq[:asks_usd]].min
              ratio_base = position_per_leg > 0 && min_base > 0 ? ((min_base / position_per_leg) * 100).round(0) : 0
              lines << "• #{base}: $#{format_number(min_base)} #{ratio_base >= 100 ? '✅' : '⚠️'}"
            else
              lines << "• #{base}: ? (нет данных)"
            end

            if quote_liq
              min_quote = [quote_liq[:bids_usd], quote_liq[:asks_usd]].min
              ratio_quote = position_per_leg > 0 && min_quote > 0 ? ((min_quote / position_per_leg) * 100).round(0) : 0
              lines << "• #{quote}: $#{format_number(min_quote)} #{ratio_quote >= 100 ? '✅' : '⚠️'}"
            else
              lines << "• #{quote}: ? (нет данных)"
            end

            lines << ""
          end

          lines.join("\n")
        end

        def format_trading_links(base, quote)
          # Pick best exchange (binance preferred, then bybit)
          exchange = 'binance'
          template = EXCHANGE_URLS[exchange]

          base_url = template.gsub('%{symbol}', base.upcase)
          quote_url = template.gsub('%{symbol}', quote.upcase)

          lines = [
            "🔗 ТОРГОВАТЬ (#{exchange.capitalize}):",
            "   #{base}: #{base_url}",
            "   #{quote}: #{quote_url}"
          ]

          lines.join("\n")
        end
      end
    end
  end
end
