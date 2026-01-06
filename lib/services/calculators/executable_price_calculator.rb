# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Calculators
      class ExecutablePriceCalculator
        ExecutionResult = Struct.new(
          :executable_price, :best_price, :slippage_pct, :levels_used,
          :total_qty, :filled_usd, :fully_filled, :unfilled_usd,
          keyword_init: true
        )

        # Calculate executable price for a given position size
        # @param orderbook [Hash] orderbook with :bids and :asks arrays
        # @param side [Symbol] :buy or :sell
        # @param position_size_usd [Numeric] position size in USD
        # @return [ExecutionResult, nil]
        def calculate(orderbook, side, position_size_usd)
          levels = side == :buy ? orderbook[:asks] : orderbook[:bids]

          return nil if levels.nil? || levels.empty?

          remaining_usd = BigDecimal(position_size_usd.to_s)
          total_qty = BigDecimal('0')
          total_cost = BigDecimal('0')
          levels_used = 0

          levels.each do |level|
            price = level[0].is_a?(BigDecimal) ? level[0] : BigDecimal(level[0].to_s)
            qty = level[1].is_a?(BigDecimal) ? level[1] : BigDecimal(level[1].to_s)

            level_value_usd = price * qty

            if remaining_usd >= level_value_usd
              # Take entire level
              total_qty += qty
              total_cost += level_value_usd
              remaining_usd -= level_value_usd
              levels_used += 1
            else
              # Partial fill
              partial_qty = remaining_usd / price
              total_qty += partial_qty
              total_cost += remaining_usd
              remaining_usd = BigDecimal('0')
              levels_used += 1
              break
            end
          end

          return nil if total_qty.zero?

          avg_price = total_cost / total_qty
          best_price = levels.first[0]
          best_price = best_price.is_a?(BigDecimal) ? best_price : BigDecimal(best_price.to_s)

          slippage_pct = if best_price.zero?
                           BigDecimal('0')
                         else
                           ((avg_price - best_price).abs / best_price * 100)
                         end

          ExecutionResult.new(
            executable_price: avg_price,
            best_price: best_price,
            slippage_pct: slippage_pct.round(4),
            levels_used: levels_used,
            total_qty: total_qty,
            filled_usd: BigDecimal(position_size_usd.to_s) - remaining_usd,
            fully_filled: remaining_usd.zero?,
            unfilled_usd: remaining_usd
          )
        end

        # Calculate for both sides
        def calculate_both_sides(orderbook, position_size_usd)
          {
            buy: calculate(orderbook, :buy, position_size_usd),
            sell: calculate(orderbook, :sell, position_size_usd)
          }
        end

        # Calculate max executable size within slippage limit
        def max_size_within_slippage(orderbook, side, max_slippage_pct)
          levels = side == :buy ? orderbook[:asks] : orderbook[:bids]

          return BigDecimal('0') if levels.nil? || levels.empty?

          best_price = levels.first[0]
          best_price = best_price.is_a?(BigDecimal) ? best_price : BigDecimal(best_price.to_s)
          max_slippage = BigDecimal(max_slippage_pct.to_s)

          total_usd = BigDecimal('0')

          levels.each do |level|
            price = level[0].is_a?(BigDecimal) ? level[0] : BigDecimal(level[0].to_s)
            qty = level[1].is_a?(BigDecimal) ? level[1] : BigDecimal(level[1].to_s)

            slippage = ((price - best_price).abs / best_price * 100)

            break if slippage > max_slippage

            total_usd += price * qty
          end

          total_usd
        end
      end
    end
  end
end
