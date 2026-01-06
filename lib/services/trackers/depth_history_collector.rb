# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Trackers
      class DepthHistoryCollector
        COLLECTION_INTERVAL = 3 * 60 # 3 minutes
        MAX_SAMPLES = 480            # 24 hours at 3-minute intervals
        HISTORY_TTL = 24 * 3600      # 24 hours
        KEY_PREFIX = 'depth_history:'

        DepthStats = Struct.new(
          :samples, :avg, :min, :max, :median, :p10, :p90, :std_dev,
          keyword_init: true
        )

        def initialize(redis = nil)
          @redis = redis || ArbitrageBot.redis
          @depth_calc = Calculators::DepthCalculator.new
        end

        # Collect depth sample for a venue
        # @param pair_id [String] arbitrage pair identifier
        # @param venue_id [String] venue identifier
        # @param orderbook [Hash] orderbook data
        # @param max_slippage_pct [Float] slippage limit for depth calculation
        def collect(pair_id, venue_id, orderbook, max_slippage_pct: 1.0)
          calc = Calculators::DepthCalculator.new(max_slippage_pct: max_slippage_pct)

          %i[bids asks].each do |side|
            depth = calc.calculate_with_slippage(orderbook, side)
            store_sample(pair_id, venue_id, side, depth.total_usd.to_f)
          end
        end

        # Get statistics for depth history
        # @param pair_id [String] arbitrage pair identifier
        # @param venue_id [String] venue identifier
        # @param side [Symbol] :bids or :asks
        # @return [DepthStats, nil]
        def stats(pair_id, venue_id, side)
          key = depth_key(pair_id, venue_id, side)
          values = @redis.lrange(key, 0, -1).map(&:to_f)

          return nil if values.empty?

          sorted = values.sort

          DepthStats.new(
            samples: values.count,
            avg: (values.sum / values.count).round(2),
            min: values.min.round(2),
            max: values.max.round(2),
            median: percentile(sorted, 50).round(2),
            p10: percentile(sorted, 10).round(2),
            p90: percentile(sorted, 90).round(2),
            std_dev: std_dev(values).round(2)
          )
        end

        # Get current depth vs historical average ratio
        def depth_vs_history_ratio(pair_id, venue_id, side, current_depth)
          historical = stats(pair_id, venue_id, side)

          return nil unless historical && historical.avg > 0

          (current_depth.to_f / historical.avg).round(4)
        end

        # Check if current depth is dangerously low
        # @return [:ok, :warning, :danger]
        def depth_status(pair_id, venue_id, side, current_depth, warning_ratio: 0.5, danger_ratio: 0.3)
          ratio = depth_vs_history_ratio(pair_id, venue_id, side, current_depth)

          return :ok if ratio.nil? # No history yet

          if ratio < danger_ratio
            :danger
          elsif ratio < warning_ratio
            :warning
          else
            :ok
          end
        end

        # Get all stats for a pair
        def all_stats_for_pair(pair_id, venue_id)
          {
            bids: stats(pair_id, venue_id, :bids),
            asks: stats(pair_id, venue_id, :asks)
          }
        end

        # Clear history for a pair/venue
        def clear(pair_id, venue_id)
          %i[bids asks].each do |side|
            @redis.del(depth_key(pair_id, venue_id, side))
          end
        end

        private

        def store_sample(pair_id, venue_id, side, value)
          key = depth_key(pair_id, venue_id, side)

          @redis.lpush(key, value)
          @redis.ltrim(key, 0, MAX_SAMPLES - 1)
          @redis.expire(key, HISTORY_TTL)
        end

        def depth_key(pair_id, venue_id, side)
          "#{KEY_PREFIX}#{pair_id}:#{venue_id}:#{side}"
        end

        def percentile(sorted_array, pct)
          return 0 if sorted_array.empty?

          k = (pct / 100.0 * (sorted_array.length - 1)).floor
          sorted_array[k]
        end

        def std_dev(values)
          return 0 if values.empty?

          mean = values.sum / values.length.to_f
          variance = values.sum { |v| (v - mean)**2 } / values.length.to_f
          Math.sqrt(variance)
        end
      end
    end
  end
end
