# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Blacklist management keyboard
        class BlacklistKeyboard < BaseKeyboard
          ITEMS_PER_PAGE = 8

          # Main blacklist menu with categories
          def build
            stats = blacklist.stats

            [
              row(
                button(
                  "Symbols (#{stats[:symbols_count]})",
                  CallbackData.encode(:nav, :blacklist, 'sy')
                )
              ),
              row(
                button(
                  "Exchanges (#{stats[:exchanges_count]})",
                  CallbackData.encode(:nav, :blacklist, 'ex')
                )
              ),
              row(
                button(
                  "Pairs (#{stats[:pairs_count]})",
                  CallbackData.encode(:nav, :blacklist, 'pr')
                )
              ),
              back_row
            ]
          end

          # Build symbols list with remove buttons
          # @param page [Integer] page number (1-indexed)
          def build_symbols_menu(page = 1)
            build_items_menu(:symbols, blacklist.symbols, page)
          end

          # Build exchanges list with remove buttons
          # @param page [Integer] page number (1-indexed)
          def build_exchanges_menu(page = 1)
            build_items_menu(:exchanges, blacklist.exchanges, page)
          end

          # Build pairs list with remove buttons
          # @param page [Integer] page number (1-indexed)
          def build_pairs_menu(page = 1)
            build_items_menu(:pairs, blacklist.pairs, page)
          end

          # Text for main blacklist menu
          def self.build_text
            <<~MSG
              🚫 Blacklist

              Manage blocked items:

              Symbols - Block specific tokens
              Exchanges - Block specific venues
              Pairs - Block specific trading pairs
            MSG
          end

          # Text for symbols submenu
          def self.build_symbols_text(count)
            <<~MSG
              🚫 Blacklisted Symbols (#{count})

              Tap a symbol to remove it from the blacklist.
              Use + Add to block a new symbol.
            MSG
          end

          # Text for exchanges submenu
          def self.build_exchanges_text(count)
            <<~MSG
              🚫 Blacklisted Exchanges (#{count})

              Tap an exchange to remove it from the blacklist.
              Use + Add to block a new exchange.
            MSG
          end

          # Text for pairs submenu
          def self.build_pairs_text(count)
            <<~MSG
              🚫 Blacklisted Pairs (#{count})

              Tap a pair to remove it from the blacklist.
              Use + Add to block a new pair.
            MSG
          end

          private

          def build_items_menu(type, items, page)
            items = items.to_a.sort
            total_pages = [(items.size.to_f / ITEMS_PER_PAGE).ceil, 1].max
            page = [[page, 1].max, total_pages].min

            offset = (page - 1) * ITEMS_PER_PAGE
            page_items = items[offset, ITEMS_PER_PAGE] || []

            rows = []

            # Item buttons with remove (x) - 2 per row
            page_items.each_slice(2) do |batch|
              rows << row(*batch.map do |item|
                display = item.length > 12 ? "#{item[0, 10]}.." : item
                button(
                  "❌ #{display}",
                  CallbackData.encode(:bl, :remove, type_code(type), item)
                )
              end)
            end

            # Add button
            rows << row(
              button(
                "➕ Add #{type.to_s.chomp('s').capitalize}",
                CallbackData.encode(:bl, :add, type_code(type))
              )
            )

            # Pagination if needed
            if total_pages > 1
              pagination = []
              if page > 1
                pagination << button("◀ Prev", CallbackData.encode(:pg, :blacklist, type_code(type), (page - 1).to_s))
              end
              pagination << button("#{page}/#{total_pages}", CallbackData.encode(:act, :noop))
              if page < total_pages
                pagination << button("Next ▶", CallbackData.encode(:pg, :blacklist, type_code(type), (page + 1).to_s))
              end
              rows << row(*pagination)
            end

            rows << back_row
            rows
          end

          def type_code(type)
            case type
            when :symbols then 'sy'
            when :exchanges then 'ex'
            when :pairs then 'pr'
            else type.to_s
            end
          end
        end
      end
    end
  end
end
