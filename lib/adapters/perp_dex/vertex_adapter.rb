# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class VertexAdapter < BaseAdapter
        API_URL = 'https://prod.vertexprotocol-backend.com'
        GATEWAY_URL = 'https://gateway.prod.vertexprotocol.com/v1'

        def dex_id
          'vertex'
        end

        def markets
          data = post("#{GATEWAY_URL}/query", body: { type: 'all_products' })

          perp_products = data['data']['perp_products'] || []

          perp_products.map do |product|
            {
              symbol: product['symbol'] || "PERP-#{product['product_id']}",
              product_id: product['product_id'],
              base_asset: extract_base_asset(product),
              quote_asset: 'USDC',
              status: 'active'
            }
          end
        end

        def ticker(symbol)
          # Find product_id for symbol
          products = markets
          product = products.find { |p| p[:symbol] == symbol }
          return nil unless product

          data = post("#{GATEWAY_URL}/query", body: {
            type: 'market_price',
            product_id: product[:product_id]
          })

          {
            symbol: symbol,
            bid: BigDecimal(data['data']['bid'].to_s),
            ask: BigDecimal(data['data']['ask'].to_s),
            mark_price: BigDecimal(data['data']['mark_price'].to_s),
            timestamp: Time.now.to_i * 1000
          }
        end

        def tickers(symbols = nil)
          data = post("#{GATEWAY_URL}/query", body: { type: 'all_products' })

          perp_products = data['data']['perp_products'] || []

          result = {}
          perp_products.each do |product|
            symbol = product['symbol'] || "PERP-#{product['product_id']}"
            next if symbols && !symbols.include?(symbol)

            oracle = product['oracle_price_x18']
            price = oracle ? BigDecimal(oracle.to_s) / 1e18 : BigDecimal('0')

            result[symbol] = {
              mid: price,
              mark_price: price,
              product_id: product['product_id'],
              timestamp: Time.now.to_i * 1000
            }
          end
          result
        end

        def orderbook(symbol, depth: 20)
          products = markets
          product = products.find { |p| p[:symbol] == symbol }
          return nil unless product

          data = post("#{GATEWAY_URL}/query", body: {
            type: 'order_book',
            product_id: product[:product_id],
            depth: depth
          })

          book = data['data']
          {
            bids: (book['bids'] || []).map { |l| [BigDecimal(l['price']), BigDecimal(l['quantity'])] },
            asks: (book['asks'] || []).map { |l| [BigDecimal(l['price']), BigDecimal(l['quantity'])] },
            timestamp: Time.now.to_i * 1000
          }
        end

        def funding_rate(symbol)
          products = markets
          product = products.find { |p| p[:symbol] == symbol }
          return nil unless product

          data = post("#{GATEWAY_URL}/query", body: {
            type: 'funding_rate',
            product_id: product[:product_id]
          })

          {
            symbol: symbol,
            rate: BigDecimal(data['data']['funding_rate_x18'].to_s) / 1e18,
            predicted_rate: nil,
            next_funding_time: nil,
            interval_hours: 1
          }
        end

        private

        def extract_base_asset(product)
          # Extract base asset from product symbol or name
          symbol = product['symbol'] || ''
          symbol.gsub(/-PERP$/, '').gsub(/_PERP$/, '')
        end
      end
    end
  end
end
