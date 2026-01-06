# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class BitgetAdapter < BaseAdapter
        BASE_URL = 'https://api.bitget.com'

        def exchange_id
          'bitget'
        end

        def futures_symbols
          data = get("#{BASE_URL}/api/v2/mix/market/contracts?productType=USDT-FUTURES")

          data['data']
            .select { |s| s['symbolStatus'] == 'normal' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseCoin'],
                quote_asset: s['quoteCoin'],
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{BASE_URL}/api/v2/spot/public/symbols")

          data['data']
            .select { |s| s['status'] == 'online' && s['quoteCoin'] == 'USDT' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseCoin'],
                quote_asset: s['quoteCoin'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{BASE_URL}/api/v2/spot/public/coins?coin=#{asset}")

          return nil if data['data'].empty?

          coin = data['data'].first
          networks = coin['chains'].map do |c|
            {
              chain: normalize_network(c['chain']),
              contract: c['contractAddress'],
              deposit_enabled: c['rechargeable'] == 'true',
              withdraw_enabled: c['withdrawable'] == 'true',
              name: c['chain']
            }
          end

          { coin: coin['coin'], networks: networks }
        end

        def ticker(symbol)
          data = get("#{BASE_URL}/api/v2/mix/market/ticker?symbol=#{symbol}&productType=USDT-FUTURES")

          t = data['data'].first
          {
            symbol: t['symbol'],
            bid: BigDecimal(t['bidPr']),
            ask: BigDecimal(t['askPr']),
            last: BigDecimal(t['lastPr']),
            timestamp: t['ts'].to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{BASE_URL}/api/v2/mix/market/tickers?productType=USDT-FUTURES")

          result = {}
          data['data'].each do |t|
            next if symbols && !symbols.include?(t['symbol'])
            result[t['symbol']] = {
              bid: BigDecimal(t['bidPr']),
              ask: BigDecimal(t['askPr']),
              last: BigDecimal(t['lastPr']),
              timestamp: t['ts'].to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{BASE_URL}/api/v2/mix/market/depth?symbol=#{symbol}&productType=USDT-FUTURES&limit=#{depth}")

          {
            bids: data['data']['bids'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            asks: data['data']['asks'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            timestamp: data['data']['ts'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{BASE_URL}/api/v2/mix/market/current-fund-rate?symbol=#{symbol}&productType=USDT-FUTURES")

          {
            symbol: symbol,
            rate: BigDecimal(data['data'].first['fundingRate']),
            next_funding_time: nil
          }
        end

        private

        def normalize_network(chain)
          case chain.to_s.upcase
          when 'SOL', 'SOLANA' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20' then 'bsc'
          when 'ARBITRUMONE' then 'arbitrum'
          when 'AVAXC' then 'avalanche'
          else chain.to_s.downcase
          end
        end
      end
    end
  end
end
