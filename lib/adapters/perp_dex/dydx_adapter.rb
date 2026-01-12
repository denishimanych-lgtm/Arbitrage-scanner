# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class DydxAdapter < BaseAdapter
        # dYdX v4 (Cosmos-based)
        API_URL = 'https://indexer.dydx.trade/v4'

        def dex_id
          'dydx'
        end

        def markets
          data = get("#{API_URL}/perpetualMarkets")

          data['markets'].map do |symbol, market|
            {
              symbol: symbol,
              base_asset: market['baseAsset'],
              quote_asset: 'USD',
              status: market['status'] == 'ACTIVE' ? 'active' : 'inactive'
            }
          end
        end

        def ticker(symbol)
          data = get("#{API_URL}/perpetualMarkets")

          market = data['markets'][symbol]
          return nil unless market

          {
            symbol: symbol,
            bid: BigDecimal(market['indexPrice'].to_s),
            ask: BigDecimal(market['indexPrice'].to_s),
            mark_price: BigDecimal(market['oraclePrice'].to_s),
            index_price: BigDecimal(market['indexPrice'].to_s),
            volume_24h: BigDecimal(market['volume24H'].to_s),
            timestamp: Time.now.to_i * 1000
          }
        end

        def tickers(symbols = nil)
          data = get("#{API_URL}/perpetualMarkets")

          result = {}
          data['markets'].each do |symbol, market|
            next if symbols && !symbols.include?(symbol)
            next unless market['status'] == 'ACTIVE'
            # Skip if price data is missing
            next if market['indexPrice'].to_s.empty? || market['oraclePrice'].to_s.empty?

            result[symbol] = {
              bid: BigDecimal(market['indexPrice'].to_s),
              ask: BigDecimal(market['indexPrice'].to_s),
              mark_price: BigDecimal(market['oraclePrice'].to_s),
              index_price: BigDecimal(market['indexPrice'].to_s),
              volume_24h: BigDecimal(market['volume24H'].to_s),
              open_interest: BigDecimal(market['openInterest'].to_s),
              timestamp: Time.now.to_i * 1000
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{API_URL}/orderbooks/perpetualMarket/#{symbol}")

          {
            bids: data['bids'].first(depth).map { |l| [BigDecimal(l['price']), BigDecimal(l['size'])] },
            asks: data['asks'].first(depth).map { |l| [BigDecimal(l['price']), BigDecimal(l['size'])] },
            timestamp: Time.now.to_i * 1000
          }
        end

        def funding_rate(symbol)
          data = get("#{API_URL}/perpetualMarkets")

          market = data['markets'][symbol]
          return nil unless market

          {
            symbol: symbol,
            rate: BigDecimal(market['nextFundingRate'].to_s),
            predicted_rate: nil,
            next_funding_time: Time.parse(market['nextFundingAt']).to_i * 1000,
            interval_hours: 1
          }
        end

        def funding_history(symbol, limit: 100)
          data = get("#{API_URL}/historicalFunding/#{symbol}?limit=#{limit}")

          data['historicalFunding'].map do |entry|
            {
              symbol: symbol,
              rate: BigDecimal(entry['rate'].to_s),
              timestamp: Time.parse(entry['effectiveAt']).to_i * 1000
            }
          end
        end
      end
    end
  end
end
