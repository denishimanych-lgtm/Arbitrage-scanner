# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Determines check intervals based on signal age
      # More frequent checks for new signals, less frequent for old ones
      class AdaptiveTrackingScheduler
        # Intervals in seconds based on signal age
        # Format: age_range => check_interval_seconds
        INTERVALS = [
          { max_age: 5 * 60, interval: 5 },          # 0-5min: every 5 seconds
          { max_age: 30 * 60, interval: 30 },        # 5-30min: every 30 seconds
          { max_age: 2 * 3600, interval: 60 },       # 30min-2h: every 60 seconds
          { max_age: 24 * 3600, interval: 5 * 60 },  # 2h-24h: every 5 minutes
          { max_age: Float::INFINITY, interval: 15 * 60 } # >24h: every 15 minutes
        ].freeze

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Get the appropriate check interval for a signal's age
        # @param age_seconds [Integer] signal age in seconds
        # @return [Integer] interval in seconds
        def interval_for_age(age_seconds)
          INTERVALS.find { |i| age_seconds < i[:max_age] }&.dig(:interval) || 900
        end

        # Check if a signal is due for a check
        # @param record [Hash] tracking record with :started_at, :last_checked_at
        # @return [Boolean] true if check should happen now
        def due_for_check?(record)
          started_at = parse_time(record[:started_at])
          last_checked_at = parse_time(record[:last_checked_at])

          return true unless last_checked_at # Never checked

          age_seconds = Time.now - started_at
          interval = interval_for_age(age_seconds.to_i)
          time_since_check = Time.now - last_checked_at

          time_since_check >= interval
        end

        # Get the next check time for a signal
        # @param started_at [Time] when signal tracking started
        # @param last_checked_at [Time, nil] last check time
        # @return [Time] next check time
        def next_check_time(started_at:, last_checked_at:)
          started_at = parse_time(started_at)
          last_checked_at = parse_time(last_checked_at) || Time.now

          age_seconds = Time.now - started_at
          interval = interval_for_age(age_seconds.to_i)

          last_checked_at + interval
        end

        # Get descriptive interval for logging
        # @param age_seconds [Integer]
        # @return [String] human-readable interval
        def interval_description(age_seconds)
          interval = interval_for_age(age_seconds)
          case interval
          when 5 then '5s (fast)'
          when 30 then '30s'
          when 60 then '60s'
          when 300 then '5m'
          else '15m (slow)'
          end
        end

        private

        def parse_time(value)
          return nil if value.nil?
          return value if value.is_a?(Time)

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
