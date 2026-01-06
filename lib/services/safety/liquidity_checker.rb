# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      class LiquidityChecker
        # Safety check result
        CheckResult = Struct.new(
          :passed, :check_name, :message, :value, :threshold,
          keyword_init: true
        ) do
          def failed?
            !passed
          end
        end

        # All checks result
        ValidationResult = Struct.new(
          :valid, :checks, :failed_checks, :warnings,
          keyword_init: true
        ) do
          def passed?
            valid
          end
        end

        DEFAULT_SETTINGS = {
          min_exit_liquidity_usd: 5_000,
          min_position_size_usd: 1_000,
          max_slippage_pct: 2.0,
          max_latency_ms: 5_000,
          min_depth_vs_history_ratio: 0.3,
          warning_depth_ratio: 0.5,
          max_spread_age_sec: 60,
          require_shortable_high_venue: true
        }.freeze

        # Venue types that can be shorted
        SHORTABLE_VENUE_TYPES = %i[cex_futures perp_dex].freeze

        attr_reader :settings, :depth_history

        def initialize(settings = {})
          @settings = DEFAULT_SETTINGS.merge(settings)
          @depth_history = Trackers::DepthHistoryCollector.new
          @logger = ArbitrageBot.logger
        end

        # Run all safety checks on a signal
        # @param signal [Hash] signal data from orderbook analysis
        # @return [ValidationResult]
        def validate(signal)
          checks = []
          warnings = []

          # 1. Exit liquidity check
          checks << check_exit_liquidity(signal)

          # 2. Position size check
          checks << check_min_position_size(signal)

          # 3. Slippage check
          checks << check_max_slippage(signal)

          # 4. Latency check
          checks << check_latency(signal)

          # 5. Depth vs history check
          depth_check = check_depth_vs_history(signal)
          checks << depth_check
          warnings << depth_check if depth_check.passed && depth_check.value && depth_check.value < @settings[:warning_depth_ratio]

          # 6. Spread freshness check
          checks << check_spread_freshness(signal)

          # 7. Direction validation (shortable high venue)
          checks << check_direction_validity(signal)

          failed_checks = checks.select(&:failed?)

          ValidationResult.new(
            valid: failed_checks.empty?,
            checks: checks,
            failed_checks: failed_checks,
            warnings: warnings.compact
          )
        end

        # Individual check methods

        # Check 1: Exit liquidity must be sufficient
        def check_exit_liquidity(signal)
          liquidity = signal.dig(:liquidity, :exit_usd) || signal.dig('liquidity', 'exit_usd') || 0
          threshold = @settings[:min_exit_liquidity_usd]

          CheckResult.new(
            passed: liquidity >= threshold,
            check_name: :exit_liquidity,
            message: liquidity >= threshold ? 'Exit liquidity OK' : "Exit liquidity too low: $#{liquidity.round(0)}",
            value: liquidity,
            threshold: threshold
          )
        end

        # Check 2: Position size must meet minimum
        def check_min_position_size(signal)
          position_size = signal[:position_size_usd] || signal['position_size_usd'] || 0
          threshold = @settings[:min_position_size_usd]

          CheckResult.new(
            passed: position_size >= threshold,
            check_name: :min_position_size,
            message: position_size >= threshold ? 'Position size OK' : "Position too small: $#{position_size.round(0)}",
            value: position_size,
            threshold: threshold
          )
        end

        # Check 3: Total slippage must be acceptable
        def check_max_slippage(signal)
          prices = signal[:prices] || signal['prices'] || {}
          buy_slip = prices[:buy_slippage_pct] || prices['buy_slippage_pct'] || 0
          sell_slip = prices[:sell_slippage_pct] || prices['sell_slippage_pct'] || 0
          total_slippage = buy_slip.to_f.abs + sell_slip.to_f.abs
          threshold = @settings[:max_slippage_pct]

          CheckResult.new(
            passed: total_slippage <= threshold,
            check_name: :max_slippage,
            message: total_slippage <= threshold ? 'Slippage OK' : "Total slippage too high: #{total_slippage.round(2)}%",
            value: total_slippage,
            threshold: threshold
          )
        end

        # Check 4: Data latency must be fresh
        def check_latency(signal)
          timing = signal[:timing] || signal['timing'] || {}
          max_latency = [
            timing[:low_latency_ms] || timing['low_latency_ms'] || 0,
            timing[:high_latency_ms] || timing['high_latency_ms'] || 0
          ].max
          threshold = @settings[:max_latency_ms]

          CheckResult.new(
            passed: max_latency <= threshold,
            check_name: :latency,
            message: max_latency <= threshold ? 'Latency OK' : "Data too stale: #{max_latency}ms",
            value: max_latency,
            threshold: threshold
          )
        end

        # Check 5: Current depth vs historical average
        def check_depth_vs_history(signal)
          pair_id = signal[:pair_id] || signal['pair_id']
          low_venue = signal[:low_venue] || signal['low_venue']
          high_venue = signal[:high_venue] || signal['high_venue']

          return CheckResult.new(
            passed: true,
            check_name: :depth_vs_history,
            message: 'No depth history available',
            value: nil,
            threshold: @settings[:min_depth_vs_history_ratio]
          ) unless pair_id

          # Get current depths
          low_depth = signal.dig(:liquidity, :low_bids_usd) || signal.dig('liquidity', 'low_bids_usd') || 0
          high_depth = signal.dig(:liquidity, :high_asks_usd) || signal.dig('liquidity', 'high_asks_usd') || 0

          # Get venue IDs
          low_venue_id = venue_id(low_venue)
          high_venue_id = venue_id(high_venue)

          # Check ratios for both venues
          ratios = []

          low_ratio = @depth_history.depth_vs_history_ratio(pair_id, low_venue_id, :bids, low_depth)
          ratios << low_ratio if low_ratio

          high_ratio = @depth_history.depth_vs_history_ratio(pair_id, high_venue_id, :asks, high_depth)
          ratios << high_ratio if high_ratio

          return CheckResult.new(
            passed: true,
            check_name: :depth_vs_history,
            message: 'No depth history available',
            value: nil,
            threshold: @settings[:min_depth_vs_history_ratio]
          ) if ratios.empty?

          min_ratio = ratios.min
          threshold = @settings[:min_depth_vs_history_ratio]

          CheckResult.new(
            passed: min_ratio >= threshold,
            check_name: :depth_vs_history,
            message: min_ratio >= threshold ? "Depth at #{(min_ratio * 100).round(0)}% of average" : "Depth dangerously low: #{(min_ratio * 100).round(0)}% of average",
            value: min_ratio,
            threshold: threshold
          )
        end

        # Check 6: Spread data must be fresh
        def check_spread_freshness(signal)
          created_at = signal[:created_at] || signal['created_at'] || Time.now.to_i
          age = Time.now.to_i - created_at.to_i
          threshold = @settings[:max_spread_age_sec]

          CheckResult.new(
            passed: age <= threshold,
            check_name: :spread_freshness,
            message: age <= threshold ? 'Spread data fresh' : "Spread data too old: #{age}s",
            value: age,
            threshold: threshold
          )
        end

        # Check 7: High venue must be shortable for valid arbitrage
        def check_direction_validity(signal)
          return CheckResult.new(
            passed: true,
            check_name: :direction_validity,
            message: 'Direction check disabled',
            value: nil,
            threshold: nil
          ) unless @settings[:require_shortable_high_venue]

          high_venue = signal[:high_venue] || signal['high_venue'] || {}
          venue_type = (high_venue[:type] || high_venue['type'])&.to_sym

          shortable = SHORTABLE_VENUE_TYPES.include?(venue_type)

          CheckResult.new(
            passed: shortable,
            check_name: :direction_validity,
            message: shortable ? 'High venue is shortable' : "Cannot short on #{venue_type} venue",
            value: venue_type,
            threshold: SHORTABLE_VENUE_TYPES
          )
        end

        # Get suggested position size based on liquidity
        def suggest_position_size(signal)
          exit_liquidity = signal.dig(:liquidity, :exit_usd) || signal.dig('liquidity', 'exit_usd') || 0

          # Use 50% of exit liquidity as max, with caps
          suggested = [
            exit_liquidity * 0.5,
            50_000  # Hard cap
          ].min

          # Round to nice numbers
          case suggested
          when 0...1_000 then suggested.round(-2)      # Round to nearest 100
          when 1_000...10_000 then suggested.round(-3) # Round to nearest 1000
          else suggested.round(-3)
          end.to_i
        end

        private

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
