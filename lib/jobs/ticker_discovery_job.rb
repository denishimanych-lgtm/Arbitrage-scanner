# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class TickerDiscoveryJob
      attr_reader :logger, :storage, :validator, :pair_generator, :ticker_matcher

      def initialize
        @logger = ArbitrageBot.logger
        @storage = Storage::TickerStorage.new
        @validator = Services::TickerValidator.new
        @pair_generator = Services::ArbitragePairGenerator.new
        @ticker_matcher = Services::TickerMatcher.new
        @tickers = {}
      end

      def perform
        log('Starting ticker discovery...')

        # Step 1: Collect CEX Futures (base)
        collect_cex_futures

        # Step 2: Collect CEX Spot
        collect_cex_spot

        # Step 3: Get contract addresses
        fetch_contract_addresses

        # Step 4: Find on DEX
        find_on_dex

        # Step 5: Find on Perp DEX
        find_on_perp_dex

        # Step 6: Validate all tickers
        validate_all

        # Step 7: Generate arbitrage pairs
        generate_pairs

        # Step 8: Save to Redis
        save_all

        # Log match statistics
        match_stats = @ticker_matcher.batch_analyze(@tickers)
        log("Match quality: excellent=#{match_stats[:excellent]}, good=#{match_stats[:good]}, fair=#{match_stats[:fair]}, poor=#{match_stats[:poor]}")
        log("Ticker discovery complete. Valid tickers: #{@tickers.count { |_, t| t.is_valid }}")

        # Return statistics for orchestrator
        {
          symbols_count: @tickers.size,
          valid_count: @tickers.count { |_, t| t.is_valid },
          pairs_count: @tickers.values.sum { |t| t.arbitrage_pairs&.size || 0 },
          match_stats: match_stats
        }
      end

      private

      def log(message)
        @logger.info("[TickerDiscovery] #{message}")
        puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
      end

      # Step 1: Collect CEX Futures
      def collect_cex_futures
        log('Collecting CEX futures symbols...')

        Services::AdapterFactory::Cex.all.each do |exchange, adapter|
          begin
            symbols = adapter.futures_symbols

            symbols.each do |sym|
              base_asset = sym[:base_asset].upcase

              @tickers[base_asset] ||= Models::Ticker.new(symbol: base_asset)
              @tickers[base_asset].add_cex_futures(
                exchange: exchange,
                symbol: sym[:symbol],
                status: sym[:status]
              )
            end

            log("  #{exchange}: #{symbols.size} futures")
          rescue StandardError => e
            log("  #{exchange}: ERROR - #{e.message}")
          end
        end

        log("Total unique symbols from futures: #{@tickers.size}")
      end

      # Step 2: Collect CEX Spot (using TickerMatcher)
      def collect_cex_spot
        log('Collecting CEX spot symbols...')

        Services::AdapterFactory::Cex.all.each do |exchange, adapter|
          begin
            symbols = adapter.spot_symbols

            # Use TickerMatcher for matching
            result = @ticker_matcher.match_cex_spot(@tickers, symbols, exchange)

            log("  #{exchange}: #{result[:matched]} spot matched to futures")
          rescue StandardError => e
            log("  #{exchange}: ERROR - #{e.message}")
          end
        end
      end

      # Step 3: Fetch contract addresses
      def fetch_contract_addresses
        if ENV['SKIP_CONTRACT_FETCH']
          log('Contract fetching skipped (SKIP_CONTRACT_FETCH=1)')
          return
        end

        log('Fetching contract addresses...')

        fetcher = Services::ContractFetcher.new

        unless fetcher.configured?
          log('No API keys for contract fetching (COINGECKO_API_KEY or COINMARKETCAP_API_KEY)')
          log('Skipping contract addresses - DEX lookup will be unavailable')
          return
        end

        # Fetch contracts for all symbols
        symbols = @tickers.keys
        contracts = fetcher.fetch_batch(symbols)

        # Add contracts to tickers
        contracts.each do |symbol, chains|
          next unless @tickers[symbol]

          chains.each do |chain, address|
            @tickers[symbol].add_contract(chain: chain, address: address)
          end
        end

        with_contracts = @tickers.count { |_, t| t.contracts.any? }
        log("Fetched contracts for #{with_contracts} symbols")
      end

      # Step 4: Add DEX spots from contract addresses
      # We already have contract addresses from CoinGecko/CMC
      # No need to verify via DEX API - just add them directly
      # Price fetching will validate if they actually have liquidity
      def find_on_dex
        if ENV['SKIP_DEX_SEARCH']
          log('DEX search skipped (SKIP_DEX_SEARCH=1)')
          return
        end

        log('Adding DEX spots from contract addresses...')

        added_count = 0
        chains_count = Hash.new(0)

        @tickers.each do |symbol, ticker|
          ticker.contracts.each do |chain, address|
            next unless address && !address.empty?

            # Find DEXes for this chain
            chain_dexes = Services::AdapterFactory::Dex::CHAINS[chain] || []
            next if chain_dexes.empty?

            # Add DEX spot for the primary DEX of this chain
            primary_dex = chain_dexes.first

            ticker.add_dex_spot(
              dex: primary_dex,
              chain: chain,
              contract: address,
              pool_address: nil, # Will be resolved during price fetch
              has_liquidity: true # Assume yes, price fetch will validate
            )

            added_count += 1
            chains_count[chain] += 1
          end
        end

        log("Added #{added_count} DEX spots from contracts")
        chains_count.each do |chain, count|
          log("  #{chain}: #{count}")
        end
      end

      # Step 5: Find on Perp DEX (using TickerMatcher)
      def find_on_perp_dex
        log('Searching on Perp DEX...')

        Services::AdapterFactory::PerpDex.all.each do |dex_name, adapter|
          begin
            markets = adapter.markets

            # Use TickerMatcher for matching
            result = @ticker_matcher.match_perp_dex(@tickers, markets, dex_name)

            log("  #{dex_name}: #{result[:matched]} matched")
          rescue StandardError => e
            log("  #{dex_name}: ERROR - #{e.message}")
          end
        end
      end

      # Step 6: Validate all tickers
      def validate_all
        log('Validating tickers...')

        valid_count = 0
        invalid_count = 0

        @tickers.each do |_, ticker|
          result = @validator.validate(ticker)

          ticker.is_valid = result.valid
          ticker.validation_errors = result.errors

          if result.valid
            valid_count += 1
          else
            invalid_count += 1
          end
        end

        log("Validation: #{valid_count} valid, #{invalid_count} invalid")
      end

      # Step 7: Generate arbitrage pairs
      def generate_pairs
        log('Generating arbitrage pairs...')

        total_pairs = 0
        auto_pairs = 0
        manual_pairs = 0

        @tickers.each do |_, ticker|
          next unless ticker.is_valid

          pairs = @pair_generator.generate(ticker)
          ticker.arbitrage_pairs = pairs.map(&:to_h)

          total_pairs += pairs.size
          auto_pairs += pairs.count { |p| p.type == :auto }
          manual_pairs += pairs.count { |p| p.type == :manual }
        end

        log("Generated #{total_pairs} pairs (#{auto_pairs} auto, #{manual_pairs} manual)")
      end

      # Step 8: Save to Redis
      def save_all
        log('Saving to Redis...')

        valid_tickers = @tickers.values.select(&:is_valid)
        @storage.save_all(valid_tickers)

        log("Saved #{valid_tickers.size} tickers to Redis")
      end
    end
  end
end
