# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class TickerDiscoveryJob
      attr_reader :logger, :storage, :validator, :pair_generator

      def initialize
        @logger = ArbitrageBot.logger
        @storage = Storage::TickerStorage.new
        @validator = Services::TickerValidator.new
        @pair_generator = Services::ArbitragePairGenerator.new
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

        log("Ticker discovery complete. Valid tickers: #{@tickers.count { |_, t| t.is_valid }}")
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

      # Step 2: Collect CEX Spot
      def collect_cex_spot
        log('Collecting CEX spot symbols...')

        Services::AdapterFactory::Cex.all.each do |exchange, adapter|
          begin
            symbols = adapter.spot_symbols
            matched = 0

            symbols.each do |sym|
              base_asset = sym[:base_asset].upcase

              # Only add if we have futures for this symbol
              next unless @tickers[base_asset]

              @tickers[base_asset].add_cex_spot(
                exchange: exchange,
                symbol: sym[:symbol]
              )
              matched += 1
            end

            log("  #{exchange}: #{matched} spot matched to futures")
          rescue StandardError => e
            log("  #{exchange}: ERROR - #{e.message}")
          end
        end
      end

      # Step 3: Fetch contract addresses
      def fetch_contract_addresses
        log('Fetching contract addresses...')

        # Use one exchange (Binance preferred) to get contract addresses
        adapter = Services::AdapterFactory::Cex.get('binance')

        @tickers.each do |symbol, ticker|
          begin
            details = adapter.asset_details(symbol)
            next unless details

            details[:networks]&.each do |network|
              next unless network[:contract]

              ticker.add_contract(
                chain: network[:chain],
                address: network[:contract]
              )
            end
          rescue StandardError => e
            # Log only at debug level - many assets won't have contract info
            @logger.debug("Contract fetch error for #{symbol}: #{e.message}")
          end
        end

        with_contracts = @tickers.count { |_, t| t.contracts.any? }
        log("Fetched contracts for #{with_contracts} symbols")
      end

      # Step 4: Find on DEX
      def find_on_dex
        log('Searching for tokens on DEX...')

        dex_adapters = Services::AdapterFactory::Dex.all
        found_count = 0

        @tickers.each do |symbol, ticker|
          ticker.contracts.each do |chain, address|
            next unless address

            # Find DEXes for this chain
            chain_dexes = Services::AdapterFactory::Dex::CHAINS[chain] || []

            chain_dexes.each do |dex_name|
              begin
                adapter = dex_adapters[dex_name]
                next unless adapter

                result = adapter.find_token(address)
                next unless result && result[:found]

                ticker.add_dex_spot(
                  dex: dex_name,
                  chain: chain,
                  pool_address: result[:pool_address],
                  has_liquidity: result[:has_liquidity] || result[:liquidity_usd].to_f > 1000,
                  liquidity_usd: result[:liquidity_usd]
                )
                found_count += 1
              rescue StandardError => e
                @logger.debug("DEX search error #{dex_name}/#{symbol}: #{e.message}")
              end
            end
          end
        end

        log("Found #{found_count} DEX pools")
      end

      # Step 5: Find on Perp DEX
      def find_on_perp_dex
        log('Searching on Perp DEX...')

        Services::AdapterFactory::PerpDex.all.each do |dex_name, adapter|
          begin
            markets = adapter.markets
            matched = 0

            markets.each do |market|
              base_asset = market[:base_asset]&.upcase || market[:symbol]&.upcase&.gsub(/USDT?$|USD$/, '')

              next unless @tickers[base_asset]

              @tickers[base_asset].add_perp_dex(
                dex: dex_name,
                symbol: market[:symbol],
                status: market[:status]
              )
              matched += 1
            end

            log("  #{dex_name}: #{matched} matched")
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
