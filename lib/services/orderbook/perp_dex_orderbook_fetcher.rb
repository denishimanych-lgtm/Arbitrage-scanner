# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Orderbook
      class PerpDexOrderbookFetcher
        DEFAULT_DEPTH = 20

        OrderbookData = Struct.new(
          :symbol, :dex, :bids, :asks, :timestamp, :timing, :type,
          keyword_init: true
        )

        TimingInfo = Struct.new(
          :request_at, :response_at, :latency_ms,
          keyword_init: true
        )

        def initialize
          @adapters = {}
        end

        # Fetch orderbook
        def fetch(dex, symbol, depth: DEFAULT_DEPTH)
          adapter = get_adapter(dex)

          request_at = Time.now
          response = adapter.orderbook(symbol, depth: depth)
          response_at = Time.now

          return nil unless response

          latency_ms = ((response_at - request_at) * 1000).round

          OrderbookData.new(
            symbol: symbol,
            dex: dex,
            bids: response[:bids] || [],
            asks: response[:asks] || [],
            timestamp: response[:timestamp],
            timing: TimingInfo.new(
              request_at: request_at.to_f,
              response_at: response_at.to_f,
              latency_ms: latency_ms
            ),
            type: response[:type] || :standard
          )
        end

        # Fetch orderbooks from multiple DEXes in parallel
        def fetch_parallel(requests)
          results = {}
          threads = []

          requests.each do |req|
            dex = req[:dex]
            symbol = req[:symbol]
            depth = req[:depth] || DEFAULT_DEPTH

            threads << Thread.new do
              begin
                orderbook = fetch(dex, symbol, depth: depth)
                Thread.current[:result] = { "#{dex}:#{symbol}" => orderbook }
              rescue StandardError => e
                ArbitrageBot.logger.error("PerpDEX orderbook error #{dex}/#{symbol}: #{e.message}")
                Thread.current[:result] = { "#{dex}:#{symbol}" => nil }
              end
            end
          end

          threads.each do |t|
            t.join
            results.merge!(t[:result]) if t[:result]
          end

          results
        end

        # Get best prices from orderbook
        def best_prices(orderbook)
          return nil unless orderbook&.bids&.any? && orderbook&.asks&.any?

          {
            best_bid: orderbook.bids.first[0],
            best_ask: orderbook.asks.first[0],
            bid_qty: orderbook.bids.first[1],
            ask_qty: orderbook.asks.first[1],
            spread_pct: calculate_spread_pct(orderbook.bids.first[0], orderbook.asks.first[0])
          }
        end

        private

        def get_adapter(dex)
          @adapters[dex] ||= AdapterFactory::PerpDex.get(dex)
        end

        def calculate_spread_pct(bid, ask)
          return BigDecimal('0') if bid.zero?

          ((ask - bid) / bid * 100).round(4)
        end
      end
    end
  end
end
