# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class OkxAdapter < BaseAdapter
        BASE_URL = 'https://www.okx.com'

        def exchange_id
          'okx'
        end

        def futures_symbols
          data = get("#{BASE_URL}/api/v5/public/instruments?instType=SWAP")

          data['data']
            .select { |s| s['state'] == 'live' && s['settleCcy'] == 'USDT' }
            .map do |s|
              {
                symbol: s['instId'],
                base_asset: s['ctValCcy'],
                quote_asset: s['settleCcy'],
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{BASE_URL}/api/v5/public/instruments?instType=SPOT")

          data['data']
            .select { |s| s['state'] == 'live' && s['quoteCcy'] == 'USDT' }
            .map do |s|
              {
                symbol: s['instId'],
                base_asset: s['baseCcy'],
                quote_asset: s['quoteCcy'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{BASE_URL}/api/v5/asset/currencies?ccy=#{asset}")

          return nil if data['data'].empty?

          networks = data['data'].map do |c|
            {
              chain: normalize_network(c['chain']),
              contract: c['ctAddr'],
              deposit_enabled: c['canDep'],
              withdraw_enabled: c['canWd'],
              name: c['chain']
            }
          end

          { coin: asset, networks: networks }
        end

        def ticker(symbol)
          data = get("#{BASE_URL}/api/v5/market/ticker?instId=#{symbol}")

          t = data['data'].first
          {
            symbol: t['instId'],
            bid: BigDecimal(t['bidPx']),
            ask: BigDecimal(t['askPx']),
            last: BigDecimal(t['last']),
            timestamp: t['ts'].to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{BASE_URL}/api/v5/market/tickers?instType=SWAP")

          result = {}
          data['data'].each do |t|
            next if symbols && !symbols.include?(t['instId'])
            result[t['instId']] = {
              bid: BigDecimal(t['bidPx']),
              ask: BigDecimal(t['askPx']),
              last: BigDecimal(t['last']),
              timestamp: t['ts'].to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          # OKX limit: 1, 5, 20, 400
          limit = depth <= 5 ? 5 : 20
          data = get("#{BASE_URL}/api/v5/market/books?instId=#{symbol}&sz=#{limit}")

          book = data['data'].first
          {
            bids: book['bids'].map { |l| [BigDecimal(l[0]), BigDecimal(l[1])] },
            asks: book['asks'].map { |l| [BigDecimal(l[0]), BigDecimal(l[1])] },
            timestamp: book['ts'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{BASE_URL}/api/v5/public/funding-rate?instId=#{symbol}")

          fr = data['data'].first
          {
            symbol: fr['instId'],
            rate: BigDecimal(fr['fundingRate']),
            next_funding_time: fr['nextFundingTime'].to_i
          }
        end

        private

        def normalize_network(chain)
          case chain.to_s.split('-').first.upcase
          when 'SOL' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20' then 'bsc'
          when 'ARBITRUM' then 'arbitrum'
          when 'AVAXC' then 'avalanche'
          else chain.to_s.downcase
          end
        end
      end
    end
  end
end
