# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      # Accumulates signals for digest mode (15-minute windows)
      # Groups by symbol and tracks best pairs per category
      class DigestAccumulator
        REDIS_KEY_PREFIX = 'digest:accumulated:'
        DIGEST_WINDOW_SECONDS = 900 # 15 minutes
        SIGNAL_TTL = 1800 # 30 minutes (2x window for safety)

        # Pair type categories
        CATEGORIES = {
          sf: 'Spot↔Futures',      # CEX Spot ↔ CEX Futures (hedge)
          ff: 'Futures↔Futures',   # CEX Futures ↔ CEX Futures
          ss: 'Spot↔Spot',         # CEX Spot ↔ CEX Spot (needs transfer)
          ds: 'DEX→Spot',          # DEX ↔ CEX Spot (needs deposit on CEX)
          df: 'DEX→Futures',       # DEX ↔ CEX Futures
          ps: 'PerpDEX→Spot',      # PerpDEX ↔ CEX Spot
          pf: 'PerpDEX↔Futures',   # PerpDEX ↔ CEX Futures
          pp: 'PerpDEX↔PerpDEX'    # PerpDEX ↔ PerpDEX
        }.freeze

        def initialize
          @logger = ArbitrageBot.logger
          # Don't cache @redis - use ArbitrageBot.redis directly for thread-safety
          @transfer_checker = Safety::DepositWithdrawChecker.new
        end

        # Add a signal to the accumulator
        # @param signal [Hash] validated signal data
        # @param skip_transfer_check [Boolean] skip slow transfer API calls (for fast path)
        # @return [Boolean] success
        def add(signal, skip_transfer_check: false)
          symbol = signal[:symbol] || signal['symbol']
          return false unless symbol

          window_key = current_window_key
          category = determine_category(signal)

          # Build signal entry with all needed data
          entry = build_entry(signal, category, skip_transfer_check: skip_transfer_check)

          # Store in Redis hash: window_key -> { "SYMBOL:category" => entry_json }
          field = "#{symbol}:#{category}"

          # Only keep if better spread than existing
          redis = ArbitrageBot.redis
          existing = redis.hget(window_key, field)
          if existing
            existing_data = JSON.parse(existing, symbolize_names: true)
            existing_spread = existing_data[:spread_pct].to_f
            new_spread = entry[:spread_pct].to_f

            return false if new_spread <= existing_spread
          end

          redis.hset(window_key, field, entry.to_json)
          redis.expire(window_key, SIGNAL_TTL)

          # Only log at debug level for fast path
          @logger.debug("[DigestAccumulator] Added #{symbol}:#{category} @ #{entry[:spread_pct]}%")
          true
        rescue StandardError => e
          @logger.error("[DigestAccumulator] add error: #{e.class}: #{e.message}")
          false
        end

        # Get all accumulated signals for current window
        # @return [Hash] { symbol => { category => signal_data } }
        def get_current_window
          get_window(current_window_key)
        end

        # Get signals from previous window (for sending digest)
        # @return [Hash] { symbol => { category => signal_data } }
        def get_previous_window
          prev_key = previous_window_key
          data = get_window(prev_key)

          # Clear previous window after reading
          ArbitrageBot.redis.del(prev_key) if data.any?

          data
        end

        # Get window data by key
        # @return [Hash] { symbol => { category => signal_data } }
        def get_window(window_key)
          raw = ArbitrageBot.redis.hgetall(window_key)
          return {} if raw.empty?

          result = {}
          raw.each do |field, json|
            symbol, category = field.split(':')
            category = category.to_sym

            result[symbol] ||= {}
            result[symbol][category] = JSON.parse(json, symbolize_names: true)
          end

          result
        end

        # Check if previous window has signals ready for digest
        # @return [Boolean]
        def digest_ready?
          prev_key = previous_window_key
          ArbitrageBot.redis.hlen(prev_key) > 0
        end

        # Get count of signals in current window
        # @return [Integer]
        def current_count
          ArbitrageBot.redis.hlen(current_window_key)
        end

        # Get unique symbols in current window
        # @return [Array<String>]
        def current_symbols
          raw = ArbitrageBot.redis.hkeys(current_window_key)
          raw.map { |f| f.split(':').first }.uniq
        end

        private

        def current_window_key
          window_id = (Time.now.to_i / DIGEST_WINDOW_SECONDS) * DIGEST_WINDOW_SECONDS
          "#{REDIS_KEY_PREFIX}#{window_id}"
        end

        def previous_window_key
          window_id = ((Time.now.to_i / DIGEST_WINDOW_SECONDS) - 1) * DIGEST_WINDOW_SECONDS
          "#{REDIS_KEY_PREFIX}#{window_id}"
        end

        # Determine pair category based on venue types
        def determine_category(signal)
          low_venue = signal[:low_venue] || signal['low_venue'] || {}
          high_venue = signal[:high_venue] || signal['high_venue'] || {}

          low_type = normalize_venue_type(low_venue)
          high_type = normalize_venue_type(high_venue)

          # Sort alphabetically for consistent categorization
          types = [low_type, high_type].sort

          case types
          when %w[cex_futures cex_spot]
            :sf
          when %w[cex_futures cex_futures]
            :ff
          when %w[cex_spot cex_spot]
            :ss
          when %w[cex_spot dex_spot]
            :ds
          when %w[cex_futures dex_spot]
            :df
          when %w[cex_spot perp_dex]
            :ps
          when %w[cex_futures perp_dex]
            :pf
          when %w[perp_dex perp_dex]
            :pp
          else
            :unknown
          end
        end

        def normalize_venue_type(venue)
          type = (venue[:type] || venue['type']).to_s.downcase

          return 'cex_spot' if type.include?('spot') && !type.include?('dex')
          return 'cex_futures' if type.include?('futures') || type.include?('perp')
          return 'dex_spot' if type.include?('dex') && !type.include?('perp')
          return 'perp_dex' if type.include?('perp') && type.include?('dex')

          type
        end

        def build_entry(signal, category, skip_transfer_check: false)
          low_venue = signal[:low_venue] || signal['low_venue'] || {}
          high_venue = signal[:high_venue] || signal['high_venue'] || {}
          spread = signal[:spread] || signal['spread'] || {}
          liquidity = signal[:liquidity] || signal['liquidity'] || {}
          prices = signal[:prices] || signal['prices'] || {}

          # Check transfer availability for categories that need it
          # Skip for fast path (will be checked when sending digest)
          transfer_ok = skip_transfer_check ? nil : check_transfer_availability(signal, category)

          {
            symbol: signal[:symbol] || signal['symbol'],
            pair_id: signal[:pair_id] || signal['pair_id'],
            category: category,
            spread_pct: (spread[:real_pct] || spread['real_pct']).to_f.round(2),
            net_spread_pct: (spread[:net_pct] || spread['net_pct']).to_f.round(2),
            low_venue: {
              exchange: low_venue[:exchange] || low_venue['exchange'],
              type: low_venue[:type] || low_venue['type']
            },
            high_venue: {
              exchange: high_venue[:exchange] || high_venue['exchange'],
              type: high_venue[:type] || high_venue['type']
            },
            buy_price: (prices[:buy_price] || prices['buy_price']).to_f,
            sell_price: (prices[:sell_price] || prices['sell_price']).to_f,
            liquidity_usd: calculate_min_liquidity(liquidity),
            transfer_available: transfer_ok,
            timestamp: Time.now.to_i
          }
        end

        # Check if transfers are available for this pair
        def check_transfer_availability(signal, category)
          # Categories that don't need transfer check
          return true if %i[sf ff df pf pp].include?(category)

          symbol = signal[:symbol] || signal['symbol']
          low_venue = signal[:low_venue] || signal['low_venue'] || {}
          high_venue = signal[:high_venue] || signal['high_venue'] || {}

          case category
          when :ss
            # Spot-Spot: need withdraw from buy exchange, deposit to sell exchange
            buy_ex = low_venue[:exchange] || low_venue['exchange']
            sell_ex = high_venue[:exchange] || high_venue['exchange']

            validation = @transfer_checker.validate_transfer_route(symbol, buy_ex, sell_ex)
            validation[:valid]

          when :ds
            # DEX-Spot: need deposit on CEX (DEX always allows sending)
            cex_venue = [low_venue, high_venue].find { |v|
              t = (v[:type] || v['type']).to_s
              t.include?('spot') && !t.include?('dex')
            }
            return true unless cex_venue

            cex_ex = cex_venue[:exchange] || cex_venue['exchange']
            status = @transfer_checker.check_status(symbol, cex_ex)
            status[:deposit_enabled] == true

          when :ps
            # PerpDEX-Spot: need deposit on CEX spot
            cex_venue = [low_venue, high_venue].find { |v|
              t = (v[:type] || v['type']).to_s
              t.include?('spot') && !t.include?('dex') && !t.include?('perp')
            }
            return true unless cex_venue

            cex_ex = cex_venue[:exchange] || cex_venue['exchange']
            status = @transfer_checker.check_status(symbol, cex_ex)
            status[:deposit_enabled] == true

          else
            true
          end
        rescue StandardError => e
          @logger.debug("[DigestAccumulator] transfer check error: #{e.message}")
          nil # Unknown status
        end

        def calculate_min_liquidity(liquidity)
          exit_usd = (liquidity[:exit_usd] || liquidity['exit_usd']).to_f
          max_entry = (liquidity[:max_entry_usd] || liquidity['max_entry_usd']).to_f

          [exit_usd, max_entry].select { |v| v > 0 }.min || 0
        end

        def log(message)
          @logger.debug("[DigestAccumulator] #{message}")
        end
      end
    end
  end
end
