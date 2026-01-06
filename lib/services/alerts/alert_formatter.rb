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
          DF: 'DEX \u{2194} Futures',
          DP: 'DEX \u{2194} PerpDEX',
          SF: 'Spot \u{2194} Futures',
          FF: 'Futures \u{2194} Futures',
          PF: 'PerpDEX \u{2194} Futures',
          PP: 'PerpDEX \u{2194} PerpDEX'
        }.freeze

        def initialize(settings = {})
          @settings = settings
          @high_spread_threshold = settings[:high_spread_threshold] || 10.0
          @medium_spread_threshold = settings[:medium_spread_threshold] || 5.0
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

        # Format for auto (shortable) signals
        def format_auto_signal(signal)
          fires = fire_emoji(signal.spread[:real_pct])
          profit_estimate = calculate_profit_estimate(signal)

          <<~MSG.strip
            #{fires} #{signal.symbol} | #{signal.spread[:real_pct]}%
            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{1F4CB} #{signal.id}
            \u{1F4CA} #{strategy_name(signal.strategy_type)}

            \u{1F4B9} PRICES:
            \u{1F7E2} #{venue_name(signal.low_venue)}:
               $#{format_price(signal.prices[:buy_price])}
            \u{1F534} #{venue_name(signal.high_venue)}:
               $#{format_price(signal.prices[:sell_price])}
            \u{1F4C8} Delta: $#{format_price(signal.prices[:delta])}

            \u{1F4B0} PROFIT ESTIMATE:
            Gross: #{signal.spread[:nominal_pct]}%
            Slip:  -#{signal.spread[:slippage_loss_pct]}%
            Fees:  -#{signal.spread[:fees_pct]}%
            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            Net:   +#{signal.spread[:net_pct]}%

            \u{1F4B5} ~$#{profit_estimate} on $#{format_number(signal.suggested_position_usd)} position

            \u{2705} ACTION:
            1\u{FE0F}\u{20E3} #{signal.actions[:entry][0]}
            2\u{FE0F}\u{20E3} #{signal.actions[:entry][1]}
            3\u{FE0F}\u{20E3} #{signal.actions[:instructions].join(', ')}

            \u{1F4CA} LIQUIDITY:
            Low venue:  $#{format_number(signal.liquidity[:low_bids_usd])}
            High venue: $#{format_number(signal.liquidity[:high_asks_usd])}
            Exit avail: $#{format_number(signal.liquidity[:exit_usd])}
            Suggested:  $#{format_number(signal.suggested_position_usd)}

            #{format_links(signal.links)}

            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{23F0} #{format_timestamp(signal.created_at)} | Latency: #{format_latency(signal.timing)}
            \u{26A0}\u{FE0F} DYOR - verify before trading!
          MSG
        end

        # Format for manual (non-shortable high venue) signals
        def format_manual_signal(signal)
          fires = fire_emoji(signal.spread[:real_pct])
          profit_estimate = calculate_profit_estimate(signal)

          <<~MSG.strip
            #{fires} #{signal.symbol} | #{signal.spread[:real_pct]}% \u{1F528}MANUAL
            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{1F4CB} #{signal.id}
            \u{1F4CA} #{strategy_name(signal.strategy_type)}

            \u{26A0}\u{FE0F} MANUAL EXECUTION REQUIRED
            High venue cannot be shorted automatically.

            \u{1F4B9} PRICES:
            \u{1F7E2} #{venue_name(signal.low_venue)}:
               $#{format_price(signal.prices[:buy_price])}
            \u{1F534} #{venue_name(signal.high_venue)}:
               $#{format_price(signal.prices[:sell_price])}
            \u{1F4C8} Delta: $#{format_price(signal.prices[:delta])}

            \u{1F4B0} PROFIT (if you have tokens):
            Gross: #{signal.spread[:nominal_pct]}%
            Net:   +#{signal.spread[:net_pct]}%
            \u{1F4B5} ~$#{profit_estimate} on $#{format_number(signal.suggested_position_usd)}

            \u{1F6A8} ACTION (Manual):
            1\u{FE0F}\u{20E3} Check if you hold #{signal.symbol}
            2\u{FE0F}\u{20E3} SELL on #{venue_name(signal.high_venue)}
            3\u{FE0F}\u{20E3} BUY back on #{venue_name(signal.low_venue)}

            \u{1F4CA} LIQUIDITY:
            Exit: $#{format_number(signal.liquidity[:exit_usd])}
            Suggested: $#{format_number(signal.suggested_position_usd)}

            #{format_links(signal.links)}

            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{23F0} #{format_timestamp(signal.created_at)}
            \u{26A0}\u{FE0F} DYOR - verify before trading!
          MSG
        end

        # Format for lagging exchange signals
        def format_lagging_signal(signal)
          lag_info = signal.lagging_info || {}
          fires = fire_emoji(signal.spread[:real_pct])

          <<~MSG.strip
            #{fires} #{signal.symbol} | #{signal.spread[:real_pct]}% \u{23F1}\u{FE0F}LAGGING
            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{1F4CB} #{signal.id}
            \u{1F4CA} #{strategy_name(signal.strategy_type)}

            \u{26A0}\u{FE0F} LAGGING EXCHANGE DETECTED
            #{lag_info[:lagging_venue]} is lagging #{lag_info[:lag_ms]}ms behind #{lag_info[:leading_venue]}
            Confidence: #{((lag_info[:confidence] || 0) * 100).round(0)}%

            \u{1F4A1} This spread may be a pricing delay, not a real opportunity.
            The lagging exchange price may catch up quickly.

            \u{1F4B9} CURRENT PRICES:
            \u{1F7E2} #{venue_name(signal.low_venue)}:
               $#{format_price(signal.prices[:buy_price])}
            \u{1F534} #{venue_name(signal.high_venue)}:
               $#{format_price(signal.prices[:sell_price])}

            \u{1F4B0} POTENTIAL (high risk):
            Spread: #{signal.spread[:real_pct]}%
            Net:    +#{signal.spread[:net_pct]}%

            \u{1F6A8} RECOMMENDATIONS:
            \u{2022} Wait for prices to stabilize
            \u{2022} Verify spread persists >30 seconds
            \u{2022} Use smaller position sizes
            \u{2022} Consider this informational only

            #{format_links(signal.links)}

            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}
            \u{23F0} #{format_timestamp(signal.created_at)}
            \u{26A0}\u{FE0F} HIGH RISK - lagging exchange alert!
          MSG
        end

        # Format for invalid signals (failed safety checks)
        def format_invalid_signal(signal)
          safety = signal.safety_checks || {}
          failed = safety[:messages] || []

          <<~MSG.strip
            \u{274C} #{signal.symbol} | #{signal.spread[:real_pct]}% BLOCKED
            \u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}

            Signal blocked due to safety checks:
            #{failed.map { |m| "\u{2022} #{m}" }.join("\n")}

            Checks passed: #{safety[:passed_count]}/#{safety[:checks_count]}
          MSG
        end

        # Format a compact summary for /top command
        def format_summary(signal)
          fires = fire_emoji(signal.spread[:real_pct])
          type_badge = case signal.signal_type
                       when :auto then ''
                       when :manual then ' \u{1F528}'
                       when :lagging then ' \u{23F1}\u{FE0F}'
                       else ''
                       end

          "#{fires} #{signal.symbol}#{type_badge} | #{signal.spread[:real_pct]}% " \
            "(#{venue_short_name(signal.low_venue)} \u{2192} #{venue_short_name(signal.high_venue)}) " \
            "| $#{format_number(signal.liquidity[:exit_usd])} liq"
        end

        private

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

        def venue_name(venue)
          return 'Unknown' unless venue

          type = (venue[:type] || venue['type'])&.to_sym
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

          type = (venue[:type] || venue['type'])&.to_sym
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          name = exchange || dex || '?'
          suffix = case type
                   when :cex_futures then 'F'
                   when :cex_spot then 'S'
                   when :perp_dex then 'P'
                   when :dex_spot then 'D'
                   else ''
                   end

          "#{name&.upcase&.slice(0, 4)}#{suffix}"
        end

        def format_price(price)
          return '0' unless price

          price = price.to_f
          if price < 0.0001
            sprintf('%.8f', price)
          elsif price < 1
            sprintf('%.6f', price)
          elsif price < 100
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

        def format_timestamp(timestamp)
          Time.at(timestamp).utc.strftime('%H:%M:%S.%L')
        end

        def format_latency(timing)
          return 'N/A' unless timing

          max_latency = [
            timing[:low_latency_ms] || timing['low_latency_ms'] || 0,
            timing[:high_latency_ms] || timing['high_latency_ms'] || 0
          ].max

          "#{max_latency}ms"
        end

        def format_links(links)
          return '' unless links

          lines = ["\u{1F517} LINKS:"]
          lines << "\u{2022} Buy: #{links[:buy]}" if links[:buy]
          lines << "\u{2022} Sell: #{links[:sell]}" if links[:sell]
          lines << "\u{2022} Chart: #{links[:chart]}" if links[:chart]
          lines.join("\n")
        end

        def calculate_profit_estimate(signal)
          position = signal.suggested_position_usd || 10_000
          net_pct = signal.spread[:net_pct] || 0
          profit = position * (net_pct / 100.0)
          format_number(profit.abs)
        end
      end
    end
  end
end
