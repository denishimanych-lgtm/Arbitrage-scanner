# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class KucoinAdapter < BaseAdapter
        SPOT_URL = 'https://api.kucoin.com'
        FUTURES_URL = 'https://api-futures.kucoin.com'

        def exchange_id
          'kucoin'
        end

        def futures_symbols
          data = get("#{FUTURES_URL}/api/v1/contracts/active")

          data['data']
            .select { |s| s['status'] == 'Open' && s['quoteCurrency'] == 'USDT' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseCurrency'],
                quote_asset: s['quoteCurrency'],
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{SPOT_URL}/api/v2/symbols")

          data['data']
            .select { |s| s['enableTrading'] && s['quoteCurrency'] == 'USDT' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseCurrency'],
                quote_asset: s['quoteCurrency'],
                status: 'active'
              }
            end
        end

        def asset_details(asset)
          data = get("#{SPOT_URL}/api/v2/currencies/#{asset}")

          return nil unless data['data']

          coin = data['data']
          networks = (coin['chains'] || []).map do |c|
            {
              chain: normalize_network(c['chainName']),
              contract: c['contractAddress'],
              deposit_enabled: c['isDepositEnabled'],
              withdraw_enabled: c['isWithdrawEnabled'],
              name: c['chainName']
            }
          end

          { coin: coin['currency'], networks: networks }
        end

        def ticker(symbol, market_type: :futures)
          if market_type == :spot
            # Convert futures symbol to spot (e.g., BTCUSDTM -> BTC-USDT)
            spot_symbol = symbol.gsub(/USDTM$/, '-USDT')
            data = get("#{SPOT_URL}/api/v1/market/orderbook/level1?symbol=#{spot_symbol}")
            t = data['data']
            {
              symbol: spot_symbol,
              bid: BigDecimal(t['bestBid'].to_s),
              ask: BigDecimal(t['bestAsk'].to_s),
              last: BigDecimal(t['price'].to_s),
              timestamp: t['time'].to_i
            }
          else
            data = get("#{FUTURES_URL}/api/v1/ticker?symbol=#{symbol}")
            t = data['data']
            {
              symbol: t['symbol'],
              bid: BigDecimal(t['bestBidPrice'].to_s),
              ask: BigDecimal(t['bestAskPrice'].to_s),
              last: BigDecimal(t['price'].to_s),
              timestamp: t['ts'].to_i
            }
          end
        end

        def tickers(symbols = nil, market_type: :futures)
          data = get("#{SPOT_URL}/api/v1/market/allTickers")
          result = {}

          data['data']['ticker'].each do |t|
            next unless t['symbol'].end_with?('-USDT')
            next if t['buy'].to_s.empty? || t['sell'].to_s.empty? || t['last'].to_s.empty?

            if market_type == :spot
              # Return spot symbols with spot format
              spot_symbol = t['symbol']
              next if symbols && !symbols.include?(spot_symbol)
              result[spot_symbol] = {
                bid: BigDecimal(t['buy'].to_s),
                ask: BigDecimal(t['sell'].to_s),
                last: BigDecimal(t['last'].to_s),
                timestamp: data['data']['time'].to_i
              }
            else
              # Return with futures symbol format
              futures_symbol = "#{t['symbol'].gsub('-USDT', '')}USDTM"
              next if symbols && !symbols.include?(futures_symbol)
              result[futures_symbol] = {
                bid: BigDecimal(t['buy'].to_s),
                ask: BigDecimal(t['sell'].to_s),
                last: BigDecimal(t['last'].to_s),
                timestamp: data['data']['time'].to_i
              }
            end
          end
          result
        end

        def orderbook(symbol, depth: 20, market_type: :futures)
          if market_type == :spot
            spot_symbol = symbol.gsub(/USDTM$/, '-USDT')
            data = get("#{SPOT_URL}/api/v1/market/orderbook/level2_#{depth}?symbol=#{spot_symbol}")
            {
              bids: data['data']['bids'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
              asks: data['data']['asks'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
              timestamp: data['data']['time'].to_i
            }
          else
            data = get("#{FUTURES_URL}/api/v1/level2/depth#{depth}?symbol=#{symbol}")
            {
              bids: data['data']['bids'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
              asks: data['data']['asks'].map { |p, q| [BigDecimal(p.to_s), BigDecimal(q.to_s)] },
              timestamp: data['data']['ts'].to_i
            }
          end
        end

        def funding_rate(symbol)
          data = get("#{FUTURES_URL}/api/v1/funding-rate/#{symbol}/current")

          {
            symbol: symbol,
            rate: BigDecimal(data['data']['value'].to_s),
            next_funding_time: data['data']['timePoint'].to_i
          }
        end

        private

        def normalize_network(chain)
          case chain.to_s.upcase
          when 'SOL', 'SOLANA' then 'solana'
          when 'ETH', 'ERC20' then 'ethereum'
          when 'BSC', 'BEP20' then 'bsc'
          when 'ARBITRUM' then 'arbitrum'
          when 'AVAX', 'AVAXC' then 'avalanche'
          else chain.to_s.downcase
          end
        end
      end
    end
  end
end
