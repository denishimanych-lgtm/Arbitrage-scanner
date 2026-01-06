# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Calculators
      class SpreadCalculator
        SpreadResult = Struct.new(
          :nominal_spread_pct, :real_spread_pct, :spread_loss_pct,
          :entry, :fully_fillable, :position_size_usd,
          keyword_init: true
        )

        EntryDetails = Struct.new(
          :buy_price, :buy_slippage_pct, :sell_price, :sell_slippage_pct,
          keyword_init: true
        )

        def initialize
          @exec_calc = ExecutablePriceCalculator.new
        end

        # Calculate spread between two orderbooks
        # @param low_orderbook [Hash] orderbook for buy side (lower price expected)
        # @param high_orderbook [Hash] orderbook for sell side (higher price expected)
        # @param position_size_usd [Numeric] position size in USD
        # @return [SpreadResult, nil]
        def calculate(low_orderbook, high_orderbook, position_size_usd)
          # Calculate executable prices
          buy_result = @exec_calc.calculate(low_orderbook, :buy, position_size_usd)
          sell_result = @exec_calc.calculate(high_orderbook, :sell, position_size_usd)

          return nil unless buy_result && sell_result

          # Nominal spread (best prices)
          nominal_spread = calculate_nominal_spread(low_orderbook, high_orderbook)

          # Real spread (executable prices)
          real_spread_pct = ((sell_result.executable_price - buy_result.executable_price) /
                             buy_result.executable_price * 100)

          # Spread loss due to slippage
          spread_loss_pct = nominal_spread - real_spread_pct

          SpreadResult.new(
            nominal_spread_pct: nominal_spread.round(4),
            real_spread_pct: real_spread_pct.round(4),
            spread_loss_pct: spread_loss_pct.round(4),
            entry: EntryDetails.new(
              buy_price: buy_result.executable_price,
              buy_slippage_pct: buy_result.slippage_pct,
              sell_price: sell_result.executable_price,
              sell_slippage_pct: sell_result.slippage_pct
            ),
            fully_fillable: buy_result.fully_filled && sell_result.fully_filled,
            position_size_usd: position_size_usd
          )
        end

        # Calculate nominal spread from best bid/ask
        def calculate_nominal_spread(low_orderbook, high_orderbook)
          low_ask = best_ask(low_orderbook)
          high_bid = best_bid(high_orderbook)

          return BigDecimal('0') if low_ask.nil? || high_bid.nil? || low_ask.zero?

          ((high_bid - low_ask) / low_ask * 100)
        end

        # Calculate spread at different position sizes
        def calculate_depth_profile(low_orderbook, high_orderbook, sizes_usd)
          sizes_usd.map do |size|
            result = calculate(low_orderbook, high_orderbook, size)
            next nil unless result

            {
              size_usd: size,
              nominal_spread_pct: result.nominal_spread_pct,
              real_spread_pct: result.real_spread_pct,
              spread_loss_pct: result.spread_loss_pct,
              fully_fillable: result.fully_fillable
            }
          end.compact
        end

        private

        def best_bid(orderbook)
          return nil unless orderbook[:bids]&.any?

          price = orderbook[:bids].first[0]
          price.is_a?(BigDecimal) ? price : BigDecimal(price.to_s)
        end

        def best_ask(orderbook)
          return nil unless orderbook[:asks]&.any?

          price = orderbook[:asks].first[0]
          price.is_a?(BigDecimal) ? price : BigDecimal(price.to_s)
        end
      end
    end
  end
end
