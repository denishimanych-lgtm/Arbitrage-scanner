# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class HtxAdapter < BaseAdapter
        SPOT_URL = 'https://api.huobi.pro'
        FUTURES_URL = 'https://api.hbdm.com'

        def exchange_id
          'htx'
        end

        def futures_symbols
          data = get("#{FUTURES_URL}/linear-swap-api/v1/swap_contract_info")

          data['data']
            .select { |s| s['contract_status'] == 1 }
            .map do |s|
              {
                symbol: s['contract_code'],
                base_asset: s['symbol'],
                quote_asset: 'USDT',
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{SPOT_URL}/v2/settings/common/symbols")

          data['data']
            .select { |s| s['state'] == 'online' && s['qc'] == 'usdt' }
            .map do |s|
              {
                symbol: s['sc'],
                base_asset: s['bc'],
                quote_asset: s['qc'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{SPOT_URL}/v2/reference/currencies?currency=#{asset.downcase}")

          return nil if data['data'].empty?

          coin = data['data'].first
          networks = coin['chains'].map do |c|
            {
              chain: normalize_network(c['chain']),
              contract: c['contractAddress'],
              deposit_enabled: c['depositStatus'] == 'allowed',
              withdraw_enabled: c['withdrawStatus'] == 'allowed',
              name: c['displayName']
            }
          end

          { coin: coin['currency'].upcase, networks: networks }
        end

        def ticker(symbol)
          data = get("#{FUTURES_URL}/linear-swap-ex/market/detail/merged?contract_code=#{symbol}")

          t = data['tick']
          {
            symbol: symbol,
            bid: BigDecimal(t['bid'][0].to_s),
            ask: BigDecimal(t['ask'][0].to_s),
            last: BigDecimal(t['close'].to_s),
            timestamp: data['ts'].to_i
          }
        end

        def tickers(symbols = nil)
          data = get("#{FUTURES_URL}/linear-swap-ex/market/detail/batch_merged")

          result = {}
          data['ticks'].each do |t|
            next if symbols && !symbols.include?(t['contract_code'])
            result[t['contract_code']] = {
              bid: BigDecimal(t['bid'][0].to_s),
              ask: BigDecimal(t['ask'][0].to_s),
              last: BigDecimal(t['close'].to_s),
              timestamp: data['ts'].to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          # HTX supports: step0-step5, step0 is most granular
          data = get("#{FUTURES_URL}/linear-swap-ex/market/depth?contract_code=#{symbol}&type=step0")

          tick = data['tick']
          {
            bids: tick['bids'].first(depth).map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
            asks: tick['asks'].first(depth).map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
            timestamp: tick['ts'].to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{FUTURES_URL}/linear-swap-api/v1/swap_funding_rate?contract_code=#{symbol}")

          fr = data['data']
          {
            symbol: symbol,
            rate: BigDecimal(fr['funding_rate'].to_s),
            next_funding_time: fr['next_funding_time'].to_i
          }
        end

        private

        def normalize_network(chain)
          case chain.to_s.upcase
          when 'SOL', 'SOLANA' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20', 'HECO' then 'bsc'
          when 'ARBITRUM' then 'arbitrum'
          when 'AVAXC' then 'avalanche'
          else chain.to_s.downcase
          end
        end
      end
    end
  end
end
