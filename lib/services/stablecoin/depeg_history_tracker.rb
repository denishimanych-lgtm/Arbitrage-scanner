# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Stablecoin
      # Tracks stablecoin price/deviation history in Redis
      # Uses sorted sets with timestamp as score for efficient range queries
      class DepegHistoryTracker
        HISTORY_TTL = 7 * 24 * 60 * 60  # 7 days in seconds
        HISTORY_KEY_PREFIX = 'depeg_history'
        SAMPLE_INTERVAL = 60  # Save at most once per minute per stablecoin

        def initialize
          @redis = ArbitrageBot.redis
          @logger = ArbitrageBot.logger
          @last_saved = {}
        end

        # Record current stablecoin prices to history
        # @param prices [Array<Hash>] from DepegMonitor.fetch_all
        def record(prices)
          return if prices.nil? || prices.empty?

          now = Time.now.to_i

          prices.each do |price_data|
            symbol = price_data[:symbol]
            price = price_data[:price]
            deviation = price_data[:deviation_pct]

            next unless symbol && price && price > 0

            key = history_key(symbol)

            # Rate limit: save at most once per minute per stablecoin
            last = @last_saved[key] || 0
            next if now - last < SAMPLE_INTERVAL

            # Save to sorted set: score = timestamp, member = "timestamp:price:deviation"
            entry = "#{now}:#{price.round(6)}:#{deviation.round(4)}"
            @redis.zadd(key, now, entry)
            @last_saved[key] = now

            # Set TTL
            @redis.expire(key, HISTORY_TTL)
          end

          # Periodically clean old entries
          cleanup_old_entries if rand < 0.01
        rescue StandardError => e
          @logger.debug("[DepegHistoryTracker] record error: #{e.message}")
        end

        # Get statistics for a stablecoin over last N hours
        # @param symbol [String] stablecoin symbol (USDT, USDC, etc.)
        # @param hours [Integer] lookback period
        # @return [Hash, nil]
        def get_stats(symbol, hours: 24)
          key = history_key(symbol)
          cutoff = Time.now.to_i - (hours * 3600)

          entries = @redis.zrangebyscore(key, cutoff, '+inf')
          return nil if entries.empty?

          prices = []
          deviations = []
          min_price_entry = nil
          max_deviation_entry = nil

          entries.each do |entry|
            parts = entry.split(':')
            next unless parts.size >= 3

            ts = parts[0].to_i
            price = parts[1].to_f
            deviation = parts[2].to_f

            prices << price
            deviations << deviation.abs

            # Track minimum price (worst depeg)
            if min_price_entry.nil? || price < min_price_entry[:price]
              min_price_entry = { timestamp: ts, price: price, deviation: deviation }
            end

            # Track maximum absolute deviation
            if max_deviation_entry.nil? || deviation.abs > max_deviation_entry[:deviation].abs
              max_deviation_entry = { timestamp: ts, price: price, deviation: deviation }
            end
          end

          return nil if prices.empty?

          {
            symbol: symbol,
            hours: hours,
            sample_count: prices.size,
            current_price: prices.last,
            min_price: prices.min,
            max_price: prices.max,
            avg_price: (prices.sum / prices.size).round(6),
            max_deviation_pct: deviations.max&.round(4) || 0,
            avg_deviation_pct: (deviations.sum / deviations.size).round(4),
            worst_depeg: min_price_entry,
            worst_deviation: max_deviation_entry
          }
        rescue StandardError => e
          @logger.debug("[DepegHistoryTracker] get_stats error: #{e.message}")
          nil
        end

        # Convenience methods
        def stats_24h(symbol)
          get_stats(symbol, hours: 24)
        end

        def stats_3d(symbol)
          get_stats(symbol, hours: 72)
        end

        def stats_7d(symbol)
          get_stats(symbol, hours: 168)
        end

        # Format statistics for alert message
        # @param symbol [String]
        # @param current_deviation [Float, nil] current deviation %
        # @return [String]
        def format_stats_for_alert(symbol, current_deviation: nil)
          stats_24 = stats_24h(symbol)
          stats_3 = stats_3d(symbol)
          stats_7 = stats_7d(symbol)

          return "" unless stats_24 || stats_3 || stats_7

          lines = ["📈 ИСТОРИЯ ОТКЛОНЕНИЙ:"]

          if stats_24
            max_dev = stats_24[:max_deviation_pct]
            avg_dev = stats_24[:avg_deviation_pct]
            worst = stats_24[:worst_deviation]
            worst_time = worst ? Time.at(worst[:timestamp]).strftime('%H:%M') : 'N/A'
            worst_dev = worst ? worst[:deviation].round(2) : 0

            # Determine direction compared to current
            direction_24 = ''
            if current_deviation && avg_dev
              if current_deviation.abs > avg_dev.abs * 1.1
                direction_24 = ' ↗️ хуже'
              elsif current_deviation.abs < avg_dev.abs * 0.9
                direction_24 = ' ↘️ лучше'
              else
                direction_24 = ' →'
              end
            end

            lines << "   24ч: max #{max_dev}% avg #{avg_dev}%#{direction_24}"
            lines << "        worst: #{worst_dev}% @ #{worst_time}" if worst
          end

          if stats_3
            max_dev_3 = stats_3[:max_deviation_pct]
            avg_dev_3 = stats_3[:avg_deviation_pct]
            direction_3 = ''
            if stats_24 && stats_3[:avg_deviation_pct]
              if stats_24[:avg_deviation_pct] > stats_3[:avg_deviation_pct] * 1.1
                direction_3 = ' ↗️ ухудшается'
              elsif stats_24[:avg_deviation_pct] < stats_3[:avg_deviation_pct] * 0.9
                direction_3 = ' ↘️ улучшается'
              end
            end
            lines << "   3д:  max #{max_dev_3}% avg #{avg_dev_3}%#{direction_3}"
          end

          if stats_7
            max_dev_7 = stats_7[:max_deviation_pct]
            worst_7 = stats_7[:worst_deviation]
            worst_time_7 = worst_7 ? Time.at(worst_7[:timestamp]).strftime('%d/%m') : 'N/A'
            worst_dev_7 = worst_7 ? worst_7[:deviation].round(2) : 0
            lines << "   7д:  max #{max_dev_7}% (worst: #{worst_dev_7}% @ #{worst_time_7})"
          end

          lines.join("\n")
        rescue StandardError => e
          @logger.debug("[DepegHistoryTracker] format_stats error: #{e.message}")
          ""
        end

        private

        def history_key(symbol)
          "#{HISTORY_KEY_PREFIX}:#{symbol}"
        end

        def cleanup_old_entries
          cutoff = Time.now.to_i - HISTORY_TTL

          DepegMonitor::STABLECOINS.each do |symbol|
            key = history_key(symbol)
            @redis.zremrangebyscore(key, '-inf', cutoff)
          end
        rescue StandardError => e
          @logger.debug("[DepegHistoryTracker] cleanup error: #{e.message}")
        end
      end
    end
  end
end
