# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class PriceMonitorJob
      PRICE_CACHE_KEY = 'prices:latest'
      SPREAD_CACHE_KEY = 'spreads:latest'
      PRICE_TTL = 10 # seconds

      attr_reader :logger, :redis

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @redis = ArbitrageBot.redis
        @settings = settings
        @min_spread_pct = settings[:min_spread_pct] || 1.0

        @cex_fetcher = Services::PriceFetcher::CexPriceFetcher.new
        @dex_fetcher = Services::PriceFetcher::DexPriceFetcher.new
        @perp_dex_fetcher = Services::PriceFetcher::PerpDexPriceFetcher.new
        @ticker_storage = Storage::TickerStorage.new
      end

      # Run single price collection cycle
      def perform
        log('Starting price collection...')
        start_time = Time.now

        # Get all tracked symbols
        symbols = @ticker_storage.all_symbols

        return if symbols.empty?

        # Fetch prices from all sources in parallel
        all_prices = fetch_all_prices(symbols)

        # Cache prices
        cache_prices(all_prices)

        # Calculate spreads for all arbitrage pairs
        spreads = calculate_spreads(symbols, all_prices)

        # Cache spreads
        cache_spreads(spreads)

        # Trigger orderbook analysis for high spreads
        trigger_analysis(spreads)

        elapsed = ((Time.now - start_time) * 1000).round
        log("Price collection complete: #{all_prices.size} prices, #{spreads.size} spreads (#{elapsed}ms)")
      end

      # Run continuous monitoring loop
      def run_loop(interval: 1)
        log("Starting price monitor loop (interval: #{interval}s)")

        loop do
          begin
            perform
          rescue StandardError => e
            @logger.error("Price monitor error: #{e.message}")
          end

          sleep interval
        end
      end

      private

      def log(message)
        @logger.info("[PriceMonitor] #{message}")
      end

      def fetch_all_prices(symbols)
        prices = {}

        # Fetch CEX prices
        begin
          cex_prices = @cex_fetcher.fetch_all_exchanges
          cex_prices.each do |exchange, exchange_prices|
            exchange_prices.each do |symbol, data|
              base = extract_base_symbol(symbol)
              prices["#{exchange}:#{base}"] = data
            end
          end
        rescue StandardError => e
          @logger.error("CEX price fetch error: #{e.message}")
        end

        # Fetch DEX prices for tokens with contracts
        begin
          fetch_dex_prices(symbols, prices)
        rescue StandardError => e
          @logger.error("DEX price fetch error: #{e.message}")
        end

        # Fetch Perp DEX prices
        begin
          perp_prices = @perp_dex_fetcher.fetch_all_dexes
          perp_prices.each do |dex, dex_prices|
            dex_prices.each do |symbol, data|
              base = extract_base_symbol(symbol)
              prices["#{dex}:#{base}"] = data
            end
          end
        rescue StandardError => e
          @logger.error("PerpDEX price fetch error: #{e.message}")
        end

        prices
      end

      def fetch_dex_prices(symbols, prices)
        symbols.each do |symbol|
          ticker = @ticker_storage.get(symbol)
          next unless ticker

          # Skip if no DEX venues
          dex_venues = ticker.venues[:dex_spot] || []
          next if dex_venues.empty?

          dex_venues.each do |venue|
            dex = venue[:dex]
            chain = venue[:chain]
            token_address = ticker.contracts[chain]

            next unless token_address

            begin
              price_data = @dex_fetcher.fetch(dex, token_address)
              next unless price_data

              base = symbol.upcase
              prices["#{dex}:#{base}"] = {
                bid: price_data.price,
                ask: price_data.price,
                last: price_data.price,
                price_impact_pct: price_data.price_impact_pct,
                received_at: price_data.received_at
              }
            rescue StandardError => e
              @logger.debug("DEX price fetch error for #{symbol}/#{dex}: #{e.message}")
            end
          end
        end
      end

      def cache_prices(prices)
        return if prices.empty?

        serialized = prices.transform_values do |data|
          if data.respond_to?(:to_h)
            data.to_h.transform_values(&:to_s)
          else
            data.transform_values(&:to_s)
          end
        end

        @redis.set(PRICE_CACHE_KEY, serialized.to_json)
        @redis.expire(PRICE_CACHE_KEY, PRICE_TTL)
      end

      def calculate_spreads(symbols, all_prices)
        spreads = []

        symbols.each do |symbol|
          ticker = @ticker_storage.get(symbol)
          next unless ticker

          ticker.arbitrage_pairs.each do |pair|
            spread = calculate_pair_spread(pair, all_prices)
            spreads << spread if spread
          end
        end

        spreads
      end

      def calculate_pair_spread(pair, all_prices)
        low_venue = pair[:low_venue] || pair['low_venue']
        high_venue = pair[:high_venue] || pair['high_venue']

        low_key = venue_price_key(low_venue)
        high_key = venue_price_key(high_venue)

        low_price = all_prices[low_key]
        high_price = all_prices[high_key]

        return nil unless low_price && high_price

        # Get ask from low venue (buy price) and bid from high venue (sell price)
        buy_price = low_price.respond_to?(:ask) ? low_price.ask : low_price[:ask]
        sell_price = high_price.respond_to?(:bid) ? high_price.bid : high_price[:bid]

        return nil unless buy_price && sell_price && buy_price > 0

        spread_pct = ((sell_price.to_f - buy_price.to_f) / buy_price.to_f * 100).round(4)

        {
          pair_id: pair[:id] || pair['id'],
          symbol: pair[:symbol] || pair['symbol'],
          low_venue: low_venue,
          high_venue: high_venue,
          buy_price: buy_price.to_f,
          sell_price: sell_price.to_f,
          spread_pct: spread_pct,
          timestamp: Time.now.to_i
        }
      end

      def cache_spreads(spreads)
        return if spreads.empty?

        @redis.set(SPREAD_CACHE_KEY, spreads.to_json)
        @redis.expire(SPREAD_CACHE_KEY, PRICE_TTL)
      end

      def trigger_analysis(spreads)
        high_spreads = spreads.select { |s| s[:spread_pct].abs >= @min_spread_pct }

        high_spreads.each do |spread|
          @redis.lpush('queue:orderbook_analysis', spread.to_json)
          @redis.ltrim('queue:orderbook_analysis', 0, 999) # Keep max 1000 pending
        end

        log("Triggered analysis for #{high_spreads.size} high spreads") if high_spreads.any?
      end

      def venue_price_key(venue)
        type = venue[:type] || venue['type']
        exchange = venue[:exchange] || venue['exchange']
        dex = venue[:dex] || venue['dex']
        symbol = venue[:symbol] || venue['symbol']

        base = extract_base_symbol(symbol || '')

        case type.to_sym
        when :cex_futures, :cex_spot
          "#{exchange}:#{base}"
        when :perp_dex
          "#{dex}:#{base}"
        when :dex_spot
          "#{dex}:#{base}"
        else
          "unknown:#{base}"
        end
      end

      def extract_base_symbol(symbol)
        symbol.to_s.upcase
          .gsub(/USDT$|USDC$|USD$|BUSD$/, '')
          .gsub(/[-_]/, '')
          .gsub(/PERP$/, '')
      end
    end
  end
end
