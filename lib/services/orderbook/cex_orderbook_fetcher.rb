# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Orderbook
      class CexOrderbookFetcher
        DEFAULT_DEPTH = 20

        OrderbookData = Struct.new(
          :symbol, :exchange, :bids, :asks, :exchange_ts, :timing,
          keyword_init: true
        )

        TimingInfo = Struct.new(
          :request_at, :response_at, :latency_ms,
          keyword_init: true
        )

        def initialize
          @adapters = {}
        end

        # Fetch orderbook for a symbol
        def fetch(exchange, symbol, depth: DEFAULT_DEPTH, market_type: nil)
          adapter = get_adapter(exchange)

          request_at = Time.now
          response = adapter.orderbook(symbol, depth: depth, market_type: market_type)
          response_at = Time.now

          latency_ms = ((response_at - request_at) * 1000).round

          OrderbookData.new(
            symbol: symbol,
            exchange: exchange,
            bids: response[:bids],
            asks: response[:asks],
            exchange_ts: response[:timestamp],
            timing: TimingInfo.new(
              request_at: request_at.to_f,
              response_at: response_at.to_f,
              latency_ms: latency_ms
            )
          )
        end

        # Fetch orderbooks from multiple exchanges in parallel
        def fetch_parallel(requests)
          results = {}
          threads = []

          requests.each do |req|
            exchange = req[:exchange]
            symbol = req[:symbol]
            depth = req[:depth] || DEFAULT_DEPTH

            threads << Thread.new do
              begin
                orderbook = fetch(exchange, symbol, depth: depth)
                Thread.current[:result] = { "#{exchange}:#{symbol}" => orderbook }
              rescue StandardError => e
                ArbitrageBot.logger.error("Orderbook fetch error #{exchange}/#{symbol}: #{e.message}")
                Thread.current[:result] = { "#{exchange}:#{symbol}" => nil }
              end
            end
          end

          threads.each do |t|
            t.join
            results.merge!(t[:result]) if t[:result]
          end

          results
        end

        # Get best bid/ask from orderbook
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

        def get_adapter(exchange)
          @adapters[exchange] ||= AdapterFactory::Cex.get(exchange)
        end

        def calculate_spread_pct(bid, ask)
          return BigDecimal('0') if bid.zero?

          ((ask - bid) / bid * 100).round(4)
        end
      end
    end
  end
end
