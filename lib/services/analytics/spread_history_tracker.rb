# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Tracks spread history in Redis for symbols that triggered alerts
      # Uses sorted sets with timestamp as score for efficient range queries
      # When a symbol gets an alert, ALL pairs of that symbol are tracked
      class SpreadHistoryTracker
        HISTORY_TTL = 7 * 24 * 60 * 60  # 7 days in seconds
        TRACKING_TTL = 7 * 24 * 60 * 60  # Stop tracking after 7 days of no alerts
        HISTORY_KEY_PREFIX = 'spread_history'
        TRACKING_KEY_PREFIX = 'spread_tracking'
        SAMPLE_INTERVAL = 60  # Save at most once per minute per pair

        def initialize
          @redis = ArbitrageBot.redis
          @logger = ArbitrageBot.logger
          @last_saved = {}  # Track last save time per pair to avoid spam
        end

        # Start tracking ALL pairs for a symbol after an alert is generated
        # @param symbol [String]
        def start_tracking(symbol)
          key = symbol_tracking_key(symbol)
          @redis.set(key, '1')
          @redis.expire(key, TRACKING_TTL)

          @logger.debug("[SpreadHistoryTracker] Started tracking symbol #{symbol}")
        rescue StandardError => e
          @logger.debug("[SpreadHistoryTracker] start_tracking error: #{e.message}")
        end

        # Check if a symbol is being tracked
        def tracking_symbol?(symbol)
          key = symbol_tracking_key(symbol)
          @redis.exists?(key)
        rescue StandardError
          false
        end

        # Record current spreads to history (only for tracked symbols)
        # Called from PriceMonitorJob after calculating spreads
        # @param spreads [Array<Hash>] current spreads
        def record(spreads)
          return if spreads.nil? || spreads.empty?

          now = Time.now.to_i
          recorded = 0

          spreads.each do |spread|
            pair_id = spread[:pair_id] || spread['pair_id']
            symbol = spread[:symbol] || spread['symbol']
            spread_pct = (spread[:spread_pct] || spread['spread_pct']).to_f.abs

            next unless pair_id && symbol && spread_pct > 0

            # Only record for tracked symbols (those that had an alert)
            next unless tracking_symbol?(symbol)

            key = history_key(pair_id, symbol)

            # Rate limit: save at most once per minute per pair
            last = @last_saved[key] || 0
            next if now - last < SAMPLE_INTERVAL

            # Save to sorted set: score = timestamp, member = spread value
            @redis.zadd(key, now, "#{now}:#{spread_pct.round(4)}")
            @last_saved[key] = now
            recorded += 1

            # Set TTL on first write (will refresh on each write)
            @redis.expire(key, HISTORY_TTL)
          end

          # Periodically clean old entries (every ~100 records)
          cleanup_old_entries if recorded > 0 && rand < 0.01
        rescue StandardError => e
          @logger.debug("[SpreadHistoryTracker] record error: #{e.message}")
        end

        # Get spread statistics for a pair over last N hours
        # @param pair_id [String]
        # @param symbol [String]
        # @param hours [Integer] lookback period
        # @return [Hash, nil] { max_spread:, min_spread:, avg_spread:, sample_count: }
        def get_stats(pair_id, symbol, hours: 24)
          key = history_key(pair_id, symbol)

          # Also check flipped pair_id
          flipped_key = history_key(flip_pair_id(pair_id), symbol)

          cutoff = Time.now.to_i - (hours * 3600)

          # Get entries from both directions
          entries = @redis.zrangebyscore(key, cutoff, '+inf')
          flipped_entries = @redis.zrangebyscore(flipped_key, cutoff, '+inf')

          all_entries = entries + flipped_entries
          return nil if all_entries.empty?

          spreads = all_entries.map do |entry|
            # Format: "timestamp:spread_pct"
            parts = entry.split(':')
            parts[1].to_f if parts.size >= 2
          end.compact

          return nil if spreads.empty?

          {
            max_spread: spreads.max,
            min_spread: spreads.min,
            avg_spread: (spreads.sum / spreads.size).round(4),
            sample_count: spreads.size
          }
        rescue StandardError => e
          @logger.debug("[SpreadHistoryTracker] get_stats error: #{e.message}")
          nil
        end

        # Get 24h stats
        def stats_24h(pair_id, symbol)
          get_stats(pair_id, symbol, hours: 24)
        end

        # Get 7d stats
        def stats_7d(pair_id, symbol)
          get_stats(pair_id, symbol, hours: 168)
        end

        private

        def history_key(pair_id, symbol)
          "#{HISTORY_KEY_PREFIX}:#{pair_id}:#{symbol}"
        end

        def symbol_tracking_key(symbol)
          "#{TRACKING_KEY_PREFIX}:symbol:#{symbol}"
        end

        def flip_pair_id(pair_id)
          parts = pair_id.to_s.split(':')
          return pair_id if parts.size != 2
          "#{parts[1]}:#{parts[0]}"
        end

        # Remove entries older than 7 days from all history keys
        def cleanup_old_entries
          cutoff = Time.now.to_i - HISTORY_TTL
          pattern = "#{HISTORY_KEY_PREFIX}:*"

          cursor = '0'
          cleaned = 0

          loop do
            cursor, keys = @redis.scan(cursor, match: pattern, count: 100)

            keys.each do |key|
              removed = @redis.zremrangebyscore(key, '-inf', cutoff)
              cleaned += removed if removed > 0
            end

            break if cursor == '0'
          end

          @logger.debug("[SpreadHistoryTracker] Cleaned #{cleaned} old entries") if cleaned > 0
        rescue StandardError => e
          @logger.debug("[SpreadHistoryTracker] cleanup error: #{e.message}")
        end
      end
    end
  end
end
