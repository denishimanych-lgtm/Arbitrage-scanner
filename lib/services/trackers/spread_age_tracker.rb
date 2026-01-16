# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Trackers
      class SpreadAgeTracker
        SPREAD_TTL = 48 * 3600 # 48 hours in seconds
        KEY_PREFIX = 'spread:first_seen:'

        def initialize(redis = nil)
          # Don't store @redis - always use thread-local connection
        end

        # Record when spread first exceeded threshold
        # @param pair_id [String] arbitrage pair identifier
        # @param current_spread_pct [Numeric] current spread percentage
        # @param min_spread_threshold [Numeric] minimum spread to track
        def record(pair_id, current_spread_pct, min_spread_threshold)
          redis = ArbitrageBot.redis  # Thread-local connection
          key = spread_key(pair_id)

          if current_spread_pct.abs >= min_spread_threshold
            # Only set if key doesn't exist (first time seeing this spread)
            unless redis.exists?(key)
              redis.set(key, Time.now.to_i)
              redis.expire(key, SPREAD_TTL)
            end
          else
            # Spread dropped below threshold, reset tracking
            redis.del(key)
          end
        end

        # Get age of spread in hours
        # @param pair_id [String] arbitrage pair identifier
        # @return [Float] age in hours, 0 if not tracked
        def age_hours(pair_id)
          redis = ArbitrageBot.redis
          key = spread_key(pair_id)
          first_seen = redis.get(key)

          return 0.0 if first_seen.nil?

          (Time.now.to_i - first_seen.to_i) / 3600.0
        end

        # Get age of spread in minutes
        def age_minutes(pair_id)
          age_hours(pair_id) * 60
        end

        # Check if spread is older than threshold
        def older_than?(pair_id, hours)
          age_hours(pair_id) > hours
        end

        # Get first seen timestamp
        def first_seen_at(pair_id)
          redis = ArbitrageBot.redis
          key = spread_key(pair_id)
          ts = redis.get(key)

          ts ? Time.at(ts.to_i) : nil
        end

        # Reset tracking for a pair
        def reset(pair_id)
          ArbitrageBot.redis.del(spread_key(pair_id))
        end

        # Get all tracked pairs with ages
        def all_tracked
          redis = ArbitrageBot.redis
          keys = redis.keys("#{KEY_PREFIX}*")

          keys.map do |key|
            pair_id = key.sub(KEY_PREFIX, '')
            first_seen = redis.get(key).to_i
            age = (Time.now.to_i - first_seen) / 3600.0

            {
              pair_id: pair_id,
              first_seen: Time.at(first_seen),
              age_hours: age.round(2)
            }
          end.sort_by { |h| -h[:age_hours] }
        end

        private

        def spread_key(pair_id)
          "#{KEY_PREFIX}#{pair_id}"
        end
      end
    end
  end
end
