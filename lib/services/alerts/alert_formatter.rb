# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      class AlertFormatter
        # Format templates for different signal types

        FIRE_EMOJIS = {
          high: "\u{1F525}\u{1F525}\u{1F525}",  # 3 fires for high spread
          medium: "\u{1F525}\u{1F525}",         # 2 fires for medium
          low: "\u{1F525}"                       # 1 fire for low
        }.freeze

        STRATEGY_NAMES = {
          DF: 'DEX ↔ Futures',
          DP: 'DEX ↔ PerpDEX',
          SF: 'Spot ↔ Futures',
          FF: 'Futures ↔ Futures',
          PF: 'PerpDEX ↔ Futures',
          PP: 'PerpDEX ↔ PerpDEX',
          SS: 'Spot ↔ Spot'
        }.freeze

        # Exchange trading URLs
        EXCHANGE_URLS = {
          'binance' => {
            futures: 'https://www.binance.com/en/futures/%{symbol}USDT',
            spot: 'https://www.binance.com/en/trade/%{symbol}_USDT'
          },
          'bybit' => {
            futures: 'https://www.bybit.com/trade/usdt/%{symbol}USDT',
            spot: 'https://www.bybit.com/en/trade/spot/%{symbol}/USDT'
          },
          'okx' => {
            futures: 'https://www.okx.com/trade-swap/%{symbol}-usdt-swap',
            spot: 'https://www.okx.com/trade-spot/%{symbol}-usdt'
          },
          'gate' => {
            futures: 'https://www.gate.io/futures_trade/USDT/%{symbol}_USDT',
            spot: 'https://www.gate.io/trade/%{symbol}_USDT'
          },
          'mexc' => {
            futures: 'https://futures.mexc.com/exchange/%{symbol}_USDT',
            spot: 'https://www.mexc.com/exchange/%{symbol}_USDT'
          },
          'kucoin' => {
            futures: 'https://www.kucoin.com/futures/trade/%{symbol}USDTM',
            spot: 'https://www.kucoin.com/trade/%{symbol}-USDT'
          },
          'bitget' => {
            futures: 'https://www.bitget.com/futures/usdt/%{symbol}USDT',
            spot: 'https://www.bitget.com/spot/%{symbol}USDT'
          },
          'htx' => {
            futures: 'https://www.htx.com/futures/linear_swap/exchange#contract_code=%{symbol}-USDT',
            spot: 'https://www.htx.com/trade/%{symbol}_usdt'
          },
          'hyperliquid' => {
            futures: 'https://app.hyperliquid.xyz/trade/%{symbol}'
          },
          'dydx' => {
            futures: 'https://trade.dydx.exchange/trade/%{symbol}-USD'
          },
          'gmx' => {
            futures: 'https://app.gmx.io/#/trade'
          },
          'vertex' => {
            futures: 'https://app.vertexprotocol.com/markets/%{symbol}-PERP'
          }
        }.freeze

        def initialize(settings = {})
          @settings = settings
          @high_spread_threshold = settings[:high_spread_threshold] || 10.0
          @medium_spread_threshold = settings[:medium_spread_threshold] || 5.0
          @default_position_usd = settings[:default_position_usd] || 10_000
          @convergence_tracker = Analytics::SpreadConvergenceTracker.new
          @baseline_collector = Analytics::SpreadBaselineCollector.new
          @pair_stats_service = Analytics::PairStatisticsService.new
          @cross_pair_service = Analytics::CrossPairComparisonService.new
        end

        # Format a validated signal for Telegram
        # @param signal [ValidatedSignal] signal from SignalBuilder
        # @return [String] formatted message
        def format(signal)
          case signal.signal_type
          when :auto
            format_auto_signal(signal)
          when :manual
            format_manual_signal(signal)
          when :lagging
            format_lagging_signal(signal)
          when :invalid
            format_invalid_signal(signal)
          else
            format_auto_signal(signal) # Default
          end
        end

        # Format for auto (hedged, shortable) signals
        def format_auto_signal(signal)
          fires = fire_emoji(signal.spread[:real_pct])

          # Prices
          buy_price = signal.prices[:buy_price].to_f
          sell_price = signal.prices[:sell_price].to_f
          best_ask = signal.prices[:best_ask_low].to_f
          best_bid = signal.prices[:best_bid_high].to_f

          # Liquidity from orderbook analysis
          max_entry_usd = signal.liquidity[:max_entry_usd].to_f
          max_buy_usd = signal.liquidity[:max_buy_usd].to_f
          max_sell_usd = signal.liquidity[:max_sell_usd].to_f
          low_bids = signal.liquidity[:low_bids_usd].to_f
          high_asks = signal.liquidity[:high_asks_usd].to_f
          exit_usd = signal.liquidity[:exit_usd].to_f

          # Position size: use suggested OR cap at max_entry (liquidity-limited)
          suggested = signal.suggested_position_usd.to_f
          position_usd = if suggested > 0 && suggested <= max_entry_usd
                           suggested
                         elsif max_entry_usd > 0
                           [max_entry_usd, @default_position_usd].min
                         else
                           @default_position_usd
                         end

          # Position size in tokens
          position_tokens = buy_price > 0 ? (position_usd / buy_price) : 0

          # Spreads
          current_spread = signal.spread[:real_pct].to_f
          net_spread = signal.spread[:net_pct].to_f
          target_spread = (current_spread / 2).round(2)

          # Profit estimate
          profit_usd = (position_usd * net_spread / 100).round(0)

          # Exit liquidity ratio
          exit_ratio = position_usd > 0 ? ((exit_usd / position_usd) * 100).round(0) : 0

          # Links
          buy_link = generate_link(signal.low_venue, signal.symbol)
          sell_link = generate_link(signal.high_venue, signal.symbol)

          <<~MSG.strip
            #{fires} HEDGED | #{signal.symbol} | #{format_spread(current_spread)}%
            ━━━━━━━━━━━━━━━━━━━━━━━━

            📊 ПЛОЩАДКИ:
            🟢 LONG: #{venue_name(signal.low_venue)} — $#{format_price(best_ask)}
            🔴 SHORT: #{venue_name(signal.high_venue)} — $#{format_price(best_bid)}

            💰 ПОЗИЦИЯ (max $#{format_number(position_usd)}):
            • Buy: $#{format_number(position_usd)} (#{format_tokens(position_tokens)} #{signal.symbol}) @ $#{format_price(buy_price)}
            • Short: $#{format_number(position_usd)} (#{format_tokens(position_tokens)} #{signal.symbol}) @ $#{format_price(sell_price)}

            📊 ЛИМИТЫ ОРДЕРБУКА (1% slip):
            • Max buy: $#{format_number(max_buy_usd)}
            • Max sell: $#{format_number(max_sell_usd)}
            • Max позиция: $#{format_number(max_entry_usd)}

            💹 ПРИБЫЛЬ:
            • Спред: #{format_spread(current_spread)}% gross → #{format_spread(net_spread)}% net
            • Ожидаемый PnL: ~$#{profit_usd}

            📝 ИНСТРУКЦИЯ:
            1. LONG $#{format_number(position_usd)} #{signal.symbol} на #{venue_short_name(signal.low_venue)} @ $#{format_price(buy_price)}
            2. SHORT $#{format_number(position_usd)} #{signal.symbol} на #{venue_short_name(signal.high_venue)} @ $#{format_price(sell_price)}
            3. Ждать схождения до ~#{format_spread(target_spread)}%
            4. Закрыть обе позиции

            💧 ЛИКВИДНОСТЬ ВЫХОДА:
            • #{venue_short_name(signal.low_venue)} bids: $#{format_number(low_bids)}
            • #{venue_short_name(signal.high_venue)} asks: $#{format_number(high_asks)}
            • Позиция vs ликвидность: #{exit_ratio}% #{exit_ratio >= 100 ? "✅" : "⚠️"}

            #{format_stats_section(symbol: signal.symbol, low_venue: signal.low_venue, high_venue: signal.high_venue, current_spread: current_spread)}🔗 ССЫЛКИ:
            • Buy: #{buy_link}
            • Sell: #{sell_link}

            ━━━━━━━━━━━━━━━━━━━━━━━━
            ⏰ #{format_timestamp(signal.created_at)} | OB: #{format_latency(signal.timing)}
          MSG
        end

        # Format for manual (spot-spot, requires token transfer) signals
        def format_manual_signal(signal)
          fires = fire_emoji(signal.spread[:real_pct])

          # Prices
          buy_price = signal.prices[:buy_price].to_f
          sell_price = signal.prices[:sell_price].to_f
          best_ask = signal.prices[:best_ask_low].to_f
          best_bid = signal.prices[:best_bid_high].to_f

          # Liquidity from orderbook analysis
          max_entry_usd = signal.liquidity[:max_entry_usd].to_f
          max_buy_usd = signal.liquidity[:max_buy_usd].to_f
          max_sell_usd = signal.liquidity[:max_sell_usd].to_f
          low_asks = signal.liquidity[:low_asks_usd].to_f || max_buy_usd
          high_bids = signal.liquidity[:high_bids_usd].to_f || signal.liquidity[:low_bids_usd].to_f

          # Position size: use suggested OR cap at max_entry (liquidity-limited)
          suggested = signal.suggested_position_usd.to_f
          position_usd = if suggested > 0 && suggested <= max_entry_usd
                           suggested
                         elsif max_entry_usd > 0
                           [max_entry_usd, @default_position_usd].min
                         else
                           @default_position_usd
                         end

          # Position size in tokens
          position_tokens = buy_price > 0 ? (position_usd / buy_price) : 0

          # Spreads
          current_spread = signal.spread[:real_pct].to_f
          net_spread = signal.spread[:net_pct].to_f

          # Profit estimate
          profit_usd = (position_usd * net_spread / 100).round(0)

          # Links
          buy_link = generate_link(signal.low_venue, signal.symbol)
          sell_link = generate_link(signal.high_venue, signal.symbol)

          # Volatility buffer analysis
          vol_buffer = signal.volatility_buffer || {}
          buffer_valid = vol_buffer[:valid]
          required_spread = vol_buffer[:required_pct] || 0
          buffer_margin = vol_buffer[:margin_pct] || 0
          buffer_details = vol_buffer[:buffer_details] || {}

          # Determine transfer warning
          low_type = venue_type(signal.low_venue)
          high_type = venue_type(signal.high_venue)
          is_spot_spot = (low_type == :cex_spot || low_type == :dex_spot) &&
                         (high_type == :cex_spot || high_type == :dex_spot)

          transfer_warning = if is_spot_spot
                               <<~WARN

                                 ⚠️ ТРЕБУЕТСЯ ПЕРЕВОД ТОКЕНОВ:
                                 Это spot↔spot арбитраж. Нужно:
                                 1. Купить на #{venue_short_name(signal.low_venue)}
                                 2. Вывести токены (withdraw)
                                 3. Депозит на #{venue_short_name(signal.high_venue)}
                                 4. Продать
                                 ⏱ Время = риск изменения цены!
                               WARN
                             else
                               <<~WARN

                                 ⚠️ ТРЕБУЮТСЯ ТОКЕНЫ:
                                 Нельзя шортить #{venue_name(signal.high_venue)}.
                                 Нужны токены #{signal.symbol} для продажи.
                               WARN
                             end

          <<~MSG.strip
            ⚠️ MANUAL | #{signal.symbol} | #{format_spread(current_spread)}%
            ━━━━━━━━━━━━━━━━━━━━━━━━
            #{transfer_warning.strip}

            📊 ПЛОЩАДКИ:
            🟢 BUY: #{venue_name(signal.low_venue)} — $#{format_price(best_ask)}
            🔴 SELL: #{venue_name(signal.high_venue)} — $#{format_price(best_bid)}

            💰 ПОЗИЦИЯ (max $#{format_number(position_usd)}):
            • Buy: $#{format_number(position_usd)} (#{format_tokens(position_tokens)} #{signal.symbol}) @ $#{format_price(buy_price)}
            • Sell: $#{format_number(position_usd)} (#{format_tokens(position_tokens)} #{signal.symbol}) @ $#{format_price(sell_price)}

            📊 ЛИМИТЫ ОРДЕРБУКА (1% slip):
            • Max buy: $#{format_number(max_buy_usd)}
            • Max sell: $#{format_number(max_sell_usd)}
            • Max позиция: $#{format_number(max_entry_usd)}

            💹 ПРИБЫЛЬ:
            • Спред: #{format_spread(current_spread)}% gross → #{format_spread(net_spread)}% net
            • Ожидаемый PnL: ~$#{profit_usd}

            ⏱ РИСК ТРАНСФЕРА:
            • Волатильность: #{buffer_details[:volatility_per_min] || '?'}%/мин
            • Время трансфера: ~#{buffer_details[:transfer_time_min] || '?'} мин
            • Safety buffer: #{required_spread}%
            • Спред vs buffer: #{buffer_valid ? '✅' : '⚠️'} #{buffer_margin >= 0 ? '+' : ''}#{buffer_margin}%

            #{format_transfer_status(signal)}📝 ИНСТРУКЦИЯ:
            1. Купить $#{format_number(position_usd)} #{signal.symbol} на #{venue_short_name(signal.low_venue)} @ $#{format_price(buy_price)}
            2. Перевести токены на #{venue_short_name(signal.high_venue)}
            3. Продать $#{format_number(position_usd)} #{signal.symbol} @ $#{format_price(sell_price)}
            ⚡ Действовать быстро - цена может измениться!

            💧 ЛИКВИДНОСТЬ:
            • #{venue_short_name(signal.low_venue)} asks: $#{format_number(low_asks)} (покупка)
            • #{venue_short_name(signal.high_venue)} bids: $#{format_number(high_bids)} (продажа)

            #{format_stats_section(symbol: signal.symbol, low_venue: signal.low_venue, high_venue: signal.high_venue, current_spread: current_spread)}🔗 ССЫЛКИ:
            • Buy: #{buy_link}
            • Sell: #{sell_link}

            ━━━━━━━━━━━━━━━━━━━━━━━━
            ⏰ #{format_timestamp(signal.created_at)} | OB: #{format_latency(signal.timing)}
          MSG
        end

        # Format for lagging exchange signals
        def format_lagging_signal(signal)
          lag_info = signal.lagging_info || {}
          fires = fire_emoji(signal.spread[:real_pct])
          position_usd = signal.suggested_position_usd || @default_position_usd

          # Prices
          buy_price = signal.prices[:buy_price].to_f
          sell_price = signal.prices[:sell_price].to_f

          # Position
          position_tokens = buy_price > 0 ? (position_usd / buy_price) : 0

          # Spreads
          current_spread = signal.spread[:real_pct].to_f
          net_spread = signal.spread[:net_pct].to_f

          # Links
          buy_link = generate_link(signal.low_venue, signal.symbol)
          sell_link = generate_link(signal.high_venue, signal.symbol)

          <<~MSG.strip
            #{fires} #{signal.symbol} | #{format_spread(current_spread)}% ⏱️ LAGGING
            ━━━━━━━━━━━━━━━━━━━━━━━━

            ⚠️ ВНИМАНИЕ: ЗАДЕРЖКА БИРЖИ
            #{lag_info[:lagging_venue]} отклоняется на #{lag_info[:deviation_pct]}%
            от #{lag_info[:other_exchanges_count]}+ других бирж.

            Медианная цена: $#{format_price(lag_info[:median_price])}
            Цена #{lag_info[:lagging_venue]}: $#{format_price(lag_info[:lagging_price])}

            💡 Спред может быть задержкой данных, а не реальной возможностью!

            📊 ПЛОЩАДКИ:
            🟢 BUY: #{venue_name(signal.low_venue)} — $#{format_price(buy_price)}
            🔴 SELL: #{venue_name(signal.high_venue)} — $#{format_price(sell_price)}

            💰 ЕСЛИ ВХОДИТЬ ($#{format_number(position_usd)}):
            • #{format_tokens(position_tokens)} #{signal.symbol}
            • Спред: #{format_spread(current_spread)}% gross → #{format_spread(net_spread)}% net

            🚨 РЕКОМЕНДАЦИИ:
            • Подождать стабилизации цен (>30 сек)
            • Уменьшить размер позиции
            • Рассматривать только как информацию

            🔗 ССЫЛКИ:
            • Buy: #{buy_link}
            • Sell: #{sell_link}

            ━━━━━━━━━━━━━━━━━━━━━━━━
            ⏰ #{format_timestamp(signal.created_at)} | OB: #{format_latency(signal.timing)}
            ⚠️ ВЫСОКИЙ РИСК - lagging exchange!
          MSG
        end

        # Format for invalid signals (failed safety checks)
        def format_invalid_signal(signal)
          safety = signal.safety_checks || {}
          failed = safety[:messages] || []

          <<~MSG.strip
            ❌ #{signal.symbol} | #{signal.spread[:real_pct]}% BLOCKED
            ━━━━━━━━━━━━━━━━━━━━━━━━

            Сигнал заблокирован:
            #{failed.map { |m| "• #{m}" }.join("\n")}

            Проверок пройдено: #{safety[:passed_count]}/#{safety[:checks_count]}
          MSG
        end

        # Format a compact summary for /top command
        def format_summary(signal)
          fires = fire_emoji(signal.spread[:real_pct])
          type_badge = case signal.signal_type
                       when :auto then ''
                       when :manual then ' 🔧'
                       when :lagging then ' ⏱️'
                       else ''
                       end

          "#{fires} #{signal.symbol}#{type_badge} | #{signal.spread[:real_pct]}% " \
            "(#{venue_short_name(signal.low_venue)} → #{venue_short_name(signal.high_venue)}) " \
            "| $#{format_number(signal.liquidity[:exit_usd])} liq"
        end

        # Format grouped alert with best pair + alternatives
        # @param best_signal [ValidatedSignal] the best signal for this symbol
        # @param other_signals [Array<ValidatedSignal>] alternative pairs
        # @param signal_id [String, nil] signal ID for the best signal
        # @return [String] formatted grouped message
        def format_grouped_signal(best_signal, other_signals = [], signal_id: nil)
          # Format the main signal
          main_message = format(best_signal)

          # If no alternatives, just return main message
          return main_message if other_signals.empty?

          # Find where to insert alternatives section (before links section)
          insert_marker = "🔗 ССЫЛКИ:"

          alternatives_section = format_alternatives_section(other_signals)

          if main_message.include?(insert_marker)
            main_message.sub(insert_marker, "#{alternatives_section}\n#{insert_marker}")
          else
            # Fallback: append at end
            "#{main_message}\n\n#{alternatives_section}"
          end
        end

        private

        # Format the alternatives section
        def format_alternatives_section(other_signals)
          return "" if other_signals.empty?

          lines = ["📊 ДРУГИЕ ПАРЫ (#{other_signals.size}):"]

          other_signals.each do |sig|
            pair_name = "#{venue_short_name(sig.low_venue)}↔#{venue_short_name(sig.high_venue)}"
            spread = sig.spread[:real_pct].to_f.round(1)
            type_icon = sig.signal_type == :auto ? '' : ' ⚠️'
            lines << "   • #{pair_name}: #{spread}%#{type_icon}"
          end

          lines.join("\n")
        end

        def fire_emoji(spread_pct)
          if spread_pct >= @high_spread_threshold
            FIRE_EMOJIS[:high]
          elsif spread_pct >= @medium_spread_threshold
            FIRE_EMOJIS[:medium]
          else
            FIRE_EMOJIS[:low]
          end
        end

        def strategy_name(strategy_type)
          STRATEGY_NAMES[strategy_type] || strategy_type.to_s
        end

        def venue_type(venue)
          return nil unless venue
          (venue[:type] || venue['type'])&.to_sym
        end

        def venue_name(venue)
          return 'Unknown' unless venue

          type = venue_type(venue)
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          case type
          when :cex_futures then "#{exchange&.capitalize} Futures"
          when :cex_spot then "#{exchange&.capitalize} Spot"
          when :perp_dex then "#{dex&.capitalize} Perp"
          when :dex_spot then "#{dex&.capitalize} DEX"
          else 'Unknown'
          end
        end

        def venue_short_name(venue)
          return '?' unless venue

          type = venue_type(venue)
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          name = (exchange || dex || '?')&.capitalize
          suffix = case type
                   when :cex_futures then '-Fut'
                   when :cex_spot then '-Spot'
                   when :perp_dex then '-Perp'
                   when :dex_spot then '-DEX'
                   else ''
                   end

          "#{name}#{suffix}"
        end

        def generate_link(venue, symbol)
          return 'N/A' unless venue

          type = venue_type(venue)
          exchange = (venue[:exchange] || venue['exchange'])&.downcase
          dex = (venue[:dex] || venue['dex'])&.downcase

          name = exchange || dex
          return 'N/A' unless name && EXCHANGE_URLS[name]

          market_type = case type
                        when :cex_futures, :perp_dex then :futures
                        when :cex_spot, :dex_spot then :spot
                        else :futures
                        end

          template = EXCHANGE_URLS[name][market_type]
          return 'N/A' unless template

          template.gsub('%{symbol}', symbol.to_s.upcase)
        end

        def format_price(price)
          return '0' unless price

          price = price.to_f
          if price < 0.0001
            sprintf('%.8f', price)
          elsif price < 0.01
            sprintf('%.6f', price)
          elsif price < 1
            sprintf('%.4f', price)
          elsif price < 100
            sprintf('%.3f', price)
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

        def format_spread(spread)
          spread.to_f.round(2)
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

        def format_transfer_status(signal)
          status = signal.transfer_status
          return "" unless status && status.is_a?(Hash)

          # Skip if error or unknown
          return "" if status[:error]
          return "" if status[:buy_withdraw_enabled].nil? && status[:sell_deposit_enabled].nil?

          emoji = status[:valid] ? '✅' : '⚠️'
          withdraw_status = format_enabled_status(status[:buy_withdraw_enabled])
          deposit_status = format_enabled_status(status[:sell_deposit_enabled])

          lines = ["🔄 СТАТУС ПЕРЕВОДОВ: #{emoji}"]
          lines << "• Withdraw (#{status[:buy_exchange]&.upcase}): #{withdraw_status}"
          lines << "• Deposit (#{status[:sell_exchange]&.upcase}): #{deposit_status}"

          if status[:best_network]
            lines << "• Рекомендуемая сеть: #{status[:best_network].upcase}"
          end

          unless status[:valid]
            lines << "⚠️ #{status[:message]}"
          end

          lines.join("\n            ") + "\n\n            "
        end

        def format_enabled_status(enabled)
          case enabled
          when true then '✅ Включен'
          when false then '❌ Выключен'
          else '❓ Неизвестно'
          end
        end

        # Format pair-specific history and baseline statistics section
        # @param symbol [String] trading symbol
        # @param low_venue [Hash] buy venue
        # @param high_venue [Hash] sell venue
        # @param current_spread [Float] current spread percentage
        # @return [String] formatted stats section or empty string
        def format_stats_section(symbol:, low_venue:, high_venue:, current_spread:)
          pair_id = compute_pair_id(low_venue, high_venue)
          sections = []

          # 1. Baseline statistics (normal spread range)
          baseline_text = @baseline_collector.format_baseline_for_alert(
            pair_id: pair_id,
            symbol: symbol,
            current_spread: current_spread
          )
          sections << baseline_text if baseline_text

          # 2. Enhanced pair statistics (max/min spread, success rate, last N outcomes)
          pair_stats_text = @pair_stats_service.format_for_alert(
            pair_id: pair_id,
            symbol: symbol
          )
          sections << pair_stats_text if pair_stats_text

          # 3. Cross-pair comparison (same symbol on other exchange pairs)
          cross_pair_text = @cross_pair_service.format_for_alert(
            symbol: symbol,
            current_pair_id: pair_id,
            current_spread: current_spread
          )
          sections << cross_pair_text if cross_pair_text

          return "" if sections.empty?

          sections.join("\n\n            ") + "\n\n            "
        rescue StandardError => e
          ArbitrageBot.logger.debug("[AlertFormatter] format_stats_section error: #{e.message}")
          ""
        end

        # Compute pair_id from venues
        # @return [String] e.g. "binance_spot:bybit_futures"
        def compute_pair_id(low_venue, high_venue)
          low_key = venue_to_pair_key(low_venue)
          high_key = venue_to_pair_key(high_venue)
          "#{low_key}:#{high_key}"
        end

        def venue_to_pair_key(venue)
          return 'unknown' unless venue

          type = venue_type(venue)
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          case type
          when :cex_futures then "#{exchange&.downcase}_futures"
          when :cex_spot then "#{exchange&.downcase}_spot"
          when :perp_dex then "#{dex&.downcase}_perp"
          when :dex_spot then "#{dex&.downcase}_dex"
          else 'unknown'
          end
        end

        # Backward compatibility - symbol only (deprecated)
        def format_symbol_history_section(symbol)
          history_text = @convergence_tracker.format_symbol_history_for_alert(symbol)
          return "" unless history_text

          history_text + "\n\n            "
        rescue StandardError => e
          ArbitrageBot.logger.debug("[AlertFormatter] format_symbol_history_section error: #{e.message}")
          ""
        end

        def format_timestamp(timestamp)
          Time.at(timestamp).utc.strftime('%H:%M:%S')
        end

        def format_latency(timing)
          return 'N/A' unless timing

          max_latency = timing[:max_latency_ms] || timing['max_latency_ms'] ||
                        timing[:total_latency_ms] || timing['total_latency_ms']

          return 'N/A' unless max_latency && max_latency > 0

          if max_latency > 1000
            "#{(max_latency / 1000.0).round(1)}s"
          else
            "#{max_latency}ms"
          end
        end
      end
    end
  end
end
