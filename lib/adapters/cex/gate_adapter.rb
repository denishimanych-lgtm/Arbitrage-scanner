# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class GateAdapter < BaseAdapter
        BASE_URL = 'https://api.gateio.ws/api/v4'

        def exchange_id
          'gate'
        end

        def futures_symbols
          data = get("#{BASE_URL}/futures/usdt/contracts")

          data
            .select { |s| !s['in_delisting'] }
            .map do |s|
              {
                symbol: s['name'],
                base_asset: s['name'].gsub('_USDT', ''),
                quote_asset: 'USDT',
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{BASE_URL}/spot/currency_pairs")

          data
            .select { |s| s['trade_status'] == 'tradable' && s['quote'] == 'USDT' }
            .map do |s|
              {
                symbol: s['id'],
                base_asset: s['base'],
                quote_asset: s['quote'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{BASE_URL}/wallet/currency_chains?currency=#{asset}")

          return nil if data.empty?

          networks = data.map do |c|
            {
              chain: normalize_network(c['chain']),
              contract: c['contract_address'],
              deposit_enabled: !c['is_deposit_disabled'],
              withdraw_enabled: !c['is_withdraw_disabled'],
              name: c['name_cn'] || c['chain']
            }
          end

          { coin: asset, networks: networks }
        end

        def ticker(symbol)
          data = get("#{BASE_URL}/futures/usdt/tickers?contract=#{symbol}")

          t = data.first
          {
            symbol: t['contract'],
            bid: BigDecimal(t['highest_bid']),
            ask: BigDecimal(t['lowest_ask']),
            last: BigDecimal(t['last']),
            timestamp: (Time.now.to_f * 1000).to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{BASE_URL}/futures/usdt/tickers")

          result = {}
          data.each do |t|
            next if symbols && !symbols.include?(t['contract'])
            result[t['contract']] = {
              bid: BigDecimal(t['highest_bid']),
              ask: BigDecimal(t['lowest_ask']),
              last: BigDecimal(t['last']),
              timestamp: (Time.now.to_f * 1000).to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = get("#{BASE_URL}/futures/usdt/order_book?contract=#{symbol}&limit=#{depth}")

          {
            bids: data['bids'].map { |l| [BigDecimal(l['p']), BigDecimal(l['s'])] },
            asks: data['asks'].map { |l| [BigDecimal(l['p']), BigDecimal(l['s'])] },
            timestamp: (data['current'].to_f * 1000).to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{BASE_URL}/futures/usdt/contracts/#{symbol}")

          {
            symbol: data['name'],
            rate: BigDecimal(data['funding_rate']),
            next_funding_time: data['funding_next_apply'].to_i * 1000
          }
        end

        private

        def normalize_network(chain)
          case chain.to_s.upcase
          when 'SOL' then 'solana'
          when 'ETH' then 'ethereum'
          when 'BSC' then 'bsc'
          when 'ARB', 'ARBITRUM' then 'arbitrum'
          when 'AVAX' then 'avalanche'
          else chain.to_s.downcase
          end
        end
      end
    end
  end
end
