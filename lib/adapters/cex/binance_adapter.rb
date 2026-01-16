# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class BinanceAdapter < BaseAdapter
        FUTURES_BASE_URL = 'https://fapi.binance.com'
        SPOT_BASE_URL = 'https://api.binance.com'

        def exchange_id
          'binance'
        end

        def futures_symbols
          data = get("#{FUTURES_BASE_URL}/fapi/v1/exchangeInfo")

          data['symbols']
            .select { |s| s['contractType'] == 'PERPETUAL' && s['status'] == 'TRADING' }
            .map do |s|
              {
                symbol: s['symbol'],
                base_asset: s['baseAsset'],
                quote_asset: s['quoteAsset'],
                status: 'active'
              }
            end
        end

        def spot_symbols
          data = get("#{SPOT_BASE_URL}/api/v3/exchangeInfo")

          data['symbols']
            .select { |s| s['status'] == 'TRADING' && s['quoteAsset'] == 'USDT' }
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
          data = get("#{SPOT_BASE_URL}/sapi/v1/capital/config/getall")

          coin = data.find { |c| c['coin'].upcase == asset.upcase }
          return nil unless coin

          networks = coin['networkList'].map do |n|
            {
              chain: normalize_network(n['network']),
              contract: n['contractAddress'],
              deposit_enabled: n['depositEnable'],
              withdraw_enabled: n['withdrawEnable'],
              name: n['name']
            }
          end

          { coin: coin['coin'], networks: networks }
        end

        def ticker(symbol, market_type: :futures)
          base_url = market_type == :spot ? SPOT_BASE_URL : FUTURES_BASE_URL
          endpoint = market_type == :spot ? '/api/v3/ticker/bookTicker' : '/fapi/v1/ticker/bookTicker'
          data = get("#{base_url}#{endpoint}?symbol=#{symbol}")

          {
            symbol: data['symbol'],
            bid: BigDecimal(data['bidPrice']),
            ask: BigDecimal(data['askPrice']),
            timestamp: data['time'] || (Time.now.to_f * 1000).to_i
          }
        end

        def tickers(symbols = nil, market_type: :futures)
          base_url = market_type == :spot ? SPOT_BASE_URL : FUTURES_BASE_URL
          endpoint = market_type == :spot ? '/api/v3/ticker/bookTicker' : '/fapi/v1/ticker/bookTicker'
          data = get("#{base_url}#{endpoint}")

          result = {}
          data.each do |t|
            next if symbols && !symbols.include?(t['symbol'])
            result[t['symbol']] = {
              bid: BigDecimal(t['bidPrice']),
              ask: BigDecimal(t['askPrice']),
              timestamp: t['time'] || (Time.now.to_f * 1000).to_i
            }
          end
          result
        end

        def orderbook(symbol, depth: 20, market_type: :futures)
          base_url = market_type == :spot ? SPOT_BASE_URL : FUTURES_BASE_URL
          endpoint = market_type == :spot ? '/api/v3/depth' : '/fapi/v1/depth'
          data = get("#{base_url}#{endpoint}?symbol=#{symbol}&limit=#{depth}")

          {
            bids: data['bids'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            asks: data['asks'].map { |p, q| [BigDecimal(p), BigDecimal(q)] },
            timestamp: data['T'] || (Time.now.to_f * 1000).to_i
          }
        end

        def funding_rate(symbol)
          data = get("#{FUTURES_BASE_URL}/fapi/v1/premiumIndex?symbol=#{symbol}")

          {
            symbol: data['symbol'],
            rate: BigDecimal(data['lastFundingRate']),
            next_funding_time: data['nextFundingTime'],
            mark_price: BigDecimal(data['markPrice'])
          }
        end

        private

        def normalize_network(network)
          case network.upcase
          when 'SOL' then 'solana'
          when 'ETH' then 'ethereum'
          when 'BSC' then 'bsc'
          when 'ARBITRUM', 'ARBITRUMONE' then 'arbitrum'
          when 'AVAXC' then 'avalanche'
          else network.downcase
          end
        end
      end
    end
  end
end
