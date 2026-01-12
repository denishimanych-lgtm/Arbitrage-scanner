# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Stablecoin
      # Monitors stablecoin prices for depegging events
      class DepegMonitor
        # Stablecoins to monitor
        STABLECOINS = %w[USDT USDC DAI FRAX TUSD BUSD].freeze

        # Price sources (priority order)
        SOURCES = {
          binance: 'https://api.binance.com/api/v3/ticker/price',
          coingecko: 'https://api.coingecko.com/api/v3/simple/price'
        }.freeze

        # Coingecko IDs for stablecoins
        COINGECKO_IDS = {
          'USDT' => 'tether',
          'USDC' => 'usd-coin',
          'DAI' => 'dai',
          'FRAX' => 'frax',
          'TUSD' => 'true-usd',
          'BUSD' => 'binance-usd'
        }.freeze

        REDIS_KEY = 'stablecoin:prices'

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Fetch all stablecoin prices
        # @return [Array<Hash>] price data for each stablecoin
        def fetch_all
          prices = []

          STABLECOINS.each do |symbol|
            price_data = fetch_price(symbol)
            prices << price_data if price_data
          end

          # Cache in Redis
          store_prices(prices)

          prices
        end

        # Get current prices from cache
        # @return [Array<Hash>]
        def current_prices
          data = ArbitrageBot.redis.get(REDIS_KEY)
          return [] unless data

          JSON.parse(data, symbolize_names: true)
        rescue StandardError
          []
        end

        # Fetch price for a specific stablecoin
        # @param symbol [String] stablecoin symbol
        # @return [Hash, nil]
        def fetch_price(symbol)
          # Try Binance first (more accurate for trading pairs)
          price = fetch_from_binance(symbol)
          source = 'binance'

          # Fallback to CoinGecko
          unless price
            price = fetch_from_coingecko(symbol)
            source = 'coingecko'
          end

          return nil unless price

          deviation = ((price - 1.0) * 100).round(4)

          {
            symbol: symbol,
            price: price,
            deviation_pct: deviation,
            source: source,
            status: classify_status(price),
            fetched_at: Time.now
          }
        rescue StandardError => e
          @logger.error("[DepegMonitor] fetch_price error for #{symbol}: #{e.message}")
          nil
        end

        # Check for depeg condition
        # @param price [Float] current price
        # @return [Boolean]
        def depegged?(price)
          price < 0.99 || price > 1.01
        end

        # Check for severe depeg
        # @param price [Float] current price
        # @return [Boolean]
        def severe_depeg?(price)
          price < 0.97 || price > 1.03
        end

        private

        def fetch_from_binance(symbol)
          # Use USDT pairs for other stables, or BUSD for USDT
          quote = symbol == 'USDT' ? 'BUSD' : 'USDT'
          pair = "#{symbol}#{quote}"

          uri = URI("https://api.binance.com/api/v3/ticker/price?symbol=#{pair}")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 5

          response = http.get(uri.request_uri)
          return nil unless response.code == '200'

          data = JSON.parse(response.body)
          price = data['price'].to_f

          # If using BUSD quote, the price is already in USD terms
          # If using USDT quote, need to consider USDT might be depegged too
          price
        rescue StandardError => e
          @logger.debug("[DepegMonitor] Binance error for #{symbol}: #{e.message}")
          nil
        end

        def fetch_from_coingecko(symbol)
          coin_id = COINGECKO_IDS[symbol]
          return nil unless coin_id

          uri = URI("https://api.coingecko.com/api/v3/simple/price?ids=#{coin_id}&vs_currencies=usd")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 10

          response = http.get(uri.request_uri)
          return nil unless response.code == '200'

          data = JSON.parse(response.body)
          data.dig(coin_id, 'usd')&.to_f
        rescue StandardError => e
          @logger.debug("[DepegMonitor] CoinGecko error for #{symbol}: #{e.message}")
          nil
        end

        def classify_status(price)
          if price >= 0.995 && price <= 1.005
            :stable
          elsif price >= 0.99 && price <= 1.01
            :minor_deviation
          elsif price >= 0.97 && price <= 1.03
            :depegged
          else
            :severe_depeg
          end
        end

        def store_prices(prices)
          data = prices.map do |p|
            p.transform_values { |v| v.is_a?(Time) ? v.to_i : v }
          end

          # Cache for 2 minutes
          ArbitrageBot.redis.setex(REDIS_KEY, 120, data.to_json)
        end
      end
    end
  end
end
