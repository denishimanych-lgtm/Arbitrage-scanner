# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class HyperliquidAdapter < BaseAdapter
        API_URL = 'https://api.hyperliquid.xyz'

        def dex_id
          'hyperliquid'
        end

        def markets
          data = post("#{API_URL}/info", body: { type: 'meta' })

          data['universe'].map.with_index do |market, idx|
            {
              symbol: market['name'],
              base_asset: market['name'],
              quote_asset: 'USD',
              status: 'active',
              index: idx
            }
          end
        end

        def ticker(symbol)
          data = post("#{API_URL}/info", body: { type: 'allMids' })

          price = data[symbol]
          return nil unless price

          {
            symbol: symbol,
            mid: BigDecimal(price.to_s),
            timestamp: Time.now.to_i * 1000
          }
        end

        def tickers(symbols = nil)
          all_mids = post("#{API_URL}/info", body: { type: 'allMids' })
          meta = post("#{API_URL}/info", body: { type: 'metaAndAssetCtxs' })

          asset_ctxs = meta[1] # Array of asset contexts

          result = {}
          all_mids.each do |sym, mid|
            next if symbols && !symbols.include?(sym)
            # Skip if mid price is missing
            next if mid.to_s.empty?

            ctx = asset_ctxs.find { |a| a['coin'] == sym } || {}
            # Skip if mark price is missing
            next if ctx['markPx'].to_s.empty?

            result[sym] = {
              mid: BigDecimal(mid.to_s),
              mark_price: BigDecimal(ctx['markPx'].to_s),
              funding_rate: ctx['funding'].to_s.empty? ? BigDecimal('0') : BigDecimal(ctx['funding'].to_s),
              open_interest: ctx['openInterest'].to_s.empty? ? BigDecimal('0') : BigDecimal(ctx['openInterest'].to_s),
              timestamp: Time.now.to_i * 1000
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          data = post("#{API_URL}/info", body: { type: 'l2Book', coin: symbol })

          levels = data['levels']
          {
            bids: levels[0].first(depth).map { |l| [BigDecimal(l['px']), BigDecimal(l['sz'])] },
            asks: levels[1].first(depth).map { |l| [BigDecimal(l['px']), BigDecimal(l['sz'])] },
            timestamp: Time.now.to_i * 1000
          }
        end

        def funding_rate(symbol)
          data = post("#{API_URL}/info", body: { type: 'metaAndAssetCtxs' })

          asset_ctxs = data[1]
          ctx = asset_ctxs.find { |a| a['coin'] == symbol }

          return nil unless ctx

          {
            symbol: symbol,
            rate: BigDecimal(ctx['funding'].to_s),
            predicted_rate: nil,
            next_funding_time: nil,
            interval_hours: 1
          }
        end

        def funding_history(symbol, start_time: nil)
          body = { type: 'fundingHistory', coin: symbol }
          body[:startTime] = start_time if start_time

          data = post("#{API_URL}/info", body: body)

          data.map do |entry|
            {
              symbol: symbol,
              rate: BigDecimal(entry['fundingRate'].to_s),
              timestamp: entry['time']
            }
          end
        end
      end
    end
  end
end
