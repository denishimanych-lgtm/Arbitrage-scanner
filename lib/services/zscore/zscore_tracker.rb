# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Tracks z-scores using rolling statistics
      # Uses Redis for real-time tracking and PostgreSQL for historical data
      class ZScoreTracker
        REDIS_PREFIX = 'zscore:'
        REDIS_HISTORY_KEY = 'zscore:history:'

        def initialize
          @logger = ArbitrageBot.logger
          @ratio_calculator = RatioCalculator.new
        end

        # Calculate z-score for a pair
        # @param pair_str [String] pair like 'BTC/ETH'
        # @return [Hash, nil] z-score data
        def calculate_zscore(pair_str)
          pair = PairsConfig.find_pair(pair_str)
          return nil unless pair

          base, quote = pair[0], pair[1]
          ratio_data = @ratio_calculator.calculate(base, quote)
          return nil unless ratio_data

          current_ratio = ratio_data[:ratio]
          stats = get_rolling_stats(pair_str)

          # Store current ratio for future calculations
          store_ratio(pair_str, current_ratio)

          # Not enough data yet
          if stats[:count] < PairsConfig.min_data_points
            return {
              pair: pair_str,
              ratio: current_ratio,
              zscore: nil,
              status: :insufficient_data,
              count: stats[:count],
              required: PairsConfig.min_data_points
            }
          end

          zscore = (current_ratio - stats[:mean]) / stats[:std]

          {
            pair: pair_str,
            ratio: current_ratio,
            mean: stats[:mean],
            std: stats[:std],
            zscore: zscore,
            count: stats[:count],
            status: classify_zscore(zscore),
            thresholds: PairsConfig.thresholds,
            calculated_at: Time.now
          }
        end

        # Calculate z-scores for all pairs
        # @return [Array<Hash>]
        def calculate_all
          PairsConfig.pair_symbols.filter_map do |pair_str|
            calculate_zscore(pair_str)
          end
        end

        # Get current z-scores from Redis cache
        # @return [Hash] pair => zscore data
        def current_zscores
          redis = ArbitrageBot.redis
          result = {}

          PairsConfig.pair_symbols.each do |pair_str|
            key = "#{REDIS_PREFIX}current:#{pair_str}"
            data = redis.get(key)
            result[pair_str] = JSON.parse(data, symbolize_names: true) if data
          end

          result
        rescue StandardError => e
          @logger.error("[ZScoreTracker] current_zscores error: #{e.message}")
          {}
        end

        # Store calculated z-score in Redis
        def cache_zscore(zscore_data)
          return unless zscore_data && zscore_data[:pair]

          redis = ArbitrageBot.redis
          key = "#{REDIS_PREFIX}current:#{zscore_data[:pair]}"

          # Store for 5 minutes (should be refreshed every minute)
          redis.setex(key, 300, zscore_data.to_json)
        end

        # Log z-score to PostgreSQL
        def log_to_db(zscore_data)
          return unless zscore_data && zscore_data[:zscore]

          Analytics::PostgresLogger.log_zscore(
            pair: zscore_data[:pair],
            ratio: zscore_data[:ratio],
            mean: zscore_data[:mean],
            std: zscore_data[:std],
            zscore: zscore_data[:zscore]
          )
        end

        private

        def get_rolling_stats(pair_str)
          # Try PostgreSQL first for historical data
          db_stats = get_stats_from_db(pair_str)
          return db_stats if db_stats && db_stats[:count] >= PairsConfig.min_data_points

          # Fallback to Redis history
          get_stats_from_redis(pair_str)
        end

        def get_stats_from_db(pair_str)
          lookback = PairsConfig.lookback_days

          sql = <<~SQL
            SELECT
              COUNT(*) as count,
              AVG(ratio) as mean,
              STDDEV_SAMP(ratio) as std
            FROM zscore_log
            WHERE pair = $1
              AND ts > NOW() - INTERVAL '#{lookback} days'
          SQL

          result = Analytics::DatabaseConnection.query_one(sql, [pair_str])
          return nil unless result

          count = result['count'].to_i
          return nil if count < 2

          {
            count: count,
            mean: result['mean'].to_f,
            std: result['std'].to_f.nonzero? || 0.0001  # Avoid division by zero
          }
        rescue StandardError => e
          @logger.debug("[ZScoreTracker] DB stats error: #{e.message}")
          nil
        end

        def get_stats_from_redis(pair_str)
          redis = ArbitrageBot.redis
          key = "#{REDIS_HISTORY_KEY}#{pair_str}"

          # Get all stored ratios
          ratios = redis.lrange(key, 0, -1).map(&:to_f)

          return { count: 0, mean: 0, std: 0 } if ratios.empty?

          mean = ratios.sum / ratios.size

          if ratios.size > 1
            variance = ratios.map { |r| (r - mean) ** 2 }.sum / (ratios.size - 1)
            std = Math.sqrt(variance)
          else
            std = 0.0001
          end

          {
            count: ratios.size,
            mean: mean,
            std: std.nonzero? || 0.0001
          }
        end

        def store_ratio(pair_str, ratio)
          redis = ArbitrageBot.redis
          key = "#{REDIS_HISTORY_KEY}#{pair_str}"

          # Store in Redis list (for real-time calculations)
          redis.lpush(key, ratio.to_s)

          # Keep only last N days worth of data (assuming 1 sample per minute)
          max_samples = PairsConfig.lookback_days * 24 * 60
          redis.ltrim(key, 0, max_samples - 1)
        end

        def classify_zscore(zscore)
          abs_z = zscore.abs
          thresholds = PairsConfig.thresholds

          if abs_z >= thresholds[:stop]
            :stop_loss
          elsif abs_z >= thresholds[:entry]
            :entry_signal
          elsif abs_z <= thresholds[:exit]
            :exit_zone
          else
            :normal
          end
        end
      end
    end
  end
end
