# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Calculates price ratios between pairs of assets
      class RatioCalculator
        REDIS_PRICES_KEY = 'prices:current'

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Calculate ratio for a specific pair
        # @param base [String] base symbol (e.g., 'BTC')
        # @param quote [String] quote symbol (e.g., 'ETH')
        # @return [Hash, nil] ratio data or nil if prices unavailable
        def calculate(base, quote)
          base_price = get_price(base)
          quote_price = get_price(quote)

          return nil unless base_price && quote_price && quote_price > 0

          ratio = base_price / quote_price

          {
            pair: "#{base}/#{quote}",
            base: base,
            quote: quote,
            base_price: base_price,
            quote_price: quote_price,
            ratio: ratio,
            calculated_at: Time.now
          }
        end

        # Calculate ratios for all configured pairs
        # @return [Array<Hash>] array of ratio data
        def calculate_all
          PairsConfig.pairs.filter_map do |base, quote, _desc|
            calculate(base, quote)
          end
        end

        # Get current ratio for display
        # @param pair_str [String] pair string like 'BTC/ETH'
        # @return [Hash, nil]
        def ratio_for_pair(pair_str)
          pair = PairsConfig.find_pair(pair_str)
          return nil unless pair

          calculate(pair[0], pair[1])
        end

        private

        def get_price(symbol)
          # Try to get price from Redis (stored by PriceMonitorJob)
          price = get_price_from_redis(symbol)
          return price if price

          # Fallback: fetch directly
          fetch_price_direct(symbol)
        end

        def get_price_from_redis(symbol)
          redis = ArbitrageBot.redis

          # Check for direct symbol price
          key = "price:#{symbol}:usd"
          price = redis.get(key)
          return price.to_f if price

          # Check in current prices hash
          prices_json = redis.get(REDIS_PRICES_KEY)
          return nil unless prices_json

          prices = JSON.parse(prices_json, symbolize_names: true)

          # Try different symbol formats
          [symbol, "#{symbol}USDT", "#{symbol}USD", "#{symbol}/USDT"].each do |sym|
            return prices[sym.to_sym].to_f if prices[sym.to_sym]
          end

          nil
        rescue StandardError => e
          @logger.debug("[RatioCalculator] Redis price fetch error: #{e.message}")
          nil
        end

        def fetch_price_direct(symbol)
          # Use Binance as primary source
          fetch_from_binance(symbol)
        rescue StandardError => e
          @logger.debug("[RatioCalculator] Direct price fetch error for #{symbol}: #{e.message}")
          nil
        end

        def fetch_from_binance(symbol)
          uri = URI("https://api.binance.com/api/v3/ticker/price?symbol=#{symbol}USDT")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 5

          response = http.get(uri.request_uri)
          return nil unless response.code == '200'

          data = JSON.parse(response.body)
          data['price'].to_f
        rescue StandardError
          nil
        end
      end
    end
  end
end
