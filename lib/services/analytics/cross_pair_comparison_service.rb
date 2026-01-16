# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Fetches and formats cross-pair comparison data for alerts
      # Shows all other pairs for the same symbol with current spreads
      class CrossPairComparisonService
        MAX_PAIRS_TO_SHOW = 5

        def initialize
          @logger = ArbitrageBot.logger
          @redis = Redis.new(
            url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
            connect_timeout: 5,
            read_timeout: 5
          )
          @min_dex_liquidity = reload_min_dex_liquidity
          @spread_history_tracker = SpreadHistoryTracker.new
          @transfer_checker = Safety::DepositWithdrawChecker.new
        end

        # Reload min_dex_liquidity from Redis
        def reload_min_dex_liquidity
          stored = @redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_dex_liquidity_usd')
          stored ? stored.to_i : 1000
        rescue StandardError
          1000
        end

        # Get all current spreads for a symbol across all pairs
        # @param symbol [String] e.g. "FLOW"
        # @param exclude_pair_id [String, nil] pair to exclude (current alert pair)
        # @return [Array<Hash>] sorted by spread descending
        def all_spreads_for_symbol(symbol:, exclude_pair_id: nil)
          spreads = fetch_current_spreads(symbol)

          # Exclude current pair if specified (check both directions)
          if exclude_pair_id
            flipped = flip_pair_id(exclude_pair_id)
            spreads = spreads.reject { |s| s[:pair_id] == exclude_pair_id || s[:pair_id] == flipped }
          end

          # Deduplicate by normalized pair_id (keep highest spread)
          unique_spreads = {}
          spreads.each do |s|
            normalized = normalize_pair_id(s[:pair_id])
            if !unique_spreads[normalized] || s[:spread_pct] > unique_spreads[normalized][:spread_pct]
              unique_spreads[normalized] = s
            end
          end

          # Sort by spread descending (highest opportunity first)
          unique_spreads.values.sort_by { |s| -s[:spread_pct] }
        end

        # Normalize pair_id so a:b and b:a are the same
        def normalize_pair_id(pair_id)
          parts = pair_id.to_s.split(':').sort
          parts.join(':')
        end

        # Format cross-pair comparison for alert inclusion
        # Shows current spread + 24h statistics for each pair
        # @param symbol [String]
        # @param current_pair_id [String]
        # @param current_spread [Float]
        # @return [String, nil] formatted section or nil if no other pairs
        def format_for_alert(symbol:, current_pair_id:, current_spread:)
          other_pairs = all_spreads_for_symbol(
            symbol: symbol,
            exclude_pair_id: current_pair_id
          )

          return nil if other_pairs.empty?

          # Take top N pairs
          top_pairs = other_pairs.first(MAX_PAIRS_TO_SHOW)

          lines = ["🔄 #{symbol} НА ДРУГИХ ПАРАХ:"]
          lines << ""

          top_pairs.each do |pair|
            pair_display = format_pair_display(pair[:pair_id])
            spread_str = format_spread(pair[:spread_pct])

            # Mark if this pair has higher spread than current
            indicator = pair[:spread_pct].abs > current_spread.abs ? ' ⭐️' : ''

            lines << "   #{pair_display}#{indicator}"
            lines << "   • Сейчас: #{spread_str}"

            # Try to get spread history (from Redis tracker)
            history_24h = @spread_history_tracker.stats_24h(pair[:pair_id], symbol)
            history_7d = @spread_history_tracker.stats_7d(pair[:pair_id], symbol)

            # Fall back to spread_convergence table if no Redis history
            stats_24h = history_24h || get_pair_stats_24h(pair[:pair_id], symbol)
            stats_7d_conv = get_pair_stats_7d(pair[:pair_id], symbol)

            # Show 24h stats (prefer Redis history for min/max)
            if history_24h
              max_24h = history_24h[:max_spread]&.round(1) || '?'
              min_24h = history_24h[:min_spread]&.round(1) || '?'
              lines << "   • 24ч: Max #{max_24h}% | Min #{min_24h}%"
            elsif stats_24h
              max_24h = stats_24h[:max_spread]&.round(1) || '?'
              min_24h = stats_24h[:min_spread]&.round(1) || '?'
              lines << "   • 24ч: Max #{max_24h}% | Min #{min_24h}%"
            end

            # Show 7d stats from Redis history if available
            if history_7d
              max_7d = history_7d[:max_spread]&.round(1) || '?'
              min_7d = history_7d[:min_spread]&.round(1) || '?'
              samples = history_7d[:sample_count] || 0
              lines << "   • 7д: Max #{max_7d}% | Min #{min_7d}% (#{samples} замеров)"
            end

            # Add 7d convergence info (from alerts)
            if stats_7d_conv && stats_7d_conv[:signal_count] > 0
              conv = stats_7d_conv[:converged_count]
              total = stats_7d_conv[:signal_count]
              if conv > 0
                lines << "   • Алерты 7д: сходился #{conv}/#{total} раз"
              else
                lines << "   • Алерты 7д: #{total} сигналов, ни один не сошёлся"
              end
            end

            # Add transfer status for spot-spot pairs
            transfer_line = format_transfer_status_short(pair, symbol)
            lines << transfer_line if transfer_line

            lines << ""
          end

          # Remove trailing empty line
          lines.pop if lines.last == ""

          lines.join("\n")
        rescue StandardError => e
          @logger.error("[CrossPairComparison] format_for_alert error: #{e.message}")
          nil
        end

        # Get 24h statistics for a pair from spread_convergence table
        # @param pair_id [String]
        # @param symbol [String]
        # @return [Hash, nil] statistics or nil
        def get_pair_stats_24h(pair_id, symbol)
          sql = <<~SQL
            SELECT
              MAX(initial_spread_pct) as max_spread,
              MIN(min_spread_pct) as min_spread,
              COUNT(*) as signal_count,
              COUNT(*) FILTER (WHERE converged = true) as converged_count
            FROM spread_convergence
            WHERE pair_id = $1
              AND symbol = $2
              AND started_at > NOW() - INTERVAL '24 hours'
          SQL

          result = DatabaseConnection.query_one(sql, [pair_id, symbol])
          return nil unless result && result[:signal_count].to_i > 0

          {
            max_spread: result[:max_spread]&.to_f,
            min_spread: result[:min_spread]&.to_f,
            signal_count: result[:signal_count].to_i,
            converged_count: result[:converged_count].to_i
          }
        rescue StandardError => e
          @logger.debug("[CrossPairComparison] get_pair_stats_24h error: #{e.message}")
          nil
        end

        # Get 7d statistics for a pair from spread_convergence table
        # @param pair_id [String]
        # @param symbol [String]
        # @return [Hash, nil] statistics or nil
        def get_pair_stats_7d(pair_id, symbol)
          sql = <<~SQL
            SELECT
              MAX(initial_spread_pct) as max_spread,
              MIN(min_spread_pct) as min_spread,
              COUNT(*) as signal_count,
              COUNT(*) FILTER (WHERE converged = true) as converged_count
            FROM spread_convergence
            WHERE pair_id = $1
              AND symbol = $2
              AND started_at > NOW() - INTERVAL '7 days'
          SQL

          result = DatabaseConnection.query_one(sql, [pair_id, symbol])
          return nil unless result && result[:signal_count].to_i > 0

          {
            max_spread: result[:max_spread]&.to_f,
            min_spread: result[:min_spread]&.to_f,
            signal_count: result[:signal_count].to_i,
            converged_count: result[:converged_count].to_i
          }
        rescue StandardError => e
          @logger.debug("[CrossPairComparison] get_pair_stats_7d error: #{e.message}")
          nil
        end

        private

        # Fetch current spreads from Redis cache
        # @param symbol [String]
        # @return [Array<Hash>]
        def fetch_current_spreads(symbol)
          # Reload min DEX liquidity for real-time changes
          @min_dex_liquidity = reload_min_dex_liquidity

          spreads_json = @redis.get('spreads:latest')
          return [] unless spreads_json

          spreads = JSON.parse(spreads_json)

          # Filter by symbol
          symbol_spreads = spreads.select do |s|
            s_symbol = s['symbol'] || s[:symbol]
            s_symbol&.upcase == symbol.upcase
          end

          # Convert to standard format, normalize negative spreads
          symbol_spreads.map do |s|
            spread_pct = (s['spread_pct'] || s[:spread_pct]).to_f
            pair_id = s['pair_id'] || s[:pair_id]
            low_venue = s['low_venue'] || s[:low_venue] || {}
            high_venue = s['high_venue'] || s[:high_venue] || {}

            # If spread is negative, flip the direction
            if spread_pct < 0
              spread_pct = spread_pct.abs
              pair_id = flip_pair_id(pair_id)
              low_venue, high_venue = high_venue, low_venue
            end

            # Only include spreads > 0.5%
            next nil if spread_pct < 0.5

            # Filter out low liquidity DEX pairs
            low_type = (low_venue['type'] || low_venue[:type]).to_s
            high_type = (high_venue['type'] || high_venue[:type]).to_s
            dex_types = %w[dex_spot perp_dex]

            if dex_types.include?(low_type)
              low_liq = (low_venue['liquidity_usd'] || low_venue[:liquidity_usd]).to_f rescue 0
              next nil if low_liq > 0 && low_liq < @min_dex_liquidity
            end

            if dex_types.include?(high_type)
              high_liq = (high_venue['liquidity_usd'] || high_venue[:liquidity_usd]).to_f rescue 0
              next nil if high_liq > 0 && high_liq < @min_dex_liquidity
            end

            {
              pair_id: pair_id,
              symbol: s['symbol'] || s[:symbol],
              spread_pct: spread_pct,
              buy_venue: low_venue,
              sell_venue: high_venue
            }
          end.compact
        rescue StandardError => e
          @logger.error("[CrossPairComparison] fetch_current_spreads error: #{e.message}")
          []
        end

        # Flip pair_id direction: "a:b" -> "b:a"
        def flip_pair_id(pair_id)
          parts = pair_id.to_s.split(':')
          return pair_id if parts.size != 2
          "#{parts[1]}:#{parts[0]}"
        end

        # Format spread percentage for display
        def format_spread(spread_pct)
          "#{spread_pct.round(2)}%"
        end

        # Format pair_id for human-readable display
        # "binance_spot:bybit_futures" -> "BINA-S→BYBI-F"
        def format_pair_display(pair_id)
          return pair_id unless pair_id.include?(':')

          parts = pair_id.split(':')
          return pair_id if parts.size != 2

          low = format_venue_short(parts[0])
          high = format_venue_short(parts[1])

          "#{low}→#{high}"
        end

        # Format venue to readable form with market type
        # "binance_spot" -> "Binance-Spot"
        # "bybit_futures" -> "Bybit-Fut"
        def format_venue_short(venue_key)
          exchange = venue_key.gsub(/_spot$|_futures$|_perp$|_dex$/, '').capitalize

          suffix = if venue_key.end_with?('_futures')
                     '-Fut'
                   elsif venue_key.end_with?('_spot')
                     '-Spot'
                   elsif venue_key.end_with?('_perp')
                     '-Perp'
                   else
                     '-DEX'
                   end

          "#{exchange}#{suffix}"
        end

        # Format transfer status for spot-spot pairs (compact one-line format)
        # @param pair [Hash] pair data with :buy_venue, :sell_venue
        # @param symbol [String] trading symbol
        # @return [String, nil] formatted line or nil if not spot-spot
        def format_transfer_status_short(pair, symbol)
          buy_venue = pair[:buy_venue] || {}
          sell_venue = pair[:sell_venue] || {}

          # Check if it's spot-spot pair
          buy_type = (buy_venue['type'] || buy_venue[:type]).to_s
          sell_type = (sell_venue['type'] || sell_venue[:type]).to_s

          return nil unless buy_type.include?('spot') && sell_type.include?('spot')

          # Get exchange names
          buy_ex = buy_venue['exchange'] || buy_venue[:exchange] || buy_venue['dex'] || buy_venue[:dex]
          sell_ex = sell_venue['exchange'] || sell_venue[:exchange] || sell_venue['dex'] || sell_venue[:dex]

          return nil unless buy_ex && sell_ex

          # Check transfer status
          begin
            validation = @transfer_checker.validate_transfer_route(symbol, buy_ex.to_s, sell_ex.to_s)

            withdraw = format_status_icon(validation[:buy_withdraw_enabled])
            deposit = format_status_icon(validation[:sell_deposit_enabled])

            status_icon = validation[:valid] ? '✅' : (validation[:valid] == false ? '⚠️' : '❓')

            "   • Перевод: #{status_icon} W:#{withdraw} D:#{deposit}"
          rescue StandardError => e
            @logger.debug("[CrossPairComparison] format_transfer_status_short error: #{e.message}")
            nil
          end
        end

        # Format status as icon
        def format_status_icon(enabled)
          case enabled
          when true then '✅'
          when false then '❌'
          else '❓'
          end
        end
      end
    end
  end
end
