# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Top spreads keyboard with pagination
        class SpreadsKeyboard < BaseKeyboard
          ITEMS_PER_PAGE = 10

          attr_reader :page, :total_pages

          def initialize(user_id:, page: 1, total_pages: 1)
            super(user_id: user_id)
            @page = page
            @total_pages = total_pages
          end

          def build
            rows = []

            # Pagination controls if multiple pages
            if @total_pages > 1
              pagination = []

              if @page > 1
                pagination << button("◀ Prev", CallbackData.encode(:pg, :top, (@page - 1).to_s))
              end

              pagination << button("#{@page}/#{@total_pages}", CallbackData.encode(:act, :noop))

              if @page < @total_pages
                pagination << button("Next ▶", CallbackData.encode(:pg, :top, (@page + 1).to_s))
              end

              rows << row(*pagination)
            end

            # Refresh and back
            rows << row(
              button("🔄 Refresh", CallbackData.encode(:pg, :top, @page.to_s)),
              button("⬅️ Back", CallbackData.encode(:nav, :back))
            )

            rows
          end

          # Build text for spreads page
          # @param spreads [Array<Hash>] spread data for current page
          # @param page [Integer] current page
          # @param total [Integer] total spreads count
          # @return [String]
          def self.build_text(spreads, page, total)
            return "📈 Top Spreads\n\nNo spread data available." if spreads.empty?

            lines = spreads.map.with_index do |s, i|
              idx = (page - 1) * ITEMS_PER_PAGE + i + 1
              spread_pct = s['spread_pct'].to_f
              direction = spread_pct.positive? ? 'SHORT' : 'LONG'
              symbol = s['symbol']
              buy_price = format_price(s['buy_price'])
              sell_price = format_price(s['sell_price'])
              buy_venue = s['buy_venue'] || '?'
              sell_venue = s['sell_venue'] || '?'

              "#{idx}. #{symbol} | #{spread_pct.abs.round(2)}% #{direction}\n" \
                "   $#{buy_price} -> $#{sell_price}\n" \
                "   #{buy_venue} -> #{sell_venue}"
            end

            header = "📈 Top Spreads (#{total} total)\n\n"
            footer = "\n\nUpdated: #{Time.now.strftime('%H:%M:%S')}"

            header + lines.join("\n\n") + footer
          end

          def self.format_price(price)
            price = price.to_f
            if price < 0.0001
              format('%.8f', price)
            elsif price < 1
              format('%.6f', price)
            elsif price < 1000
              format('%.4f', price)
            else
              format('%.2f', price)
            end
          end

          # Load spreads from Redis
          # @param page [Integer] page number (1-indexed)
          # @return [Hash] { spreads: [], page:, total_pages:, total: }
          def self.load_spreads(page = 1)
            redis = ArbitrageBot.redis
            spreads_json = redis.get('spreads:latest')

            return { spreads: [], page: 1, total_pages: 1, total: 0 } unless spreads_json

            all_spreads = JSON.parse(spreads_json)
                              .sort_by { |s| -s['spread_pct'].to_f.abs }

            total = all_spreads.size
            total_pages = [(total.to_f / ITEMS_PER_PAGE).ceil, 1].max
            page = [[page, 1].max, total_pages].min

            offset = (page - 1) * ITEMS_PER_PAGE
            page_spreads = all_spreads[offset, ITEMS_PER_PAGE] || []

            {
              spreads: page_spreads,
              page: page,
              total_pages: total_pages,
              total: total
            }
          rescue JSON::ParserError
            { spreads: [], page: 1, total_pages: 1, total: 0 }
          end
        end
      end
    end
  end
end
