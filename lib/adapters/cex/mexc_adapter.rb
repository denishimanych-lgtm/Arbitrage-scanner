# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class MexcAdapter < BaseAdapter
        SPOT_URL = 'https://api.mexc.com'
        FUTURES_URL = 'https://contract.mexc.com'

        def exchange_id
          'mexc'
        end

        def futures_symbols
          data = get("#{FUTURES_URL}/api/v1/contract/detail")

          data['data']
            .select { |s| s['state'] == 0 && s['quoteCoin'] == 'USDT' }
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
          data = get("#{SPOT_URL}/api/v3/exchangeInfo")

          data['symbols']
            .select { |s| s['status'] == 'ENABLED' && s['quoteAsset'] == 'USDT' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseAsset'],
                quote_asset: s['quoteAsset'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{SPOT_URL}/api/v3/capital/config/getall")

          coin = data.find { |c| c['coin'].upcase == asset.upcase }
          return nil unless coin

          networks = coin['networkList'].map do |n|
            {
              chain: normalize_network(n['network']),
              contract: n['contract'],
              deposit_enabled: n['depositEnable'],
              withdraw_enabled: n['withdrawEnable'],
              name: n['name']
            }
          end

          { coin: coin['coin'], networks: networks }
        end

        def ticker(symbol)
          data = get("#{FUTURES_URL}/api/v1/contract/ticker?symbol=#{symbol}")

          t = data['data']
          {
            symbol: t['symbol'],
            bid: BigDecimal(t['bid1'].to_s),
            ask: BigDecimal(t['ask1'].to_s),
            last: BigDecimal(t['lastPrice'].to_s),
            timestamp: t['timestamp'].to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{FUTURES_URL}/api/v1/contract/ticker")

          result = {}
          data['data'].each do |t|
            next if symbols && !symbols.include?(t['symbol'])
            result[t['symbol']] = {
              bid: BigDecimal(t['bid1'].to_s),
              ask: BigDecimal(t['ask1'].to_s),
              last: BigDecimal(t['lastPrice'].to_s),
              timestamp: t['timestamp'].to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{FUTURES_URL}/api/v1/contract/depth/#{symbol}?limit=#{depth}")

          {
            bids: data['data']['bids'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
            asks: data['data']['asks'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
            timestamp: data['data']['timestamp'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{FUTURES_URL}/api/v1/contract/funding_rate/#{symbol}")

          {
            symbol: symbol,
            rate: BigDecimal(data['data']['fundingRate'].to_s),
            next_funding_time: data['data']['nextSettleTime'].to_i
          }
        end

        private

        def normalize_network(network)
          case network.to_s.upcase
          when 'SOL' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20' then 'bsc'
          when 'ARB', 'ARBITRUM' then 'arbitrum'
          when 'AVAX', 'AVAXC' then 'avalanche'
          else network.to_s.downcase
          end
        end
      end
    end
  end
end
