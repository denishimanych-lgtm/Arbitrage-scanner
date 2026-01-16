# frozen_string_literal: true

module ArbitrageBot
  module Services
    module PriceFetcher
      # Bulk DEX price fetcher using DexScreener aggregator
      # Much faster than individual DEX API calls
      class DexBulkPriceFetcher
        PriceData = Struct.new(
          :symbol, :address, :price, :liquidity_usd, :volume_24h,
          :dex, :chain, :pair_address, :received_at,
          keyword_init: true
        )

        # Default minimum liquidity (can be overridden via settings)
        DEFAULT_MIN_LIQUIDITY_USD = 1000

        def initialize
          @logger = ArbitrageBot.logger
          @dexscreener = Adapters::Aggregator::DexscreenerAdapter.new
          @ticker_storage = Storage::TickerStorage.new
          @redis = ArbitrageBot.redis
        end

        # Fetch all DEX prices for tracked tokens
        # @return [Hash] { "dex:SYMBOL" => price_data }
        def fetch_all
          prices = {}
          tokens_by_chain = group_tokens_by_chain

          @logger.info("[DexBulkPriceFetcher] Fetching prices for #{tokens_by_chain.values.sum(&:size)} tokens across #{tokens_by_chain.size} chains")

          tokens_by_chain.each do |chain, tokens|
            chain_prices = fetch_chain_prices(chain, tokens)
            prices.merge!(chain_prices)
          end

          @logger.info("[DexBulkPriceFetcher] Fetched #{prices.size} valid DEX prices")
          prices
        end

        private

        # Get minimum DEX liquidity from settings (real-time from Redis)
        # @return [Integer] minimum liquidity in USD
        def min_dex_liquidity
          stored_value = @redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_dex_liquidity_usd')
          if stored_value
            stored_value.to_i
          else
            DEFAULT_MIN_LIQUIDITY_USD
          end
        rescue StandardError
          DEFAULT_MIN_LIQUIDITY_USD
        end

        # Group tracked DEX tokens by chain
        # @return [Hash] { chain => [{ symbol:, address: }, ...] }
        def group_tokens_by_chain
          tokens_by_chain = Hash.new { |h, k| h[k] = [] }

          symbols = @ticker_storage.all_symbols
          symbols.each do |symbol|
            ticker = @ticker_storage.get(symbol)
            next unless ticker

            # Get DEX venues and their contracts (handle both string and symbol keys)
            dex_venues = ticker.venues[:dex_spot] || ticker.venues['dex_spot'] || []
            dex_venues.each do |venue|
              chain = venue[:chain] || venue['chain']
              dex = venue[:dex] || venue['dex']
              contract = venue[:contract] || venue['contract'] || ticker.contracts[chain]
              next unless chain && contract

              tokens_by_chain[chain] << {
                symbol: symbol,
                address: contract,
                dex: dex
              }
            end
          end

          tokens_by_chain
        end

        # Fetch prices for all tokens on a chain
        # @param chain [String] blockchain name
        # @param tokens [Array<Hash>] tokens with symbol, address, dex
        # @return [Hash] { "dex:SYMBOL" => price_data }
        def fetch_chain_prices(chain, tokens)
          prices = {}

          # Get unique addresses
          addresses = tokens.map { |t| t[:address] }.uniq

          @logger.info("[DexBulkPriceFetcher] Fetching #{addresses.size} tokens on #{chain}")

          # Bulk fetch from DexScreener
          dexscreener_data = @dexscreener.fetch_tokens_bulk(chain, addresses)

          # Get CEX prices for cross-validation (prevents wrapped asset pricing errors)
          cex_prices = get_cex_reference_prices

          # Map results back to our format
          tokens.each do |token|
            address_lower = token[:address].downcase
            data = dexscreener_data[address_lower]
            next unless data

            # Filter by minimum liquidity (configurable via UI)
            liquidity = data[:liquidity_usd] || 0
            next if liquidity < min_dex_liquidity

            price = data[:price_usd]
            next unless price && price > 0

            symbol = token[:symbol]

            # Cross-validate DEX price with CEX price
            # Wrapped assets (like pumpBTC) can have wrong DEX pricing from DexScreener
            cex_price = cex_prices[symbol]
            if cex_price && cex_price > 0
              price_ratio = [price, cex_price].max / [price, cex_price].min
              if price_ratio > 10.0
                @logger.debug("[DexBulkPriceFetcher] Skipping #{symbol} on #{chain}: DEX $#{price.round(4)} vs CEX $#{cex_price.round(4)} (#{price_ratio.round(0)}x diff)")
                next
              end
            end

            # Use our ticker's DEX name (not DexScreener's) to match price keys
            dex = token[:dex]
            key = "#{dex}:#{symbol}"

            prices[key] = PriceData.new(
              symbol: symbol,
              address: token[:address],
              price: price,
              liquidity_usd: liquidity,
              volume_24h: data[:volume_24h],
              dex: dex,
              chain: chain,
              pair_address: data[:pair_address],
              received_at: data[:received_at]
            )
          end

          prices
        end

        # Get CEX prices for cross-validation
        # @return [Hash] { symbol => price }
        def get_cex_reference_prices
          prices_raw = @redis.get('prices:latest')
          return {} unless prices_raw

          prices = JSON.parse(prices_raw) rescue {}
          cex_prices = {}

          prices.each do |key, data|
            # Skip DEX prices
            next if key.start_with?('jupiter:', 'uniswap:', 'pancakeswap:', 'camelot:', 'traderjoe:')

            # Extract symbol from key (format: exchange:SYMBOL)
            parts = key.split(':')
            next unless parts.size == 2

            symbol = parts[1]
            price = data['bid'].to_f
            next unless price > 0

            # Keep first CEX price found for each symbol
            cex_prices[symbol] ||= price
          end

          cex_prices
        end
      end
    end
  end
end
