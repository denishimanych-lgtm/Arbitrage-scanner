# frozen_string_literal: true

module ArbitrageBot
  module Storage
    class TickerStorage
      # Redis key patterns
      MASTER_KEY = 'tickers:master:%s'
      BY_EXCHANGE_FUTURES_KEY = 'tickers:by_exchange:%s:futures'
      BY_EXCHANGE_SPOT_KEY = 'tickers:by_exchange:%s:spot'
      BY_DEX_KEY = 'tickers:by_dex:%s'
      BY_PERP_DEX_KEY = 'tickers:by_perp_dex:%s'
      CONTRACT_KEY = 'contracts:%s:%s'
      LAST_UPDATE_KEY = 'tickers:last_update'
      COUNT_KEY = 'tickers:count'
      ALL_SYMBOLS_KEY = 'tickers:all_symbols'

      def initialize(redis = nil)
        @redis = redis || ArbitrageBot.redis
      end

      # Save a ticker to Redis
      def save(ticker)
        symbol = ticker.symbol.upcase

        # Save master record
        @redis.set(format(MASTER_KEY, symbol), ticker.to_json)

        # Update indexes
        update_indexes(ticker)

        # Save contract mappings
        save_contracts(ticker)
      end

      # Save multiple tickers in a pipeline
      def save_all(tickers)
        return if tickers.empty?

        @redis.pipelined do |pipe|
          tickers.each do |ticker|
            symbol = ticker.symbol.upcase
            pipe.set(format(MASTER_KEY, symbol), ticker.to_json)
          end
        end

        # Update indexes after pipeline
        tickers.each { |t| update_indexes(t) }

        # Update metadata
        @redis.set(LAST_UPDATE_KEY, Time.now.to_i)
        @redis.set(COUNT_KEY, tickers.size)

        # Update all symbols set
        symbols = tickers.map { |t| t.symbol.upcase }
        @redis.del(ALL_SYMBOLS_KEY)
        @redis.sadd(ALL_SYMBOLS_KEY, symbols) unless symbols.empty?
      end

      # Get a ticker by symbol
      def get(symbol)
        json = @redis.get(format(MASTER_KEY, symbol.upcase))
        return nil unless json

        Models::Ticker.from_json(json)
      end

      # Get multiple tickers
      def get_all(symbols)
        return [] if symbols.empty?

        keys = symbols.map { |s| format(MASTER_KEY, s.upcase) }
        jsons = @redis.mget(*keys)

        jsons.compact.map { |json| Models::Ticker.from_json(json) }
      end

      # Get all symbols
      def all_symbols
        @redis.smembers(ALL_SYMBOLS_KEY) || []
      end

      # Get symbols by exchange (futures)
      def symbols_by_exchange_futures(exchange)
        @redis.smembers(format(BY_EXCHANGE_FUTURES_KEY, exchange.downcase)) || []
      end

      # Get symbols by exchange (spot)
      def symbols_by_exchange_spot(exchange)
        @redis.smembers(format(BY_EXCHANGE_SPOT_KEY, exchange.downcase)) || []
      end

      # Get symbols by DEX
      def symbols_by_dex(dex)
        @redis.smembers(format(BY_DEX_KEY, dex.downcase)) || []
      end

      # Get symbols by Perp DEX
      def symbols_by_perp_dex(dex)
        @redis.smembers(format(BY_PERP_DEX_KEY, dex.downcase)) || []
      end

      # Find symbol by contract address
      def symbol_by_contract(chain, address)
        @redis.get(format(CONTRACT_KEY, chain.downcase, address.downcase))
      end

      # Get last update timestamp
      def last_update
        ts = @redis.get(LAST_UPDATE_KEY)
        ts ? Time.at(ts.to_i) : nil
      end

      # Get ticker count
      def count
        @redis.get(COUNT_KEY).to_i
      end

      # Delete a ticker
      def delete(symbol)
        ticker = get(symbol)
        return unless ticker

        # Remove from indexes
        remove_from_indexes(ticker)

        # Remove master record
        @redis.del(format(MASTER_KEY, symbol.upcase))

        # Remove from all symbols
        @redis.srem(ALL_SYMBOLS_KEY, symbol.upcase)
      end

      # Clear all ticker data
      def clear_all
        keys = @redis.keys('tickers:*') + @redis.keys('contracts:*')
        @redis.del(*keys) unless keys.empty?
      end

      # Get statistics
      def stats
        {
          total_tickers: count,
          last_update: last_update,
          exchanges_futures: count_by_pattern(BY_EXCHANGE_FUTURES_KEY),
          exchanges_spot: count_by_pattern(BY_EXCHANGE_SPOT_KEY),
          dexes: count_by_pattern(BY_DEX_KEY),
          perp_dexes: count_by_pattern(BY_PERP_DEX_KEY)
        }
      end

      private

      def update_indexes(ticker)
        symbol = ticker.symbol.upcase

        # CEX Futures indexes
        ticker.venues[:cex_futures]&.each do |venue|
          @redis.sadd(format(BY_EXCHANGE_FUTURES_KEY, venue[:exchange].downcase), symbol)
        end

        # CEX Spot indexes
        ticker.venues[:cex_spot]&.each do |venue|
          @redis.sadd(format(BY_EXCHANGE_SPOT_KEY, venue[:exchange].downcase), symbol)
        end

        # DEX indexes
        ticker.venues[:dex_spot]&.each do |venue|
          @redis.sadd(format(BY_DEX_KEY, venue[:dex].downcase), symbol)
        end

        # Perp DEX indexes
        ticker.venues[:perp_dex]&.each do |venue|
          @redis.sadd(format(BY_PERP_DEX_KEY, venue[:dex].downcase), symbol)
        end
      end

      def remove_from_indexes(ticker)
        symbol = ticker.symbol.upcase

        ticker.venues[:cex_futures]&.each do |venue|
          @redis.srem(format(BY_EXCHANGE_FUTURES_KEY, venue[:exchange].downcase), symbol)
        end

        ticker.venues[:cex_spot]&.each do |venue|
          @redis.srem(format(BY_EXCHANGE_SPOT_KEY, venue[:exchange].downcase), symbol)
        end

        ticker.venues[:dex_spot]&.each do |venue|
          @redis.srem(format(BY_DEX_KEY, venue[:dex].downcase), symbol)
        end

        ticker.venues[:perp_dex]&.each do |venue|
          @redis.srem(format(BY_PERP_DEX_KEY, venue[:dex].downcase), symbol)
        end
      end

      def save_contracts(ticker)
        ticker.contracts.each do |chain, address|
          next unless address

          @redis.set(
            format(CONTRACT_KEY, chain.downcase, address.downcase),
            ticker.symbol.upcase
          )
        end
      end

      def count_by_pattern(pattern)
        result = {}
        keys = @redis.keys(pattern.gsub('%s', '*'))

        keys.each do |key|
          name = key.split(':')[-1]
          result[name] = @redis.scard(key)
        end

        result
      end
    end
  end
end
