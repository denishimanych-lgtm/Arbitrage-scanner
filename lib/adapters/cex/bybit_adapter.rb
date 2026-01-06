# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class BybitAdapter < BaseAdapter
        BASE_URL = 'https://api.bybit.com'

        def exchange_id
          'bybit'
        end

        def futures_symbols
          data = get("#{BASE_URL}/v5/market/instruments-info?category=linear")

          data['result']['list']
            .select { |s| s['status'] == 'Trading' && s['quoteCoin'] == 'USDT' }
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
          data = get("#{BASE_URL}/v5/market/instruments-info?category=spot")

          data['result']['list']
            .select { |s| s['status'] == 'Trading' && s['quoteCoin'] == 'USDT' }
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
          data = get("#{BASE_URL}/v5/asset/coin/query-info?coin=#{asset}")

          return nil if data['result']['rows'].empty?

          coin = data['result']['rows'].first
          networks = coin['chains'].map do |c|
            {
              chain: normalize_network(c['chain']),
              contract: c['chainType'] == 'SOL' ? coin['coin'] : nil,
              deposit_enabled: c['chainDeposit'] == '1',
              withdraw_enabled: c['chainWithdraw'] == '1',
              name: c['chain']
            }
          end

          { coin: coin['coin'], networks: networks }
        end

        def ticker(symbol)
          data = get("#{BASE_URL}/v5/market/tickers?category=linear&symbol=#{symbol}")

          t = data['result']['list'].first
          {
            symbol: t['symbol'],
            bid: BigDecimal(t['bid1Price']),
            ask: BigDecimal(t['ask1Price']),
            last: BigDecimal(t['lastPrice']),
            timestamp: data['time'].to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{BASE_URL}/v5/market/tickers?category=linear")

          result = {}
          data['result']['list'].each do |t|
            next if symbols && !symbols.include?(t['symbol'])
            result[t['symbol']] = {
              bid: BigDecimal(t['bid1Price']),
              ask: BigDecimal(t['ask1Price']),
              last: BigDecimal(t['lastPrice']),
              timestamp: data['time'].to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{BASE_URL}/v5/market/orderbook?category=linear&symbol=#{symbol}&limit=#{depth}")

          {
            bids: data['result']['b'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            asks: data['result']['a'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            timestamp: data['result']['ts'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{BASE_URL}/v5/market/tickers?category=linear&symbol=#{symbol}")

          t = data['result']['list'].first
          {
            symbol: t['symbol'],
            rate: BigDecimal(t['fundingRate']),
            next_funding_time: t['nextFundingTime'].to_i
          }
        end

        private

        def normalize_network(network)
          case network.upcase
          when 'SOL' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20' then 'bsc'
          when 'ARBI', 'ARBITRUM' then 'arbitrum'
          when 'AVAXC' then 'avalanche'
          else network.downcase
          end
        end
      end
    end
  end
end
