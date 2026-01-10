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
          max_spread_age_hours: 24,
          max_position_to_exit_ratio: 0.5,
          max_bid_ask_spread_pct: 1.0,
          require_shortable_high_venue: true
        }.freeze

        # Venue types that can be shorted
        SHORTABLE_VENUE_TYPES = %i[cex_futures perp_dex].freeze

        attr_reader :settings, :depth_history, :spread_tracker

        def initialize(settings = {})
          @settings = DEFAULT_SETTINGS.merge(settings)
          @depth_history = Trackers::DepthHistoryCollector.new
          @spread_tracker = Trackers::SpreadAgeTracker.new
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

          # 2. Position ratio check (position vs exit liquidity)
          checks << check_position_ratio(signal)

          # 3. Slippage check
          checks << check_max_slippage(signal)

          # 4. Latency check
          checks << check_latency(signal)

          # 5. Depth vs history check
          depth_check = check_depth_vs_history(signal)
          checks << depth_check
          warnings << depth_check if depth_check.passed && depth_check.value && depth_check.value < @settings[:warning_depth_ratio]

          # 6. Spread age check (how long spread has persisted)
          checks << check_spread_age(signal)

          # 7. Spread freshness check (signal creation time)
          checks << check_spread_freshness(signal)

          # 8. Bid-ask spread check
          checks << check_bid_ask_spread(signal)

          # 9. Instant exit check (can we exit profitably right now?)
          checks << check_instant_exit(signal)

          # 10. Direction validation (shortable high venue)
          checks << check_direction_validity(signal)

          # 11. Deposit/withdraw status for manual arbitrage
          signal_type = signal[:type] || signal['type']
          if signal_type == :manual || signal_type == 'manual'
            checks << check_deposit_withdraw_status(signal)
          end

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

        # Check 2: Position to exit liquidity ratio
        def check_position_ratio(signal)
          exit_liquidity = signal.dig(:liquidity, :exit_usd) || signal.dig('liquidity', 'exit_usd') || 0
          position_size = signal[:position_size_usd] || signal['position_size_usd'] || @settings[:min_position_size_usd]
          threshold = @settings[:max_position_to_exit_ratio]

          return CheckResult.new(
            passed: false,
            check_name: :position_ratio,
            message: 'No exit liquidity available',
            value: nil,
            threshold: threshold
          ) if exit_liquidity <= 0

          ratio = position_size.to_f / exit_liquidity
          passed = ratio <= threshold

          CheckResult.new(
            passed: passed,
            check_name: :position_ratio,
            message: passed ? "Position ratio OK (#{(ratio * 100).round(0)}%)" : "Position too large vs exit liquidity: #{(ratio * 100).round(0)}%",
            value: ratio,
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

        # Check 6: Spread age (how long has this spread persisted)
        def check_spread_age(signal)
          pair_id = signal[:pair_id] || signal['pair_id']
          threshold = @settings[:max_spread_age_hours]

          return CheckResult.new(
            passed: true,
            check_name: :spread_age,
            message: 'No pair ID for spread age tracking',
            value: 0,
            threshold: threshold
          ) unless pair_id

          age_hours = @spread_tracker.age_hours(pair_id)
          passed = age_hours <= threshold

          CheckResult.new(
            passed: passed,
            check_name: :spread_age,
            message: passed ? "Spread age OK (#{age_hours.round(1)}h)" : "Spread persisted too long: #{age_hours.round(1)}h",
            value: age_hours,
            threshold: threshold
          )
        end

        # Check 7: Spread data must be fresh (signal creation time)
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

        # Check 8: Bid-ask spread on individual venues
        def check_bid_ask_spread(signal)
          low_orderbook = signal[:low_orderbook] || signal['low_orderbook']
          high_orderbook = signal[:high_orderbook] || signal['high_orderbook']
          threshold = @settings[:max_bid_ask_spread_pct]

          spreads = []

          if low_orderbook
            low_spread = calculate_bid_ask_spread(low_orderbook)
            spreads << low_spread if low_spread
          end

          if high_orderbook
            high_spread = calculate_bid_ask_spread(high_orderbook)
            spreads << high_spread if high_spread
          end

          return CheckResult.new(
            passed: true,
            check_name: :bid_ask_spread,
            message: 'No orderbook data for bid-ask spread',
            value: nil,
            threshold: threshold
          ) if spreads.empty?

          max_spread = spreads.max
          passed = max_spread <= threshold

          CheckResult.new(
            passed: passed,
            check_name: :bid_ask_spread,
            message: passed ? "Bid-ask spread OK (#{max_spread.round(2)}%)" : "Bid-ask spread too wide: #{max_spread.round(2)}%",
            value: max_spread,
            threshold: threshold
          )
        end

        # Check 9: Instant exit profitability
        def check_instant_exit(signal)
          low_orderbook = signal[:low_orderbook] || signal['low_orderbook']
          high_orderbook = signal[:high_orderbook] || signal['high_orderbook']

          return CheckResult.new(
            passed: true,
            check_name: :instant_exit,
            message: 'No orderbook data for instant exit check',
            value: nil,
            threshold: nil
          ) unless low_orderbook && high_orderbook

          # Entry: buy on low asks, sell on high bids
          entry_buy = get_best_price(low_orderbook, :asks)
          entry_sell = get_best_price(high_orderbook, :bids)

          # Exit: sell on low bids, buy on high asks
          exit_sell = get_best_price(low_orderbook, :bids)
          exit_buy = get_best_price(high_orderbook, :asks)

          return CheckResult.new(
            passed: true,
            check_name: :instant_exit,
            message: 'Incomplete orderbook data',
            value: nil,
            threshold: nil
          ) unless entry_buy && entry_sell && exit_sell && exit_buy

          # Calculate PnL
          entry_pnl = entry_sell - entry_buy
          exit_pnl = exit_sell - exit_buy
          total_pnl = entry_pnl + exit_pnl
          profitable = total_pnl > 0

          CheckResult.new(
            passed: profitable,
            check_name: :instant_exit,
            message: profitable ? 'Instant exit profitable' : 'Instant exit would be unprofitable',
            value: profitable,
            threshold: true
          )
        end

        # Check 10: High venue must be shortable for valid arbitrage
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

        # Check 11: Deposit/withdraw status for manual arbitrage
        def check_deposit_withdraw_status(signal)
          low_venue = signal[:low_venue] || signal['low_venue'] || {}
          high_venue = signal[:high_venue] || signal['high_venue'] || {}
          transfer_network = signal[:transfer_network] || signal['transfer_network']

          # Get withdraw status from low venue
          low_withdraw_enabled = low_venue[:withdraw_enabled]
          low_withdraw_enabled = low_venue['withdraw_enabled'] if low_withdraw_enabled.nil?
          low_withdraw_enabled = true if low_withdraw_enabled.nil? # Default to true if unknown

          # Get deposit status from high venue
          high_deposit_enabled = high_venue[:deposit_enabled]
          high_deposit_enabled = high_venue['deposit_enabled'] if high_deposit_enabled.nil?
          high_deposit_enabled = true if high_deposit_enabled.nil? # Default to true if unknown

          passed = low_withdraw_enabled && high_deposit_enabled

          details = []
          details << "Withdraw: #{low_withdraw_enabled ? 'enabled' : 'DISABLED'}"
          details << "Deposit: #{high_deposit_enabled ? 'enabled' : 'DISABLED'}"
          details << "Network: #{transfer_network}" if transfer_network

          CheckResult.new(
            passed: passed,
            check_name: :deposit_withdraw,
            message: passed ? "Transfer OK (#{details.join(', ')})" : "Transfer blocked: #{details.join(', ')}",
            value: { withdraw: low_withdraw_enabled, deposit: high_deposit_enabled },
            threshold: { withdraw: true, deposit: true }
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

        def calculate_bid_ask_spread(orderbook)
          bids = orderbook[:bids] || orderbook['bids']
          asks = orderbook[:asks] || orderbook['asks']

          return nil unless bids&.any? && asks&.any?

          best_bid = bids.first[0].to_f
          best_ask = asks.first[0].to_f

          return nil if best_bid <= 0 || best_ask <= 0

          ((best_ask - best_bid) / best_bid * 100).abs
        end

        def get_best_price(orderbook, side)
          levels = orderbook[side] || orderbook[side.to_s]
          return nil unless levels&.any?

          levels.first[0].to_f
        end
      end
    end
  end
end
