# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      class LaggingExchangeDetector
        # Lagging detection result
        LaggingResult = Struct.new(
          :lagging, :lagging_venue, :leading_venue, :lag_ms, :confidence,
          keyword_init: true
        )

        # Price update tracking
        UpdateRecord = Struct.new(:price, :timestamp, :venue, keyword_init: true)

        DEFAULT_SETTINGS = {
          # Minimum time difference to consider lagging (ms)
          min_lag_threshold_ms: 500,
          # Maximum lag before it's suspicious (likely stale data)
          max_lag_threshold_ms: 10_000,
          # Minimum price updates to calculate lag
          min_samples: 5,
          # Window for tracking updates (seconds)
          tracking_window_sec: 60,
          # Correlation threshold for detecting lag pattern
          min_correlation: 0.7
        }.freeze

        KEY_PREFIX = 'lagging:updates:'

        attr_reader :settings, :redis

        def initialize(settings = {})
          @settings = DEFAULT_SETTINGS.merge(settings)
          @redis = ArbitrageBot.redis
          @logger = ArbitrageBot.logger
        end

        # Record a price update for lag detection
        # @param symbol [String] normalized symbol
        # @param venue_id [String] venue identifier
        # @param price [Float] current price
        # @param timestamp [Integer] update timestamp in ms
        def record_update(symbol, venue_id, price, timestamp = nil)
          timestamp ||= (Time.now.to_f * 1000).to_i
          key = update_key(symbol, venue_id)

          record = {
            price: price.to_f,
            timestamp: timestamp,
            venue: venue_id
          }.to_json

          @redis.lpush(key, record)
          @redis.ltrim(key, 0, 99) # Keep last 100 updates
          @redis.expire(key, @settings[:tracking_window_sec] * 2)
        end

        # Detect if one venue is lagging behind another
        # @param symbol [String] normalized symbol
        # @param venue1_id [String] first venue
        # @param venue2_id [String] second venue
        # @return [LaggingResult]
        def detect(symbol, venue1_id, venue2_id)
          updates1 = get_recent_updates(symbol, venue1_id)
          updates2 = get_recent_updates(symbol, venue2_id)

          # Need minimum samples
          if updates1.size < @settings[:min_samples] || updates2.size < @settings[:min_samples]
            return LaggingResult.new(
              lagging: false,
              lagging_venue: nil,
              leading_venue: nil,
              lag_ms: 0,
              confidence: 0.0
            )
          end

          # Calculate average update frequency
          freq1 = calculate_update_frequency(updates1)
          freq2 = calculate_update_frequency(updates2)

          # Calculate lag by comparing price movements
          lag_result = calculate_lag(updates1, updates2)

          # Determine which is lagging
          if lag_result[:lag_ms].abs >= @settings[:min_lag_threshold_ms] &&
             lag_result[:lag_ms].abs <= @settings[:max_lag_threshold_ms] &&
             lag_result[:confidence] >= @settings[:min_correlation]

            if lag_result[:lag_ms] > 0
              # Venue2 is lagging behind venue1
              LaggingResult.new(
                lagging: true,
                lagging_venue: venue2_id,
                leading_venue: venue1_id,
                lag_ms: lag_result[:lag_ms],
                confidence: lag_result[:confidence]
              )
            else
              # Venue1 is lagging behind venue2
              LaggingResult.new(
                lagging: true,
                lagging_venue: venue1_id,
                leading_venue: venue2_id,
                lag_ms: lag_result[:lag_ms].abs,
                confidence: lag_result[:confidence]
              )
            end
          else
            LaggingResult.new(
              lagging: false,
              lagging_venue: nil,
              leading_venue: nil,
              lag_ms: 0,
              confidence: lag_result[:confidence]
            )
          end
        end

        # Detect lagging for a signal
        # @param signal [Hash] signal with low_venue and high_venue
        # @return [LaggingResult]
        def detect_for_signal(signal)
          symbol = signal[:symbol] || signal['symbol']
          low_venue = signal[:low_venue] || signal['low_venue']
          high_venue = signal[:high_venue] || signal['high_venue']

          low_venue_id = venue_id(low_venue)
          high_venue_id = venue_id(high_venue)

          detect(symbol, low_venue_id, high_venue_id)
        end

        private

        def update_key(symbol, venue_id)
          "#{KEY_PREFIX}#{symbol}:#{venue_id}"
        end

        def get_recent_updates(symbol, venue_id)
          key = update_key(symbol, venue_id)
          records = @redis.lrange(key, 0, -1)

          cutoff = (Time.now.to_f * 1000).to_i - (@settings[:tracking_window_sec] * 1000)

          records.map { |r| JSON.parse(r) }
                 .select { |r| r['timestamp'] >= cutoff }
                 .sort_by { |r| r['timestamp'] }
        end

        def calculate_update_frequency(updates)
          return 0 if updates.size < 2

          time_span = updates.last['timestamp'] - updates.first['timestamp']
          return 0 if time_span == 0

          (updates.size - 1) / (time_span / 1000.0) # Updates per second
        end

        def calculate_lag(updates1, updates2)
          # Find price changes in both venues
          changes1 = price_changes(updates1)
          changes2 = price_changes(updates2)

          return { lag_ms: 0, confidence: 0.0 } if changes1.empty? || changes2.empty?

          # Try different lag offsets and find best correlation
          best_lag = 0
          best_correlation = 0.0

          # Test lags from -5s to +5s in 100ms increments
          (-5000..5000).step(100).each do |lag_offset|
            correlation = calculate_correlation(changes1, changes2, lag_offset)
            if correlation > best_correlation
              best_correlation = correlation
              best_lag = lag_offset
            end
          end

          { lag_ms: best_lag, confidence: best_correlation }
        end

        def price_changes(updates)
          changes = []
          updates.each_cons(2) do |prev, curr|
            pct_change = (curr['price'] - prev['price']) / prev['price'] * 100
            changes << {
              timestamp: curr['timestamp'],
              change: pct_change
            }
          end
          changes
        end

        def calculate_correlation(changes1, changes2, lag_offset)
          # Match changes by timestamp with lag offset
          matched = []

          changes1.each do |c1|
            target_time = c1[:timestamp] + lag_offset
            # Find closest change in changes2
            closest = changes2.min_by { |c2| (c2[:timestamp] - target_time).abs }
            next unless closest

            time_diff = (closest[:timestamp] - target_time).abs
            # Only match if within 200ms
            matched << [c1[:change], closest[:change]] if time_diff < 200
          end

          return 0.0 if matched.size < 3

          # Calculate Pearson correlation
          pearson_correlation(matched.map(&:first), matched.map(&:last))
        end

        def pearson_correlation(x, y)
          return 0.0 if x.empty? || y.empty? || x.size != y.size

          n = x.size
          sum_x = x.sum
          sum_y = y.sum
          sum_xy = x.zip(y).map { |a, b| a * b }.sum
          sum_x2 = x.map { |v| v**2 }.sum
          sum_y2 = y.map { |v| v**2 }.sum

          numerator = n * sum_xy - sum_x * sum_y
          denominator = Math.sqrt((n * sum_x2 - sum_x**2) * (n * sum_y2 - sum_y**2))

          return 0.0 if denominator == 0

          (numerator / denominator).abs
        end

        def venue_id(venue)
          return 'unknown' unless venue

          type = (venue[:type] || venue['type'])&.to_sym
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          case type
          when :cex_futures, :cex_spot
            "#{exchange}_#{type}"
          when :perp_dex, :dex_spot
            "#{dex}_#{type}"
          else
            'unknown'
          end
        end
      end
    end
  end
end
