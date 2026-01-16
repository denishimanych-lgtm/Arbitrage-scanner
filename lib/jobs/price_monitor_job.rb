# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class PriceMonitorJob
      PRICE_CACHE_KEY = 'prices:latest'
      SPREAD_CACHE_KEY = 'spreads:latest'
      PRICE_TTL = 120 # seconds (long enough for ConvergenceCheckJob to read)
      # Max age for price staleness - needs to account for full fetch cycle time
      # which can take 15-30 seconds across all exchanges
      DEFAULT_MAX_PRICE_AGE_MS = 60_000 # 60 seconds - filter truly stale data only

      attr_reader :logger

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        # Use ArbitrageBot.redis directly (thread-local)
        @settings = settings
        @min_spread_pct = settings[:min_spread_pct] || 1.0
        @max_price_age_ms = (settings[:max_price_age_ms] || DEFAULT_MAX_PRICE_AGE_MS).to_i

        @cex_fetcher = Services::PriceFetcher::CexPriceFetcher.new
        @dex_fetcher = Services::PriceFetcher::DexPriceFetcher.new(@settings)
        @dex_bulk_fetcher = Services::PriceFetcher::DexBulkPriceFetcher.new
        @perp_dex_fetcher = Services::PriceFetcher::PerpDexPriceFetcher.new
        @ticker_storage = Storage::TickerStorage.new
        @baseline_collector = Services::Analytics::SpreadBaselineCollector.new
        @spread_history_tracker = Services::Analytics::SpreadHistoryTracker.new
        @stale_count = 0
      end

      # Run single price collection cycle
      def perform
        log('Starting price collection...')
        start_time = Time.now

        # Get all tracked symbols
        log('Fetching symbols from storage...')
        symbols = @ticker_storage.all_symbols
        log("Got #{symbols.size} symbols")

        return if symbols.empty?

        # Fetch prices from all sources in parallel
        log('Fetching CEX prices...')
        all_prices = fetch_all_prices(symbols)
        log("Fetched #{all_prices.size} prices")

        # Cache prices
        log('Caching prices...')
        cache_prices(all_prices)
        log('Prices cached')

        # Calculate spreads for all arbitrage pairs
        log('Calculating spreads...')
        spreads = calculate_spreads(symbols, all_prices)
        log("Calculated #{spreads.size} spreads")

        # Record baseline statistics (background spread data)
        record_baseline_samples(spreads)

        # Cache spreads
        cache_spreads(spreads)

        # Record spread history for tracked pairs
        @spread_history_tracker.record(spreads)

        # Trigger orderbook analysis for high spreads
        trigger_analysis(spreads)

        elapsed = ((Time.now - start_time) * 1000).round
        log("Price collection complete: #{all_prices.size} prices, #{spreads.size} spreads (#{elapsed}ms)")
      end

      # Run continuous monitoring loop
      def run_loop(interval: 1)
        log("Starting price monitor loop (interval: #{interval}s)")

        loop do
          begin
            perform
          rescue StandardError => e
            @logger.error("Price monitor error: #{e.message}")
          end

          sleep interval
        end
      end

      private

      def log(message)
        @logger.info("[PriceMonitor] #{message}")
      end

      def fetch_all_prices(symbols)
        prices = {}
        @stale_count = 0

        # Fetch CEX prices
        begin
          cex_prices = @cex_fetcher.fetch_all_exchanges
          cex_prices.each do |exchange, exchange_prices|
            exchange_prices.each do |symbol, data|
              base = extract_base_symbol(symbol)
              key = "#{exchange}:#{base}"

              # Check staleness before adding
              if price_is_fresh?(data)
                prices[key] = data
              else
                @stale_count += 1
                @logger.debug("Stale price from #{key}: age > #{@max_price_age_ms}ms")
              end
            end
          end
        rescue StandardError => e
          @logger.error("CEX price fetch error: #{e.message}")
          @logger.error("Backtrace: #{e.backtrace.first(5).join(' | ')}")
        end

        # Fetch DEX prices using bulk DexScreener API (with timeout)
        begin
          log('Fetching DEX prices (bulk)...')
          dex_prices = Timeout.timeout(90) { @dex_bulk_fetcher.fetch_all }
          dex_prices.each do |key, data|
            # Check staleness before adding
            if price_is_fresh?(data)
              prices[key] = {
                bid: data.price,
                ask: data.price,
                last: data.price,
                liquidity_usd: data.liquidity_usd,
                volume_24h: data.volume_24h,
                received_at: data.received_at
              }
            else
              @stale_count += 1
            end
          end
          log("DEX prices done: #{dex_prices.size} tokens")
        rescue StandardError => e
          @logger.error("DEX price fetch error: #{e.message}")
          @logger.error("Backtrace: #{e.backtrace.first(3).join(' | ')}")
        end

        # Fetch Perp DEX prices (with timeout)
        begin
          log('Fetching Perp DEX prices...')
          perp_prices = Timeout.timeout(60) { @perp_dex_fetcher.fetch_all_dexes }
          log("Perp DEX prices done: #{perp_prices.size} dexes")
          perp_prices.each do |dex, dex_prices|
            dex_prices.each do |symbol, data|
              base = extract_base_symbol(symbol)
              key = "#{dex}:#{base}"

              # Check staleness before adding
              if price_is_fresh?(data)
                prices[key] = data
              else
                @stale_count += 1
                @logger.debug("Stale price from #{key}: age > #{@max_price_age_ms}ms")
              end
            end
          end
        rescue StandardError => e
          @logger.error("PerpDEX price fetch error: #{e.message}")
        end

        # Log stale prices if any
        if @stale_count > 0
          @logger.warn("[PriceMonitor] #{@stale_count} stale prices filtered out (age > #{@max_price_age_ms}ms)")
        end

        prices
      end

      # Check if price data is fresh (not stale)
      # @param data [Hash, Struct] price data with received_at or exchange_ts
      # @return [Boolean] true if fresh, false if stale
      def price_is_fresh?(data)
        return true unless data # Allow nil to pass (handled elsewhere)

        now_ms = (Time.now.to_f * 1000).to_i

        # Check received_at first (when we received the data)
        received_at = extract_timestamp_ms(data, :received_at)
        if received_at && received_at > 0
          age_ms = now_ms - received_at
          return age_ms <= @max_price_age_ms
        end

        # Fallback to exchange_ts (timestamp from exchange)
        exchange_ts = extract_timestamp_ms(data, :exchange_ts)
        if exchange_ts && exchange_ts > 0
          age_ms = now_ms - exchange_ts
          return age_ms <= @max_price_age_ms
        end

        # If no timestamp available, consider fresh (will be caught by other checks)
        true
      end

      # Extract timestamp in milliseconds from data
      def extract_timestamp_ms(data, key)
        value = if data.respond_to?(key)
                  data.send(key)
                elsif data.is_a?(Hash)
                  data[key] || data[key.to_s]
                end

        return nil unless value

        # Convert to ms if in seconds
        value = value.to_i
        value *= 1000 if value < 1_000_000_000_000 # Likely seconds, not ms
        value
      end

      def fetch_dex_prices(symbols, prices)
        dex_count = 0
        symbols.each_with_index do |symbol, idx|
          log("DEX progress: #{idx}/#{symbols.size} (#{symbol})") if idx % 100 == 0

          begin
            ticker = @ticker_storage.get(symbol)
          rescue StandardError => e
            @logger.warn("Ticker get error for #{symbol}: #{e.message}")
            next
          end
          next unless ticker

          # Skip if no DEX venues
          dex_venues = ticker.venues[:dex_spot] || []
          next if dex_venues.empty?

          dex_count += dex_venues.size

          dex_venues.each do |venue|
            dex = venue[:dex]
            chain = venue[:chain]
            token_address = ticker.contracts[chain]

            next unless token_address

            begin
              price_data = @dex_fetcher.fetch(dex, token_address)
              next unless price_data

              base = symbol.upcase
              key = "#{dex}:#{base}"

              data = {
                bid: price_data.price,
                ask: price_data.price,
                last: price_data.price,
                price_impact_pct: price_data.price_impact_pct,
                received_at: price_data.received_at
              }

              # Check staleness before adding
              if price_is_fresh?(data)
                prices[key] = data
              else
                @stale_count += 1
                @logger.debug("Stale DEX price from #{key}: age > #{@max_price_age_ms}ms")
              end
            rescue StandardError => e
              @logger.debug("DEX price fetch error for #{symbol}/#{dex}: #{e.message}")
            end
          end
        end
        log("DEX scan complete: #{dex_count} venues checked")
      end

      def cache_prices(prices)
        return if prices.empty?

        log("Serializing #{prices.size} prices...")
        serialized = prices.transform_values do |data|
          if data.respond_to?(:to_h)
            data.to_h.transform_values(&:to_s)
          else
            data.transform_values(&:to_s)
          end
        end
        log("Serialization done, saving to Redis...")

        json_data = serialized.to_json
        log("JSON size: #{json_data.bytesize} bytes")

        Timeout.timeout(10) do
          ArbitrageBot.redis.set(PRICE_CACHE_KEY, json_data)
          ArbitrageBot.redis.expire(PRICE_CACHE_KEY, PRICE_TTL)
          # Update timestamp for health check
          ArbitrageBot.redis.set('prices:last_update', Time.now.to_i)
        end
        log("Saved to Redis")
      rescue Timeout::Error
        @logger.error("Redis SET timed out after 10 seconds")
      end

      def calculate_spreads(symbols, all_prices)
        # Dynamic spread generation from available prices (100% match rate)
        # Group prices by base symbol
        prices_by_symbol = Hash.new { |h, k| h[k] = [] }
        all_prices.each do |key, data|
          venue_id, base_symbol = key.split(':', 2)
          next unless base_symbol && !base_symbol.empty?

          venue_info = parse_venue_from_key(venue_id, base_symbol)
          next unless venue_info

          prices_by_symbol[base_symbol] << {
            key: key,
            venue_id: venue_id,
            venue_info: venue_info,
            data: data
          }
        end

        # Generate spreads for all combinations
        spreads = []
        prices_by_symbol.each do |symbol, venues|
          next if venues.size < 2

          venues.combination(2).each do |v1, v2|
            spread = calculate_dynamic_spread(symbol, v1, v2)
            spreads << spread if spread
          end
        end

        spreads
      end

      # Parse venue_id to get full venue info for orderbook fetching
      def parse_venue_from_key(venue_id, base_symbol)
        # CEX patterns
        if venue_id.end_with?('_futures')
          exchange = venue_id.sub('_futures', '')
          trading_symbol = lookup_trading_symbol(exchange, base_symbol, :futures)
          return {
            type: 'cex_futures',
            venue_id: venue_id,
            exchange: exchange,
            symbol: trading_symbol || "#{base_symbol}USDT"
          }
        elsif venue_id.end_with?('_spot')
          exchange = venue_id.sub('_spot', '')
          trading_symbol = lookup_trading_symbol(exchange, base_symbol, :spot)
          return {
            type: 'cex_spot',
            venue_id: venue_id,
            exchange: exchange,
            symbol: trading_symbol || "#{base_symbol}USDT"
          }
        end

        # DEX patterns - known DEX names
        dex_names = %w[uniswap pancakeswap jupiter camelot traderjoe sushiswap curve]
        perp_dex_names = %w[gmx dydx hyperliquid vertex aster]

        if perp_dex_names.include?(venue_id)
          return {
            type: 'perp_dex',
            venue_id: "#{venue_id}_perp",
            dex: venue_id,
            symbol: "#{base_symbol}-USD"
          }
        elsif dex_names.any? { |d| venue_id.start_with?(d) }
          # Could be uniswap_ethereum, jupiter_solana, etc.
          parts = venue_id.split('_')
          dex = parts[0]
          chain = parts[1] if parts.size > 1
          return {
            type: 'dex_spot',
            venue_id: venue_id,
            dex: dex,
            chain: chain,
            symbol: base_symbol
          }
        elsif dex_names.include?(venue_id)
          return {
            type: 'dex_spot',
            venue_id: venue_id,
            dex: venue_id,
            symbol: base_symbol
          }
        end

        nil # Unknown venue type
      end

      # Look up actual trading symbol from ticker storage
      def lookup_trading_symbol(exchange, base_symbol, market_type)
        ticker = @ticker_storage.get(base_symbol)
        return nil unless ticker

        venues = case market_type
                 when :futures
                   ticker.venues[:cex_futures] || ticker.venues['cex_futures'] || []
                 when :spot
                   ticker.venues[:cex_spot] || ticker.venues['cex_spot'] || []
                 else
                   []
                 end

        venue = venues.find { |v| (v[:exchange] || v['exchange']) == exchange }
        venue[:symbol] || venue['symbol'] if venue
      end

      def calculate_dynamic_spread(symbol, v1, v2)
        price1 = v1[:data]
        price2 = v2[:data]

        # Get bid/ask
        bid1 = extract_price(price1, :bid)
        ask1 = extract_price(price1, :ask)
        bid2 = extract_price(price2, :bid)
        ask2 = extract_price(price2, :ask)

        return nil unless bid1 && ask1 && bid2 && ask2
        return nil if ask1 <= 0 || ask2 <= 0

        # Filter mismatched tokens: if prices differ by more than 10x, likely different tokens
        # This catches cases like PUMPBTC (DEX: $94k wrapped BTC, CEX: $0.02 different token)
        price_ratio = [ask1, ask2].max / [ask1, ask2].min
        if price_ratio > 10.0
          @logger.debug("[PriceMonitor] Price mismatch filter: #{symbol} - #{v1[:venue_id]} ($#{ask1.round(6)}) vs #{v2[:venue_id]} ($#{ask2.round(6)}) ratio=#{price_ratio.round(1)}x")
          return nil
        end

        # Calculate both directions
        spread1 = ((bid2 - ask1) / ask1 * 100).round(4)
        spread2 = ((bid1 - ask2) / ask2 * 100).round(4)

        if spread1 >= spread2
          build_spread(symbol, v1, v2, ask1, bid2, spread1)
        else
          build_spread(symbol, v2, v1, ask2, bid1, spread2)
        end
      end

      def extract_price(data, field)
        value = if data.is_a?(Hash)
                  data[field] || data[field.to_s]
                elsif data.respond_to?(field)
                  data.send(field)
                end
        value.to_f if value
      end

      def build_spread(symbol, low, high, buy_price, sell_price, spread_pct)
        {
          pair_id: "#{low[:venue_id]}:#{high[:venue_id]}",
          symbol: symbol,
          low_venue: low[:venue_info],
          high_venue: high[:venue_info],
          buy_price: buy_price,
          sell_price: sell_price,
          spread_pct: spread_pct,
          timestamp: Time.now.to_i
        }
      end

      def calculate_pair_spread(pair, all_prices)
        low_venue = pair[:low_venue] || pair['low_venue']
        high_venue = pair[:high_venue] || pair['high_venue']
        pair_symbol = pair[:symbol] || pair['symbol']

        low_key = venue_price_key(low_venue, pair_symbol)
        high_key = venue_price_key(high_venue, pair_symbol)

        low_price = all_prices[low_key]
        high_price = all_prices[high_key]

        return nil unless low_price && high_price

        # Get ask from low venue (buy price) and bid from high venue (sell price)
        buy_price = low_price.respond_to?(:ask) ? low_price.ask : low_price[:ask]
        sell_price = high_price.respond_to?(:bid) ? high_price.bid : high_price[:bid]

        return nil unless buy_price && sell_price && buy_price > 0

        spread_pct = ((sell_price.to_f - buy_price.to_f) / buy_price.to_f * 100).round(4)

        {
          pair_id: pair[:id] || pair['id'],
          symbol: pair[:symbol] || pair['symbol'],
          low_venue: low_venue,
          high_venue: high_venue,
          buy_price: buy_price.to_f,
          sell_price: sell_price.to_f,
          spread_pct: spread_pct,
          timestamp: Time.now.to_i
        }
      end

      def cache_spreads(spreads)
        return if spreads.empty?

        ArbitrageBot.redis.set(SPREAD_CACHE_KEY, spreads.to_json)
        ArbitrageBot.redis.expire(SPREAD_CACHE_KEY, PRICE_TTL)
      end

      def trigger_analysis(spreads)
        # Reload min_spread from Redis for real-time UI changes
        current_min_spread = reload_min_spread_setting
        min_dex_liq = reload_min_dex_liquidity_setting

        high_spreads = spreads.select do |s|
          spread_pct = s[:spread_pct].abs
          next false if spread_pct < current_min_spread

          # Get venue types
          low_type = (s[:low_venue][:type] || s[:low_venue]['type']).to_s rescue ''
          high_type = (s[:high_venue][:type] || s[:high_venue]['type']).to_s rescue ''

          # Check DEX liquidity if either venue is DEX
          dex_types = %w[dex_spot perp_dex]
          low_is_dex = dex_types.include?(low_type)
          high_is_dex = dex_types.include?(high_type)

          if low_is_dex || high_is_dex
            # Filter out low liquidity DEX pairs
            low_liq = (s[:low_venue][:liquidity_usd] || s[:low_venue]['liquidity_usd']).to_f rescue 0
            high_liq = (s[:high_venue][:liquidity_usd] || s[:high_venue]['liquidity_usd']).to_f rescue 0

            if low_is_dex && low_liq < min_dex_liq
              next false
            end
            if high_is_dex && high_liq < min_dex_liq
              next false
            end
          end

          true
        end

        high_spreads.each do |spread|
          spread[:detected_at] = Time.now.to_i
          ArbitrageBot.redis.lpush('queue:orderbook_analysis', spread.to_json)
          ArbitrageBot.redis.ltrim('queue:orderbook_analysis', 0, 999)
        end

        log("Triggered analysis for #{high_spreads.size} high spreads") if high_spreads.any?
      end

      def venue_price_key(venue, fallback_symbol = nil)
        type = venue[:type] || venue['type']
        exchange = venue[:exchange] || venue['exchange']
        dex = venue[:dex] || venue['dex']
        symbol = venue[:symbol] || venue['symbol'] || fallback_symbol

        base = extract_base_symbol(symbol || '')

        case type.to_sym
        when :cex_futures
          "#{exchange}_futures:#{base}"
        when :cex_spot
          "#{exchange}_spot:#{base}"
        when :perp_dex
          "#{dex}:#{base}"
        when :dex_spot
          "#{dex}:#{base}"
        else
          "unknown:#{base}"
        end
      end

      def extract_base_symbol(symbol)
        symbol.to_s.upcase
          .gsub(/USDT$|USDC$|USD$|BUSD$/, '')
          .gsub(/[-_]/, '')
          .gsub(/PERP$/, '')
      end

      # Reload just min_spread_pct from Redis for real-time UI changes
      def reload_min_spread_setting
        stored_value = ArbitrageBot.redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_spread_pct')
        if stored_value
          stored_value.to_f
        else
          @min_spread_pct || 1.0
        end
      rescue StandardError
        @min_spread_pct || 1.0
      end

      # Reload min_dex_liquidity_usd from Redis for real-time UI changes
      def reload_min_dex_liquidity_setting
        stored_value = ArbitrageBot.redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_dex_liquidity_usd')
        if stored_value
          stored_value.to_i
        else
          1000 # Default minimum DEX liquidity
        end
      rescue StandardError
        1000
      end

      # Record spread samples for baseline statistics
      # This captures "normal" spread behavior across all pairs
      def record_baseline_samples(spreads)
        return if spreads.empty?

        log("Recording #{spreads.size} baseline samples...")

        # Convert spreads to baseline format
        samples = spreads.map do |spread|
          {
            pair_id: spread[:pair_id],
            symbol: spread[:symbol],
            spread_pct: spread[:spread_pct]
          }
        end.compact

        @baseline_collector.record_batch(samples)
        log("Baseline samples recorded")
      rescue StandardError => e
        @logger.error("[PriceMonitor] record_baseline_samples error: #{e.message}")
      end
    end
  end
end
