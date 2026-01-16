# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class GmxAdapter < BaseAdapter
        # GMX V2 on Arbitrum
        API_URL = 'https://arbitrum-api.gmxinfra.io'
        SUBGRAPH_URL = 'https://subgraph.satsuma-prod.com/3b2ced13c8d9/gmx/synthetics-arbitrum-stats/api'

        # Token decimals for price calculation
        # GMX stores prices as: price * 10^(30 - tokenDecimals)
        TOKEN_DECIMALS = {
          'BTC' => 8,
          'ETH' => 18,
          'WETH' => 18,
          'SOL' => 9,
          'LINK' => 18,
          'UNI' => 18,
          'ARB' => 18,
          'AVAX' => 18,
          'DOGE' => 8,
          'LTC' => 8,
          'XRP' => 6,
          'NEAR' => 24,
          'ATOM' => 6,
          'AAVE' => 18,
          'OP' => 18,
          'GMX' => 18,
          'PEPE' => 18,
          'WIF' => 6,
          'ORDI' => 18
        }.freeze

        DEFAULT_DECIMALS = 18

        def dex_id
          'gmx'
        end

        def markets
          data = get("#{API_URL}/prices/tickers")

          data.map do |ticker|
            {
              symbol: ticker['tokenSymbol'],
              base_asset: ticker['tokenSymbol'],
              quote_asset: 'USD',
              status: 'active'
            }
          end.uniq { |m| m[:symbol] }
        end

        def ticker(symbol)
          data = get("#{API_URL}/prices/tickers")

          ticker_data = data.find { |t| t['tokenSymbol'] == symbol }
          return nil unless ticker_data

          divisor = price_divisor(symbol)
          {
            symbol: symbol,
            bid: BigDecimal(ticker_data['minPrice'].to_s) / divisor,
            ask: BigDecimal(ticker_data['maxPrice'].to_s) / divisor,
            timestamp: Time.now.to_i * 1000
          }
        end

        def tickers(symbols = nil)
          data = get("#{API_URL}/prices/tickers")

          result = {}
          data.each do |t|
            sym = t['tokenSymbol']
            next if symbols && !symbols.include?(sym)
            next if result[sym] # Skip duplicates

            divisor = price_divisor(sym)
            result[sym] = {
              bid: BigDecimal(t['minPrice'].to_s) / divisor,
              ask: BigDecimal(t['maxPrice'].to_s) / divisor,
              timestamp: Time.now.to_i * 1000
            }
          end
          result
        end

        # Calculate price divisor based on token decimals
        # GMX formula: actualPrice = rawPrice / 10^(30 - tokenDecimals)
        def price_divisor(symbol)
          decimals = TOKEN_DECIMALS[symbol] || DEFAULT_DECIMALS
          BigDecimal(10)**(30 - decimals)
        end

        def orderbook(symbol, depth: 20)
          # GMX doesn't have traditional orderbook, uses oracle pricing
          ticker_data = ticker(symbol)
          return nil unless ticker_data

          # Create synthetic orderbook from bid/ask spread
          mid = (ticker_data[:bid] + ticker_data[:ask]) / 2
          spread = ticker_data[:ask] - ticker_data[:bid]

          bids = (1..depth).map do |i|
            price = mid - (spread * i / 2)
            [price, BigDecimal('1000000')] # Infinite liquidity at oracle price
          end

          asks = (1..depth).map do |i|
            price = mid + (spread * i / 2)
            [price, BigDecimal('1000000')]
          end

          {
            bids: bids,
            asks: asks,
            timestamp: Time.now.to_i * 1000,
            type: :oracle_based
          }
        end

        def funding_rate(symbol)
          # GMX uses funding rates based on utilization
          # This would need to query the contracts for accurate rates
          {
            symbol: symbol,
            rate: BigDecimal('0'),
            predicted_rate: nil,
            next_funding_time: nil,
            interval_hours: 1,
            note: 'GMX uses dynamic funding based on utilization'
          }
        end
      end
    end
  end
end
