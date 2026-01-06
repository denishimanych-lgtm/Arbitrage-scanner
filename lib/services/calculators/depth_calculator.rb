# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Calculators
      class DepthCalculator
        DepthResult = Struct.new(
          :total_usd, :levels_count, :max_slippage_pct, :depth_points,
          keyword_init: true
        )

        DepthPoint = Struct.new(
          :price, :qty, :cumulative_usd, :slippage_pct,
          keyword_init: true
        )

        def initialize(max_slippage_pct: 1.0)
          @max_slippage_pct = BigDecimal(max_slippage_pct.to_s)
        end

        # Calculate depth within slippage limit
        # @param orderbook [Hash] orderbook with :bids and :asks
        # @param side [Symbol] :bids or :asks
        # @return [DepthResult]
        def calculate_with_slippage(orderbook, side)
          levels = orderbook[side]

          return DepthResult.new(total_usd: BigDecimal('0'), levels_count: 0, max_slippage_pct: @max_slippage_pct, depth_points: []) if levels.nil? || levels.empty?

          best_price = to_decimal(levels.first[0])
          total_usd = BigDecimal('0')
          depth_points = []
          levels_count = 0

          levels.each do |level|
            price = to_decimal(level[0])
            qty = to_decimal(level[1])

            slippage = calculate_slippage(best_price, price)

            break if slippage > @max_slippage_pct

            level_usd = price * qty
            total_usd += level_usd
            levels_count += 1

            depth_points << DepthPoint.new(
              price: price,
              qty: qty,
              cumulative_usd: total_usd,
              slippage_pct: slippage.round(4)
            )
          end

          DepthResult.new(
            total_usd: total_usd,
            levels_count: levels_count,
            max_slippage_pct: @max_slippage_pct,
            depth_points: depth_points
          )
        end

        # Calculate depth for both sides
        def calculate_both_sides(orderbook)
          {
            bids: calculate_with_slippage(orderbook, :bids),
            asks: calculate_with_slippage(orderbook, :asks)
          }
        end

        # Calculate exit liquidity (bids on low venue, asks on high venue)
        def calculate_exit_liquidity(low_orderbook, high_orderbook)
          low_bids = calculate_with_slippage(low_orderbook, :bids)
          high_asks = calculate_with_slippage(high_orderbook, :asks)

          {
            low_bids_usd: low_bids.total_usd,
            high_asks_usd: high_asks.total_usd,
            min_exit_usd: [low_bids.total_usd, high_asks.total_usd].min,
            details: {
              low: low_bids,
              high: high_asks
            }
          }
        end

        # Calculate bid-ask spread percentage
        def calculate_bid_ask_spread(orderbook)
          return BigDecimal('100') if orderbook[:bids].nil? || orderbook[:asks].nil?
          return BigDecimal('100') if orderbook[:bids].empty? || orderbook[:asks].empty?

          best_bid = to_decimal(orderbook[:bids].first[0])
          best_ask = to_decimal(orderbook[:asks].first[0])

          return BigDecimal('100') if best_bid.zero?

          ((best_ask - best_bid) / best_bid * 100).round(4)
        end

        private

        def to_decimal(value)
          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end

        def calculate_slippage(best_price, current_price)
          return BigDecimal('0') if best_price.zero?

          ((current_price - best_price).abs / best_price * 100)
        end
      end
    end
  end
end
