# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      class CooldownManager
        DEFAULT_COOLDOWN_SECONDS = 300 # 5 minutes
        KEY_PREFIX = 'alert:cooldown:'
        STATS_KEY = 'alert:cooldown:stats'

        attr_reader :redis, :default_cooldown

        def initialize(default_cooldown: nil, redis: nil)
          @redis = redis || ArbitrageBot.redis
          @default_cooldown = default_cooldown || DEFAULT_COOLDOWN_SECONDS
          @logger = ArbitrageBot.logger
        end

        # Check if a symbol is on cooldown
        # @param symbol [String] symbol to check
        # @param pair_id [String, nil] optional pair ID for more specific cooldown
        # @return [Boolean] true if NOT on cooldown (can send alert)
        def can_alert?(symbol, pair_id: nil)
          key = cooldown_key(symbol, pair_id)
          !@redis.exists?(key)
        end

        # Get remaining cooldown time in seconds
        # @param symbol [String] symbol to check
        # @param pair_id [String, nil] optional pair ID
        # @return [Integer] remaining seconds, 0 if not on cooldown
        def remaining_cooldown(symbol, pair_id: nil)
          key = cooldown_key(symbol, pair_id)
          ttl = @redis.ttl(key)
          ttl.positive? ? ttl : 0
        end

        # Set cooldown for a symbol
        # @param symbol [String] symbol
        # @param pair_id [String, nil] optional pair ID
        # @param seconds [Integer, nil] cooldown duration (uses default if nil)
        def set_cooldown(symbol, pair_id: nil, seconds: nil)
          key = cooldown_key(symbol, pair_id)
          duration = seconds || @default_cooldown

          @redis.setex(key, duration, Time.now.to_i)

          # Track stats
          increment_stats(:cooldowns_set)

          @logger.debug("[Cooldown] Set #{duration}s cooldown for #{symbol}")
        end

        # Clear cooldown for a symbol (manual override)
        # @param symbol [String] symbol
        # @param pair_id [String, nil] optional pair ID
        def clear_cooldown(symbol, pair_id: nil)
          key = cooldown_key(symbol, pair_id)
          @redis.del(key)

          @logger.info("[Cooldown] Cleared cooldown for #{symbol}")
        end

        # Get all active cooldowns
        # @return [Array<Hash>] list of active cooldowns with remaining time
        def active_cooldowns
          pattern = "#{KEY_PREFIX}*"
          keys = @redis.keys(pattern)

          keys.map do |key|
            symbol = key.sub(KEY_PREFIX, '')
            ttl = @redis.ttl(key)

            {
              symbol: symbol,
              remaining_seconds: ttl,
              expires_at: Time.now + ttl
            }
          end.select { |c| c[:remaining_seconds].positive? }
        end

        # Get cooldown statistics
        # @return [Hash] stats including total set, currently active
        def stats
          active = active_cooldowns
          stored_stats = @redis.hgetall(STATS_KEY)

          {
            active_count: active.size,
            cooldowns_set_total: stored_stats['cooldowns_set'].to_i,
            alerts_blocked_total: stored_stats['alerts_blocked'].to_i,
            default_cooldown_seconds: @default_cooldown
          }
        end

        # Record that an alert was blocked by cooldown
        def record_blocked
          increment_stats(:alerts_blocked)
        end

        # Check cooldown and record blocked if applicable
        # @param symbol [String]
        # @param pair_id [String, nil]
        # @return [Boolean] true if can alert
        def check_and_record(symbol, pair_id: nil)
          if can_alert?(symbol, pair_id: pair_id)
            true
          else
            record_blocked
            @logger.debug("[Cooldown] Alert blocked for #{symbol} (#{remaining_cooldown(symbol, pair_id: pair_id)}s remaining)")
            false
          end
        end

        # Process alert: check cooldown, set if passed
        # @param symbol [String]
        # @param pair_id [String, nil]
        # @param cooldown_seconds [Integer, nil]
        # @return [Boolean] true if alert was allowed
        def process_alert(symbol, pair_id: nil, cooldown_seconds: nil)
          if check_and_record(symbol, pair_id: pair_id)
            set_cooldown(symbol, pair_id: pair_id, seconds: cooldown_seconds)
            true
          else
            false
          end
        end

        private

        def cooldown_key(symbol, pair_id = nil)
          if pair_id
            "#{KEY_PREFIX}#{symbol}:#{pair_id}"
          else
            "#{KEY_PREFIX}#{symbol}"
          end
        end

        def increment_stats(field)
          @redis.hincrby(STATS_KEY, field.to_s, 1)
        end
      end
    end
  end
end
