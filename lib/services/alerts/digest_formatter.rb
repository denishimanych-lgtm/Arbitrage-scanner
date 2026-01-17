# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      # Formats accumulated signals into a digest message
      class DigestFormatter
        # Category display order (most important first)
        CATEGORY_ORDER = %i[sf ss ds ps pf ff df pp].freeze

        # Category labels
        CATEGORY_LABELS = {
          sf: 'SF',  # Spot-Futures
          ff: 'FF',  # Futures-Futures
          ss: 'SS',  # Spot-Spot
          ds: 'DS',  # DEX-Spot
          df: 'DF',  # DEX-Futures
          ps: 'PS',  # PerpDEX-Spot
          pf: 'PF',  # PerpDEX-Futures
          pp: 'PP'   # PerpDEX-PerpDEX
        }.freeze

        MAX_MESSAGE_LENGTH = 4000 # Leave buffer for Telegram's 4096 limit
        MAX_BUTTONS_PER_ROW = 4
        MAX_BUTTON_ROWS = 10

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Format digest from accumulated signals
        # @param signals [Hash] { symbol => { category => signal_data } }
        # @return [Hash] { message:, keyboard: }
        def format(signals)
          return nil if signals.empty?

          # Sort symbols by best spread (across all categories)
          sorted_symbols = sort_by_best_spread(signals)

          lines = []
          lines << header(sorted_symbols.size)
          lines << ''

          # Format each symbol
          sorted_symbols.each do |symbol|
            symbol_data = signals[symbol]
            symbol_lines = format_symbol(symbol, symbol_data)
            lines.concat(symbol_lines)
            lines << ''
          end

          lines << footer

          message = lines.join("\n")

          # Truncate if too long
          if message.length > MAX_MESSAGE_LENGTH
            message = truncate_message(message, sorted_symbols.size)
          end

          {
            message: message,
            keyboard: build_keyboard(sorted_symbols, signals)
          }
        end

        private

        def header(count)
          time_str = Time.now.strftime('%H:%M')
          "📊 ДАЙДЖЕСТ | #{time_str} | #{count} монет\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        end

        def footer
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n⏰ Следующий дайджест: 15 мин\n💡 Нажми на монету → real-time режим"
        end

        def format_symbol(symbol, categories)
          lines = ["🔶 #{symbol}"]

          # Sort categories by our preferred order
          sorted_cats = categories.keys.sort_by { |c| CATEGORY_ORDER.index(c) || 99 }

          sorted_cats.each do |cat|
            data = categories[cat]
            lines << format_category_line(cat, data)
          end

          lines
        end

        def format_category_line(category, data)
          label = CATEGORY_LABELS[category] || category.to_s.upcase
          spread = data[:spread_pct].round(1)
          low_ex = short_exchange_name(data.dig(:low_venue, :exchange))
          high_ex = short_exchange_name(data.dig(:high_venue, :exchange))

          # Arrow for spot-spot (direction matters), double arrow for others
          arrow = category == :ss ? '→' : '↔'

          # Liquidity
          liq = format_liquidity(data[:liquidity_usd])

          # Transfer status icon
          transfer = format_transfer_icon(data[:transfer_available], category)

          "   #{label}: #{spread}% #{low_ex}#{arrow}#{high_ex} #{transfer}| #{liq}"
        end

        def format_transfer_icon(available, category)
          # Only show for categories that need transfer
          return '' unless %i[ss ds ps].include?(category)

          case available
          when true then '✅ '
          when false then '❌ '
          else '❓ '
          end
        end

        def format_liquidity(usd)
          return 'N/A' unless usd && usd > 0

          if usd >= 1_000_000
            "$#{(usd / 1_000_000).round(1)}M"
          elsif usd >= 1_000
            "$#{(usd / 1_000).round(0)}K"
          else
            "$#{usd.round(0)}"
          end
        end

        def short_exchange_name(name)
          return '?' unless name

          case name.to_s.downcase
          when 'binance' then 'Bin'
          when 'bybit' then 'Byb'
          when 'okx' then 'OKX'
          when 'gate' then 'Gate'
          when 'mexc' then 'MEXC'
          when 'kucoin' then 'KuC'
          when 'htx', 'huobi' then 'HTX'
          when 'bitget' then 'Bitg'
          when 'jupiter' then 'Jup'
          when 'raydium' then 'Ray'
          when 'orca' then 'Orca'
          when 'uniswap' then 'Uni'
          when 'hyperliquid' then 'HL'
          when 'dydx' then 'dYdX'
          when 'gmx' then 'GMX'
          when 'vertex' then 'Vtx'
          else name.to_s[0..3]
          end
        end

        def sort_by_best_spread(signals)
          signals.keys.sort_by do |symbol|
            categories = signals[symbol]
            # Best spread across all categories for this symbol
            best = categories.values.map { |d| d[:spread_pct].to_f }.max
            -best # Descending
          end
        end

        def truncate_message(message, total_count)
          # Keep header and as many symbols as fit
          lines = message.split("\n")

          truncated = []
          current_length = 0

          lines.each do |line|
            break if current_length + line.length + 1 > MAX_MESSAGE_LENGTH - 200 # Leave room for footer + "..."

            truncated << line
            current_length += line.length + 1
          end

          truncated << ''
          truncated << "... и ещё #{total_count - count_symbols_in_lines(truncated)} монет"
          truncated << footer

          truncated.join("\n")
        end

        def count_symbols_in_lines(lines)
          lines.count { |l| l.start_with?('🔶') }
        end

        # Build inline keyboard with coin buttons
        def build_keyboard(symbols, signals)
          buttons = []

          symbols.each do |symbol|
            best_spread = signals[symbol].values.map { |d| d[:spread_pct].to_f }.max.round(0)
            buttons << {
              text: "#{symbol} #{best_spread}%",
              callback_data: Telegram::CallbackData.encode(:act, :track_coin, symbol)
            }
          end

          # Organize into rows
          rows = []
          buttons.each_slice(MAX_BUTTONS_PER_ROW) do |row_buttons|
            break if rows.size >= MAX_BUTTON_ROWS

            rows << row_buttons
          end

          # Add "more" button if truncated
          if buttons.size > MAX_BUTTONS_PER_ROW * MAX_BUTTON_ROWS
            remaining = buttons.size - (MAX_BUTTONS_PER_ROW * MAX_BUTTON_ROWS)
            rows.last << {
              text: "+ ещё #{remaining}",
              callback_data: Telegram::CallbackData.encode(:nav, :digest_more)
            }
          end

          { inline_keyboard: rows }
        end
      end
    end
  end
end
