# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Trackers
      class TimingData
        attr_reader :low_venue, :high_venue

        MAX_LATENCY_DIFF_MS = 2000 # Maximum acceptable latency difference
        MAX_LATENCY_MS = 5000      # Maximum acceptable single latency

        def initialize(low_orderbook, high_orderbook)
          @low_venue = extract_timing(low_orderbook)
          @high_venue = extract_timing(high_orderbook)
        end

        # Difference in response times between venues
        def latency_diff_ms
          return 0 unless @low_venue && @high_venue

          ((@low_venue[:response_at] - @high_venue[:response_at]).abs * 1000).round
        end

        # Maximum latency of the two venues
        def max_latency_ms
          latencies = []
          latencies << @low_venue[:latency_ms] if @low_venue
          latencies << @high_venue[:latency_ms] if @high_venue

          latencies.max || 0
        end

        # Total round-trip latency
        def total_latency_ms
          latencies = []
          latencies << @low_venue[:latency_ms] if @low_venue
          latencies << @high_venue[:latency_ms] if @high_venue

          latencies.sum
        end

        # Check if data is fresh enough
        def data_fresh?(max_allowed_ms = MAX_LATENCY_DIFF_MS)
          latency_diff_ms < max_allowed_ms && max_latency_ms < MAX_LATENCY_MS
        end

        # Get staleness score (higher = more stale)
        def staleness_score
          diff_score = [latency_diff_ms / MAX_LATENCY_DIFF_MS.to_f, 1.0].min
          max_score = [max_latency_ms / MAX_LATENCY_MS.to_f, 1.0].min

          (diff_score + max_score) / 2.0
        end

        # Get timing summary
        def to_h
          {
            low_venue: @low_venue,
            high_venue: @high_venue,
            latency_diff_ms: latency_diff_ms,
            max_latency_ms: max_latency_ms,
            total_latency_ms: total_latency_ms,
            data_fresh: data_fresh?,
            staleness_score: staleness_score.round(4)
          }
        end

        private

        def extract_timing(orderbook)
          return nil unless orderbook

          timing = orderbook[:timing] || orderbook.timing rescue nil

          if timing.respond_to?(:to_h)
            timing.to_h
          elsif timing.is_a?(Hash)
            timing
          else
            nil
          end
        end
      end
    end
  end
end
