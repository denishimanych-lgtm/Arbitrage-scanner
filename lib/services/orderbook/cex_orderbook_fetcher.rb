# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Orderbook
      class CexOrderbookFetcher
        DEFAULT_DEPTH = 20
        CACHE_TTL = 60 # seconds - orderbook cache validity
        CACHE_KEY_PREFIX = 'orderbook:cache:'

        OrderbookData = Struct.new(
          :symbol, :exchange, :bids, :asks, :exchange_ts, :timing, :cached,
          keyword_init: true
        )

        TimingInfo = Struct.new(
          :request_at, :response_at, :latency_ms,
          keyword_init: true
        )

        def initialize
          @adapters = {}
          @redis = ArbitrageBot.redis
          @logger = ArbitrageBot.logger
        end

        # Fetch orderbook for a symbol with caching and fallback
        def fetch(exchange, symbol, depth: DEFAULT_DEPTH, market_type: nil)
          cache_key = "#{CACHE_KEY_PREFIX}#{exchange}:#{symbol}"
          adapter = get_adapter(exchange)

          begin
            request_at = Time.now
            response = adapter.orderbook(symbol, depth: depth, market_type: market_type)
            response_at = Time.now

            latency_ms = ((response_at - request_at) * 1000).round

            orderbook = OrderbookData.new(
              symbol: symbol,
              exchange: exchange,
              bids: response[:bids],
              asks: response[:asks],
              exchange_ts: response[:timestamp],
              timing: TimingInfo.new(
                request_at: request_at.to_f,
                response_at: response_at.to_f,
                latency_ms: latency_ms
              ),
              cached: false
            )

            # Cache the successful response
            cache_orderbook(cache_key, orderbook)

            orderbook
          rescue StandardError => e
            @logger.warn("[CexOrderbookFetcher] Fetch failed #{exchange}/#{symbol}: #{e.message}, trying cache")

            # Try to return cached data on failure
            cached = get_cached_orderbook(cache_key, exchange, symbol)
            if cached
              @logger.info("[CexOrderbookFetcher] Using cached orderbook for #{exchange}/#{symbol}")
              cached
            else
              raise e # Re-raise if no cache available
            end
          end
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

        def cache_orderbook(key, orderbook)
          data = {
            symbol: orderbook.symbol,
            exchange: orderbook.exchange,
            bids: orderbook.bids.map { |b| [b[0].to_s('F'), b[1].to_s('F')] },
            asks: orderbook.asks.map { |a| [a[0].to_s('F'), a[1].to_s('F')] },
            exchange_ts: orderbook.exchange_ts,
            cached_at: Time.now.to_i
          }
          @redis.setex(key, CACHE_TTL, JSON.generate(data))
        rescue StandardError => e
          @logger.debug("[CexOrderbookFetcher] Cache write failed: #{e.message}")
        end

        def get_cached_orderbook(key, exchange, symbol)
          raw = @redis.get(key)
          return nil unless raw

          data = JSON.parse(raw)

          # Check if cache is still fresh enough (within 2x TTL for fallback)
          cached_at = data['cached_at'].to_i
          return nil if Time.now.to_i - cached_at > CACHE_TTL * 2

          OrderbookData.new(
            symbol: symbol,
            exchange: exchange,
            bids: data['bids'].map { |b| [BigDecimal(b[0]), BigDecimal(b[1])] },
            asks: data['asks'].map { |a| [BigDecimal(a[0]), BigDecimal(a[1])] },
            exchange_ts: data['exchange_ts'],
            timing: TimingInfo.new(
              request_at: cached_at.to_f,
              response_at: cached_at.to_f,
              latency_ms: 0
            ),
            cached: true
          )
        rescue StandardError => e
          @logger.debug("[CexOrderbookFetcher] Cache read failed: #{e.message}")
          nil
        end
      end
    end
  end
end
