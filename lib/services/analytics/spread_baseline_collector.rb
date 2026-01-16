# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Collects background spread statistics to understand "normal" spread behavior
      # Uses Redis for in-memory sample collection, flushes hourly to PostgreSQL
      class SpreadBaselineCollector
        REDIS_KEY_PREFIX = 'spread_baseline:'
        SAMPLES_PER_HOUR_LIMIT = 3600  # Max samples to keep per hour (1 per second max)
        RETENTION_HOURS = 168  # 7 days of hourly data

        def initialize
          @logger = ArbitrageBot.logger
          # Use a dedicated Redis connection to avoid thread-local issues
          @redis = Redis.new(
            url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
            connect_timeout: 5,
            read_timeout: 30,
            write_timeout: 30
          )
          @last_flush_hour = nil
        end

        # Record a spread sample (called from PriceMonitorJob)
        # @param pair_id [String] e.g. "binance_spot:bybit_futures"
        # @param symbol [String] e.g. "FLOW"
        # @param spread_pct [Float] current spread percentage
        def record_sample(pair_id:, symbol:, spread_pct:)
          return if spread_pct.nil? || spread_pct.abs > 100  # sanity check

          hour_bucket = current_hour_bucket
          key = redis_key(pair_id, symbol, hour_bucket)

          # Add to sorted set with timestamp as score for ordering
          @redis.zadd(key, Time.now.to_f, "#{Time.now.to_f}:#{spread_pct}")

          # Trim to limit memory usage (keep most recent samples)
          @redis.zremrangebyrank(key, 0, -SAMPLES_PER_HOUR_LIMIT - 1)

          # Set expiry on first add (2 hours to allow flush)
          @redis.expire(key, 7200) if @redis.zcard(key) == 1
        rescue StandardError => e
          @logger.debug("[BaselineCollector] record_sample error: #{e.message}")
        end

        # Batch record multiple spreads
        # Groups by key and stores just ONE sample per key per call (latest value)
        # This keeps Redis operations fast while still collecting data
        # @param spreads [Array<Hash>] array of {pair_id:, symbol:, spread_pct:}
        BATCH_SIZE = 1000  # Process in chunks to avoid blocking

        def record_batch(spreads)
          return if spreads.empty?

          start = Time.now
          hour_bucket = current_hour_bucket
          timestamp = Time.now.to_f

          # Group by Redis key, keeping only latest value per key
          by_key = {}
          skipped = 0

          spreads.each do |spread|
            if spread[:spread_pct].nil? || spread[:spread_pct].abs > 100
              skipped += 1
              next
            end
            if spread[:pair_id].nil? || spread[:symbol].nil?
              skipped += 1
              next
            end

            key = redis_key(spread[:pair_id], spread[:symbol], hour_bucket)
            # Keep only one value per key (overwrite if exists)
            by_key[key] = spread[:spread_pct]
          end

          group_elapsed = ((Time.now - start) * 1000).round
          @logger.info("[BaselineCollector] Grouped #{by_key.size} keys in #{group_elapsed}ms (skipped: #{skipped})")

          return if by_key.empty?

          # Process in batches to avoid blocking
          redis_start = Time.now
          keys_array = by_key.to_a
          keys_array.each_slice(BATCH_SIZE) do |batch|
            @redis.pipelined do |pipe|
              batch.each do |key, spread_pct|
                pipe.zadd(key, timestamp, "#{timestamp}:#{spread_pct}")
                pipe.expire(key, 7200)
              end
            end
          end
          redis_elapsed = ((Time.now - redis_start) * 1000).round

          total_elapsed = ((Time.now - start) * 1000).round
          @logger.info("[BaselineCollector] Recorded #{by_key.size} samples in #{total_elapsed}ms (redis: #{redis_elapsed}ms)")

          # Check if we should flush previous hour
          maybe_flush_previous_hour(hour_bucket)
        rescue StandardError => e
          @logger.error("[BaselineCollector] record_batch error: #{e.message}")
        end

        # Flush previous hour's data to PostgreSQL
        def maybe_flush_previous_hour(current_bucket = nil)
          current_bucket ||= current_hour_bucket
          prev_bucket = current_bucket - 3600

          # Only flush once per hour
          return if @last_flush_hour == prev_bucket

          flush_hour(prev_bucket)
          @last_flush_hour = prev_bucket
        end

        # Flush a specific hour's data to PostgreSQL
        # @param hour_timestamp [Integer] Unix timestamp of hour start
        def flush_hour(hour_timestamp)
          pattern = "#{REDIS_KEY_PREFIX}*:#{hour_timestamp}"
          keys = @redis.keys(pattern)

          return if keys.empty?

          @logger.info("[BaselineCollector] Flushing #{keys.size} pairs for hour #{Time.at(hour_timestamp)}")

          flushed = 0
          keys.each do |key|
            pair_id, symbol, _ = parse_redis_key(key)
            next unless pair_id && symbol

            samples = get_samples_from_redis(key)
            next if samples.empty?

            save_hourly_aggregate(pair_id, symbol, hour_timestamp, samples)
            @redis.del(key)
            flushed += 1
          end

          @logger.info("[BaselineCollector] Flushed #{flushed} pairs")

          # Cleanup old data
          cleanup_old_data
        rescue StandardError => e
          @logger.error("[BaselineCollector] flush_hour error: #{e.message}")
        end

        # Get baseline statistics for a specific pair
        # @param pair_id [String] e.g. "binance_spot:bybit_futures"
        # @param symbol [String] e.g. "FLOW"
        # @param days [Integer] lookback period
        # @return [Hash] baseline statistics
        def get_baseline(pair_id:, symbol:, days: 7)
          sql = <<~SQL
            SELECT
              COUNT(*) as hours_count,
              SUM(samples_count) as total_samples,
              ROUND(AVG(avg_spread_pct)::numeric, 2) as avg_spread,
              ROUND(MIN(min_spread_pct)::numeric, 2) as min_spread,
              ROUND(MAX(max_spread_pct)::numeric, 2) as max_spread,
              ROUND(AVG(p50_spread_pct)::numeric, 2) as median_spread,
              ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY avg_spread_pct)::numeric, 2) as p5_avg,
              ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY avg_spread_pct)::numeric, 2) as p95_avg
            FROM spread_baseline
            WHERE pair_id = $1
              AND symbol = $2
              AND hour_bucket > NOW() - INTERVAL '#{days} days'
          SQL

          result = DatabaseConnection.query_one(sql, [pair_id, symbol])
          return nil unless result && result[:hours_count].to_i > 0

          {
            pair_id: pair_id,
            symbol: symbol,
            days: days,
            hours_count: result[:hours_count].to_i,
            total_samples: result[:total_samples].to_i,
            avg_spread: result[:avg_spread]&.to_f,
            min_spread: result[:min_spread]&.to_f,
            max_spread: result[:max_spread]&.to_f,
            median_spread: result[:median_spread]&.to_f,
            normal_range_low: result[:p5_avg]&.to_f,
            normal_range_high: result[:p95_avg]&.to_f
          }
        rescue StandardError => e
          @logger.error("[BaselineCollector] get_baseline error: #{e.message}")
          nil
        end

        # Format baseline for alert inclusion
        # @param pair_id [String]
        # @param symbol [String]
        # @param current_spread [Float]
        # @return [String] formatted baseline section
        def format_baseline_for_alert(pair_id:, symbol:, current_spread:)
          baseline = get_baseline(pair_id: pair_id, symbol: symbol, days: 7)

          return nil unless baseline && baseline[:hours_count] >= 24  # Need at least 24 hours of data

          normal_low = baseline[:normal_range_low] || baseline[:min_spread]
          normal_high = baseline[:normal_range_high] || baseline[:max_spread]
          median = baseline[:median_spread] || baseline[:avg_spread]

          # Determine if current spread is anomaly
          is_anomaly = current_spread > normal_high * 1.5
          is_normal = current_spread <= normal_high * 1.2
          ratio = median > 0 ? (current_spread / median).round(1) : 0

          status = if is_anomaly
                     "⚠️ АНОМАЛИЯ - спред в #{ratio}x выше нормы!"
                   elsif is_normal
                     "ℹ️ В ПРЕДЕЛАХ НОРМЫ - спред может не сойтись"
                   else
                     "📈 Выше среднего (#{ratio}x)"
                   end

          lines = [
            "📊 BASELINE ЭТОЙ ПАРЫ (#{baseline[:days]}d, #{baseline[:hours_count]}h данных):",
            "   Обычный диапазон пары: #{normal_low}% - #{normal_high}%",
            "   Медиана: #{median}%",
            "   Текущий: #{current_spread.round(2)}%",
            "   #{status}"
          ]

          lines.join("\n")
        rescue StandardError => e
          @logger.debug("[BaselineCollector] format_baseline_for_alert error: #{e.message}")
          nil
        end

        private

        def current_hour_bucket
          (Time.now.to_i / 3600) * 3600
        end

        def redis_key(pair_id, symbol, hour_bucket)
          "#{REDIS_KEY_PREFIX}#{pair_id}:#{symbol}:#{hour_bucket}"
        end

        def parse_redis_key(key)
          # "spread_baseline:binance_spot:bybit_futures:FLOW:1234567890"
          parts = key.sub(REDIS_KEY_PREFIX, '').split(':')
          return [nil, nil, nil] if parts.size < 4

          # pair_id has format "exchange_type:exchange_type"
          pair_id = "#{parts[0]}:#{parts[1]}"
          symbol = parts[2]
          hour = parts[3].to_i

          [pair_id, symbol, hour]
        end

        def get_samples_from_redis(key)
          values = @redis.zrange(key, 0, -1)
          values.map do |v|
            _, spread = v.split(':')
            spread.to_f
          end.compact
        end

        def save_hourly_aggregate(pair_id, symbol, hour_timestamp, samples)
          return if samples.empty?

          sorted = samples.sort
          count = sorted.size

          stats = {
            avg: (sorted.sum / count).round(4),
            min: sorted.first.round(4),
            max: sorted.last.round(4),
            stddev: calculate_stddev(sorted).round(4),
            p50: percentile(sorted, 50).round(4),
            p95: percentile(sorted, 95).round(4)
          }

          sql = <<~SQL
            INSERT INTO spread_baseline (
              pair_id, symbol, hour_bucket, samples_count,
              avg_spread_pct, min_spread_pct, max_spread_pct,
              stddev_spread_pct, p50_spread_pct, p95_spread_pct
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (pair_id, symbol, hour_bucket) DO UPDATE SET
              samples_count = spread_baseline.samples_count + EXCLUDED.samples_count,
              avg_spread_pct = (spread_baseline.avg_spread_pct * spread_baseline.samples_count +
                               EXCLUDED.avg_spread_pct * EXCLUDED.samples_count) /
                              (spread_baseline.samples_count + EXCLUDED.samples_count),
              min_spread_pct = LEAST(spread_baseline.min_spread_pct, EXCLUDED.min_spread_pct),
              max_spread_pct = GREATEST(spread_baseline.max_spread_pct, EXCLUDED.max_spread_pct)
          SQL

          DatabaseConnection.execute(sql, [
            pair_id, symbol, Time.at(hour_timestamp),
            count, stats[:avg], stats[:min], stats[:max],
            stats[:stddev], stats[:p50], stats[:p95]
          ])
        rescue StandardError => e
          @logger.error("[BaselineCollector] save_hourly_aggregate error: #{e.message}")
        end

        def calculate_stddev(sorted)
          return 0 if sorted.size < 2

          mean = sorted.sum / sorted.size.to_f
          variance = sorted.map { |x| (x - mean)**2 }.sum / sorted.size
          Math.sqrt(variance)
        end

        def percentile(sorted, p)
          return sorted.first if sorted.size == 1

          k = (p / 100.0) * (sorted.size - 1)
          f = k.floor
          c = k.ceil

          if f == c
            sorted[f]
          else
            sorted[f] * (c - k) + sorted[c] * (k - f)
          end
        end

        def cleanup_old_data
          sql = "DELETE FROM spread_baseline WHERE hour_bucket < NOW() - INTERVAL '#{RETENTION_HOURS} hours'"
          DatabaseConnection.execute(sql)
        rescue StandardError => e
          @logger.debug("[BaselineCollector] cleanup_old_data error: #{e.message}")
        end
      end
    end
  end
end
