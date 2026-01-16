# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Removes arbitrage pairs that don't have price data available
    # Run this after price collection to clean up unmatchable pairs
    class PairCleanupJob
      def initialize
        @logger = ArbitrageBot.logger
        @ticker_storage = Storage::TickerStorage.new
      end

      def perform
        log('Starting pair cleanup...')

        prices_json = ArbitrageBot.redis.get('prices:latest')
        unless prices_json
          log('No prices cache found, skipping cleanup')
          return
        end

        prices = JSON.parse(prices_json)
        price_keys = prices.keys.to_set

        total_pairs = 0
        removed_pairs = 0
        updated_tickers = 0

        symbols = @ticker_storage.all_symbols
        symbols.each do |symbol|
          ticker = @ticker_storage.get(symbol)
          next unless ticker

          pairs = ticker.arbitrage_pairs || []
          total_pairs += pairs.size

          # Filter to only pairs with both prices available
          valid_pairs = pairs.select do |pair|
            low_key = venue_price_key(pair['low_venue'] || pair[:low_venue], symbol)
            high_key = venue_price_key(pair['high_venue'] || pair[:high_venue], symbol)
            price_keys.include?(low_key) && price_keys.include?(high_key)
          end

          removed = pairs.size - valid_pairs.size
          if removed > 0
            removed_pairs += removed
            ticker.arbitrage_pairs = valid_pairs
            @ticker_storage.save(ticker)
            updated_tickers += 1
          end
        end

        log("Cleanup complete: #{removed_pairs} pairs removed from #{updated_tickers} tickers")
        log("Remaining pairs: #{total_pairs - removed_pairs}")

        { total: total_pairs, removed: removed_pairs, remaining: total_pairs - removed_pairs }
      end

      private

      def log(message)
        @logger.info("[PairCleanup] #{message}")
        puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
      end

      def venue_price_key(venue, fallback_symbol)
        type = (venue['type'] || venue[:type]).to_s
        exchange = venue['exchange'] || venue[:exchange]
        dex = venue['dex'] || venue[:dex]
        symbol = venue['symbol'] || venue[:symbol] || fallback_symbol

        base = extract_base_symbol(symbol || '')

        case type
        when 'cex_futures' then "#{exchange}_futures:#{base}"
        when 'cex_spot' then "#{exchange}_spot:#{base}"
        when 'perp_dex' then "#{dex}:#{base}"
        when 'dex_spot' then "#{dex}:#{base}"
        else "unknown:#{base}"
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
