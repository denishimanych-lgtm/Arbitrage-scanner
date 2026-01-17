# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Orderbook
      class PerpDexOrderbookFetcher
        DEFAULT_DEPTH = 20
        CACHE_TTL = 60 # seconds - orderbook cache validity
        CACHE_KEY_PREFIX = 'orderbook:dex:cache:'

        OrderbookData = Struct.new(
          :symbol, :dex, :bids, :asks, :timestamp, :timing, :type, :cached,
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

        # Fetch orderbook with caching and fallback
        def fetch(dex, symbol, depth: DEFAULT_DEPTH)
          cache_key = "#{CACHE_KEY_PREFIX}#{dex}:#{symbol}"
          adapter = get_adapter(dex)

          begin
            request_at = Time.now
            response = adapter.orderbook(symbol, depth: depth)
            response_at = Time.now

            return nil unless response

            latency_ms = ((response_at - request_at) * 1000).round

            orderbook = OrderbookData.new(
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
              type: response[:type] || :standard,
              cached: false
            )

            # Cache successful response
            cache_orderbook(cache_key, orderbook)

            orderbook
          rescue StandardError => e
            @logger.warn("[PerpDexOrderbookFetcher] Fetch failed #{dex}/#{symbol}: #{e.message}, trying cache")

            # Try cached data on failure
            cached = get_cached_orderbook(cache_key, dex, symbol)
            if cached
              @logger.info("[PerpDexOrderbookFetcher] Using cached orderbook for #{dex}/#{symbol}")
              cached
            else
              nil # DEX orderbooks return nil on failure instead of raising
            end
          end
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

        def cache_orderbook(key, orderbook)
          data = {
            symbol: orderbook.symbol,
            dex: orderbook.dex,
            bids: orderbook.bids.map { |b| [b[0].to_s, b[1].to_s] },
            asks: orderbook.asks.map { |a| [a[0].to_s, a[1].to_s] },
            timestamp: orderbook.timestamp,
            type: orderbook.type.to_s,
            cached_at: Time.now.to_i
          }
          @redis.setex(key, CACHE_TTL, JSON.generate(data))
        rescue StandardError => e
          @logger.debug("[PerpDexOrderbookFetcher] Cache write failed: #{e.message}")
        end

        def get_cached_orderbook(key, dex, symbol)
          raw = @redis.get(key)
          return nil unless raw

          data = JSON.parse(raw)

          # Check if cache is still fresh enough (within 2x TTL for fallback)
          cached_at = data['cached_at'].to_i
          return nil if Time.now.to_i - cached_at > CACHE_TTL * 2

          OrderbookData.new(
            symbol: symbol,
            dex: dex,
            bids: data['bids'].map { |b| [BigDecimal(b[0]), BigDecimal(b[1])] },
            asks: data['asks'].map { |a| [BigDecimal(a[0]), BigDecimal(a[1])] },
            timestamp: data['timestamp'],
            timing: TimingInfo.new(
              request_at: cached_at.to_f,
              response_at: cached_at.to_f,
              latency_ms: 0
            ),
            type: data['type']&.to_sym || :standard,
            cached: true
          )
        rescue StandardError => e
          @logger.debug("[PerpDexOrderbookFetcher] Cache read failed: #{e.message}")
          nil
        end
      end
    end
  end
end
