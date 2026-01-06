# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      class Blacklist
        SYMBOLS_KEY = 'blacklist:symbols'
        ADDRESSES_KEY = 'blacklist:addresses'
        EXCHANGES_KEY = 'blacklist:exchanges'
        PAIRS_KEY = 'blacklist:pairs'

        attr_reader :redis

        def initialize(redis: nil)
          @redis = redis || ArbitrageBot.redis
          @logger = ArbitrageBot.logger
        end

        # === Symbol Blacklist ===

        # Check if a symbol is blacklisted
        # @param symbol [String] symbol to check (case-insensitive)
        # @return [Boolean]
        def symbol_blacklisted?(symbol)
          @redis.sismember(SYMBOLS_KEY, normalize_symbol(symbol))
        end

        # Add a symbol to blacklist
        # @param symbol [String]
        def add_symbol(symbol)
          normalized = normalize_symbol(symbol)
          @redis.sadd(SYMBOLS_KEY, normalized)
          @logger.info("[Blacklist] Added symbol: #{normalized}")
        end

        # Remove a symbol from blacklist
        # @param symbol [String]
        def remove_symbol(symbol)
          normalized = normalize_symbol(symbol)
          @redis.srem(SYMBOLS_KEY, normalized)
          @logger.info("[Blacklist] Removed symbol: #{normalized}")
        end

        # Get all blacklisted symbols
        # @return [Array<String>]
        def symbols
          @redis.smembers(SYMBOLS_KEY).sort
        end

        # === Address Blacklist ===

        # Check if a contract address is blacklisted
        # @param address [String] contract address
        # @return [Boolean]
        def address_blacklisted?(address)
          return false unless address

          @redis.sismember(ADDRESSES_KEY, address.downcase)
        end

        # Add a contract address to blacklist
        # @param address [String]
        def add_address(address)
          normalized = address.to_s.downcase
          @redis.sadd(ADDRESSES_KEY, normalized)
          @logger.info("[Blacklist] Added address: #{normalized}")
        end

        # Remove a contract address from blacklist
        # @param address [String]
        def remove_address(address)
          normalized = address.to_s.downcase
          @redis.srem(ADDRESSES_KEY, normalized)
          @logger.info("[Blacklist] Removed address: #{normalized}")
        end

        # Get all blacklisted addresses
        # @return [Array<String>]
        def addresses
          @redis.smembers(ADDRESSES_KEY).sort
        end

        # === Exchange Blacklist ===

        # Check if an exchange is blacklisted
        # @param exchange [String] exchange name
        # @return [Boolean]
        def exchange_blacklisted?(exchange)
          return false unless exchange

          @redis.sismember(EXCHANGES_KEY, exchange.downcase)
        end

        # Add an exchange to blacklist
        # @param exchange [String]
        def add_exchange(exchange)
          normalized = exchange.to_s.downcase
          @redis.sadd(EXCHANGES_KEY, normalized)
          @logger.info("[Blacklist] Added exchange: #{normalized}")
        end

        # Remove an exchange from blacklist
        # @param exchange [String]
        def remove_exchange(exchange)
          normalized = exchange.to_s.downcase
          @redis.srem(EXCHANGES_KEY, normalized)
          @logger.info("[Blacklist] Removed exchange: #{normalized}")
        end

        # Get all blacklisted exchanges
        # @return [Array<String>]
        def exchanges
          @redis.smembers(EXCHANGES_KEY).sort
        end

        # === Pair Blacklist ===

        # Check if a specific pair is blacklisted
        # @param pair_id [String] pair identifier
        # @return [Boolean]
        def pair_blacklisted?(pair_id)
          return false unless pair_id

          @redis.sismember(PAIRS_KEY, pair_id)
        end

        # Add a pair to blacklist
        # @param pair_id [String]
        def add_pair(pair_id)
          @redis.sadd(PAIRS_KEY, pair_id)
          @logger.info("[Blacklist] Added pair: #{pair_id}")
        end

        # Remove a pair from blacklist
        # @param pair_id [String]
        def remove_pair(pair_id)
          @redis.srem(PAIRS_KEY, pair_id)
          @logger.info("[Blacklist] Removed pair: #{pair_id}")
        end

        # Get all blacklisted pairs
        # @return [Array<String>]
        def pairs
          @redis.smembers(PAIRS_KEY).sort
        end

        # === Comprehensive Check ===

        # Check if a signal should be blocked by any blacklist
        # @param signal [Hash] signal data
        # @return [Boolean] true if blacklisted (should block)
        def blocked?(signal)
          symbol = signal[:symbol] || signal['symbol']
          pair_id = signal[:pair_id] || signal['pair_id']
          low_venue = signal[:low_venue] || signal['low_venue'] || {}
          high_venue = signal[:high_venue] || signal['high_venue'] || {}

          # Check symbol
          return true if symbol_blacklisted?(symbol)

          # Check pair
          return true if pair_blacklisted?(pair_id)

          # Check addresses
          low_address = low_venue[:token_address] || low_venue['token_address']
          high_address = high_venue[:token_address] || high_venue['token_address']
          return true if address_blacklisted?(low_address)
          return true if address_blacklisted?(high_address)

          # Check exchanges
          low_exchange = low_venue[:exchange] || low_venue['exchange'] || low_venue[:dex] || low_venue['dex']
          high_exchange = high_venue[:exchange] || high_venue['exchange'] || high_venue[:dex] || high_venue['dex']
          return true if exchange_blacklisted?(low_exchange)
          return true if exchange_blacklisted?(high_exchange)

          false
        end

        # === Utility Methods ===

        # Get blacklist statistics
        # @return [Hash]
        def stats
          {
            symbols_count: @redis.scard(SYMBOLS_KEY),
            addresses_count: @redis.scard(ADDRESSES_KEY),
            exchanges_count: @redis.scard(EXCHANGES_KEY),
            pairs_count: @redis.scard(PAIRS_KEY)
          }
        end

        # Get all blacklist items formatted for display
        # @return [Hash]
        def all
          {
            symbols: symbols,
            addresses: addresses,
            exchanges: exchanges,
            pairs: pairs
          }
        end

        # Clear all blacklists (use with caution!)
        def clear_all!
          @redis.del(SYMBOLS_KEY)
          @redis.del(ADDRESSES_KEY)
          @redis.del(EXCHANGES_KEY)
          @redis.del(PAIRS_KEY)
          @logger.warn('[Blacklist] All blacklists cleared!')
        end

        # Import blacklist from hash
        # @param data [Hash] with keys: symbols, addresses, exchanges, pairs
        def import(data)
          data[:symbols]&.each { |s| add_symbol(s) }
          data[:addresses]&.each { |a| add_address(a) }
          data[:exchanges]&.each { |e| add_exchange(e) }
          data[:pairs]&.each { |p| add_pair(p) }
        end

        private

        def normalize_symbol(symbol)
          symbol.to_s.upcase.gsub(/[^A-Z0-9]/, '')
        end
      end
    end
  end
end
