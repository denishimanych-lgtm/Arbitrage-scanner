# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      # Manages coin modes: real-time vs digest
      # Real-time mode = immediate alerts for every spread change
      # Digest mode = accumulated into 15-min digest
      class CoinModeManager
        REDIS_REALTIME_KEY = 'digest:realtime_coins'
        REDIS_TRACKING_KEY = 'digest:tracking:'
        DEFAULT_REALTIME_DURATION = 3 * 24 * 3600 # 3 days in seconds

        def initialize
          @logger = ArbitrageBot.logger
          # Don't cache @redis - use ArbitrageBot.redis directly for thread-safety
        end

        # Check if coin is in real-time mode
        # @param symbol [String] coin symbol
        # @return [Boolean]
        def realtime?(symbol)
          # Use thread-local Redis connection
          ArbitrageBot.redis.sismember(REDIS_REALTIME_KEY, symbol.to_s.upcase)
        rescue StandardError
          false
        end

        # Enable real-time mode for a coin (3 days by default)
        # @param symbol [String] coin symbol
        # @param duration [Integer] seconds to keep in real-time mode
        # @return [Boolean] success
        def enable_realtime(symbol, duration: DEFAULT_REALTIME_DURATION)
          symbol = symbol.to_s.upcase
          redis = ArbitrageBot.redis

          # Add to realtime set
          redis.sadd(REDIS_REALTIME_KEY, symbol)

          # Set expiration tracker
          tracking_key = "#{REDIS_TRACKING_KEY}#{symbol}"
          redis.setex(tracking_key, duration, Time.now.to_i.to_s)

          # Store tracking metadata
          store_tracking_metadata(symbol, duration)

          log("Enabled real-time mode for #{symbol} (#{duration / 3600}h)")
          true
        rescue StandardError => e
          @logger.error("[CoinModeManager] enable_realtime error: #{e.message}")
          false
        end

        # Disable real-time mode (return to digest)
        # @param symbol [String] coin symbol
        # @return [Boolean] success
        def disable_realtime(symbol)
          symbol = symbol.to_s.upcase
          redis = ArbitrageBot.redis

          redis.srem(REDIS_REALTIME_KEY, symbol)
          redis.del("#{REDIS_TRACKING_KEY}#{symbol}")
          redis.del("digest:metadata:#{symbol}")

          log("Disabled real-time mode for #{symbol}")
          true
        rescue StandardError => e
          @logger.error("[CoinModeManager] disable_realtime error: #{e.message}")
          false
        end

        # Get all coins in real-time mode
        # @return [Array<String>]
        def realtime_coins
          ArbitrageBot.redis.smembers(REDIS_REALTIME_KEY) || []
        rescue StandardError
          []
        end

        # Get tracking info for a coin
        # @param symbol [String] coin symbol
        # @return [Hash, nil] { started_at:, expires_at:, duration:, elapsed: }
        def tracking_info(symbol)
          symbol = symbol.to_s.upcase
          redis = ArbitrageBot.redis

          tracking_key = "#{REDIS_TRACKING_KEY}#{symbol}"
          started = redis.get(tracking_key)
          return nil unless started

          ttl = redis.ttl(tracking_key)
          return nil if ttl <= 0

          started_at = Time.at(started.to_i)
          expires_at = Time.now + ttl

          {
            symbol: symbol,
            started_at: started_at,
            expires_at: expires_at,
            duration: expires_at - started_at,
            elapsed: Time.now - started_at,
            remaining: ttl
          }
        rescue StandardError
          nil
        end

        # Check and cleanup expired real-time coins
        # Called periodically to remove coins whose tracking expired
        def cleanup_expired
          redis = ArbitrageBot.redis
          coins = realtime_coins
          removed = []

          coins.each do |symbol|
            tracking_key = "#{REDIS_TRACKING_KEY}#{symbol}"
            ttl = redis.ttl(tracking_key)

            if ttl <= 0
              redis.srem(REDIS_REALTIME_KEY, symbol)
              removed << symbol
            end
          end

          log("Cleaned up #{removed.size} expired real-time coins") if removed.any?
          removed
        rescue StandardError => e
          @logger.error("[CoinModeManager] cleanup_expired error: #{e.message}")
          []
        end

        # Get statistics
        # @return [Hash]
        def stats
          coins = realtime_coins

          {
            realtime_count: coins.size,
            realtime_coins: coins,
            tracking_info: coins.map { |s| tracking_info(s) }.compact
          }
        end

        # Record a spread observation for a tracked coin
        # Used for historical analysis (did the spread converge?)
        # @param symbol [String] coin symbol
        # @param spread_data [Hash] spread observation
        def record_observation(symbol, spread_data)
          return unless realtime?(symbol)

          redis = ArbitrageBot.redis
          symbol = symbol.to_s.upcase
          obs_key = "digest:observations:#{symbol}"

          observation = {
            timestamp: Time.now.to_i,
            spread_pct: spread_data[:spread_pct],
            pair_id: spread_data[:pair_id],
            category: spread_data[:category]
          }

          # Store as sorted set by timestamp
          redis.zadd(obs_key, Time.now.to_i, observation.to_json)

          # Keep only last 7 days of observations
          week_ago = Time.now.to_i - (7 * 24 * 3600)
          redis.zremrangebyscore(obs_key, '-inf', week_ago)

          # Set TTL on the observations key
          redis.expire(obs_key, 8 * 24 * 3600) # 8 days
        rescue StandardError => e
          @logger.debug("[CoinModeManager] record_observation error: #{e.message}")
        end

        # Get observation history for a coin
        # @param symbol [String] coin symbol
        # @param hours [Integer] how many hours back
        # @return [Array<Hash>]
        def get_observations(symbol, hours: 24)
          symbol = symbol.to_s.upcase
          obs_key = "digest:observations:#{symbol}"

          since = Time.now.to_i - (hours * 3600)
          raw = ArbitrageBot.redis.zrangebyscore(obs_key, since, '+inf')

          raw.map { |json| JSON.parse(json, symbolize_names: true) }
        rescue StandardError
          []
        end

        # Analyze if spread converged for a coin
        # @param symbol [String] coin symbol
        # @return [Hash] { converged:, min_spread:, max_spread:, observations: }
        def analyze_convergence(symbol)
          observations = get_observations(symbol, hours: 72) # 3 days

          return { converged: nil, observations: 0 } if observations.empty?

          spreads = observations.map { |o| o[:spread_pct].to_f }

          {
            converged: spreads.min < 1.0, # Consider converged if spread went below 1%
            min_spread: spreads.min.round(2),
            max_spread: spreads.max.round(2),
            current_spread: spreads.last.round(2),
            observations: observations.size,
            first_observation: Time.at(observations.first[:timestamp]),
            last_observation: Time.at(observations.last[:timestamp])
          }
        end

        private

        def store_tracking_metadata(symbol, duration)
          meta_key = "digest:metadata:#{symbol}"
          metadata = {
            started_at: Time.now.to_i,
            duration: duration,
            expires_at: Time.now.to_i + duration
          }
          ArbitrageBot.redis.setex(meta_key, duration + 3600, metadata.to_json)
        end

        def log(message)
          @logger.info("[CoinModeManager] #{message}")
        end
      end
    end
  end
end
