# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class AsterAdapter < BaseAdapter
        # Aster (formerly Aevo)
        API_URL = 'https://api.aevo.xyz'

        def dex_id
          'aster'
        end

        def markets
          data = get("#{API_URL}/markets")

          data
            .select { |m| m['instrument_type'] == 'PERPETUAL' && m['is_active'] }
            .map do |market|
              {
                symbol: market['instrument_name'],
                base_asset: market['underlying_asset'],
                quote_asset: 'USDC',
                status: 'active'
              }
            end
        end

        def ticker(symbol)
          data = get("#{API_URL}/ticker?instrument_name=#{symbol}")

          {
            symbol: symbol,
            bid: BigDecimal(data['best_bid'].to_s),
            ask: BigDecimal(data['best_ask'].to_s),
            mark_price: BigDecimal(data['mark_price'].to_s),
            index_price: BigDecimal(data['index_price'].to_s),
            volume_24h: BigDecimal(data['daily_volume'].to_s),
            funding_rate: BigDecimal(data['funding_rate'].to_s),
            timestamp: data['timestamp'].to_i
          }
        end

        def tickers(symbols = nil)
          # Get all markets and fetch tickers
          all_markets = markets

          result = {}
          all_markets.each do |market|
            sym = market[:symbol]
            next if symbols && !symbols.include?(sym)

            begin
              t = ticker(sym)
              result[sym] = t if t
            rescue ApiError
              next
            end
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{API_URL}/orderbook?instrument_name=#{symbol}")

          {
            bids: data['bids'].first(depth).map { |l| [BigDecimal(l[0]), BigDecimal(l[1])] },
            asks: data['asks'].first(depth).map { |l| [BigDecimal(l[0]), BigDecimal(l[1])] },
            timestamp: data['timestamp'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{API_URL}/funding?instrument_name=#{symbol}")

          {
            symbol: symbol,
            rate: BigDecimal(data['funding_rate'].to_s),
            predicted_rate: BigDecimal(data['next_funding_rate'].to_s),
            next_funding_time: data['next_funding_time'].to_i,
            interval_hours: 1
          }
        end

        def funding_history(symbol, limit: 100)
          data = get("#{API_URL}/funding-history?instrument_name=#{symbol}&limit=#{limit}")

          data['funding_history'].map do |entry|
            {
              symbol: symbol,
              rate: BigDecimal(entry['funding_rate'].to_s),
              timestamp: entry['timestamp'].to_i
            }
          end
        end
      end
    end
  end
end
