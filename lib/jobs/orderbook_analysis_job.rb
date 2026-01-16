# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    class OrderbookAnalysisJob
      QUEUE_KEY = 'queue:orderbook_analysis'
      SIGNAL_KEY = 'signals:pending'

      attr_reader :logger, :redis, :settings

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @redis = ArbitrageBot.redis
        @settings = settings

        @cex_orderbook = Services::Orderbook::CexOrderbookFetcher.new
        @perp_orderbook = Services::Orderbook::PerpDexOrderbookFetcher.new
        @dex_depth = Services::Orderbook::DexDepthFetcher.new

        @spread_calc = Services::Calculators::SpreadCalculator.new
        @depth_calc = Services::Calculators::DepthCalculator.new(
          max_slippage_pct: settings[:max_slippage_pct] || 1.0
        )

        @spread_tracker = Services::Trackers::SpreadAgeTracker.new
        @depth_history = Services::Trackers::DepthHistoryCollector.new

        @ticker_storage = Storage::TickerStorage.new
      end

      # Process single spread from queue
      def perform(spread_data)
        spread = spread_data.is_a?(String) ? JSON.parse(spread_data) : spread_data

        # Skip signals that are too old (stale data)
        max_signal_age_sec = @settings[:max_signal_age_sec] || 120
        detected_at = spread['detected_at'] || spread[:detected_at]
        if detected_at
          age_sec = Time.now.to_i - detected_at.to_i
          if age_sec > max_signal_age_sec
            log("Skipping stale signal: #{spread['pair_id']} (#{age_sec}s old)")
            return nil
          end
        end

        log("Analyzing: #{spread['pair_id']} (#{spread['spread_pct']}%)")

        # Fetch orderbooks with timeout protection
        log("  Fetching low orderbook...")
        low_orderbook = Timeout.timeout(15) { fetch_orderbook(spread['low_venue']) } rescue nil
        log("  Fetching high orderbook...")
        high_orderbook = Timeout.timeout(15) { fetch_orderbook(spread['high_venue']) } rescue nil

        # Fallback: if orderbooks unavailable, create signal from cached prices
        if !low_orderbook || !high_orderbook
          log("  Orderbook fetch failed, using fallback from cached prices")
          signal = build_fallback_signal(spread)
          if signal
            queue_signal(signal)
            log("  Fallback signal queued: spread=#{spread['spread_pct']}%")
            return signal
          else
            log("  Skipped: fallback signal creation failed")
            return nil
          end
        end

        log("  Calculating spread...")
        # Calculate real spread with slippage
        position_size = @settings[:suggested_position_usd] || 10_000

        low_ob = orderbook_to_hash(low_orderbook)
        high_ob = orderbook_to_hash(high_orderbook)

        # Log best prices from orderbook for debugging
        best_ask_low = low_ob[:asks]&.first&.at(0)
        best_bid_high = high_ob[:bids]&.first&.at(0)
        log("  Low best ask: $#{best_ask_low}, High best bid: $#{best_bid_high}")

        spread_result = @spread_calc.calculate(low_ob, high_ob, position_size)

        unless spread_result
          log("  Spread calculation failed, using fallback")
          signal = build_fallback_signal(spread)
          if signal
            queue_signal(signal)
            log("  Fallback signal queued: spread=#{spread['spread_pct']}%")
            return signal
          else
            log("  Skipped: fallback signal creation failed")
            return nil
          end
        end

        log("  Executable prices: buy=$#{spread_result.entry.buy_price.round(6)} sell=$#{spread_result.entry.sell_price.round(6)}")

        log("  Building signal...")
        # Build signal - pass already converted orderbook hashes
        signal = build_signal(spread, low_ob, high_ob, spread_result)
        log("  Signal built, tracking...")

        # Track spread age
        @spread_tracker.record(
          spread['pair_id'],
          spread_result.real_spread_pct,
          reload_min_spread_setting
        )

        # Collect depth history
        collect_depth_history(spread, low_ob, high_ob)
        log("  Depth history collected, queueing signal...")

        # Queue signal for liquidity checks
        queue_signal(signal)

        log("  Signal queued: real_spread=#{spread_result.real_spread_pct}%")

        signal
      rescue Timeout::Error => e
        log("  Timeout fetching orderbooks, using fallback")
        signal = build_fallback_signal(spread)
        if signal
          queue_signal(signal)
          log("  Fallback signal queued")
        end
        signal
      rescue StandardError => e
        log("  Error: #{e.class}: #{e.message}")
        @logger.error("[OrderbookAnalysis] #{e.backtrace.first(5).join("\n")}")
        nil
      end

      # Process queue continuously
      def run_loop
        log("Starting orderbook analysis loop")

        loop do
          begin
            # Use thread-local redis connection
            redis = ArbitrageBot.redis

            # Pop from queue (blocking with timeout)
            result = redis.brpop(QUEUE_KEY, timeout: 5)

            if result
              _, data = result
              log("Processing item from queue...")
              perform(data)
            end
          rescue StandardError => e
            @logger.error("[OrderbookAnalysis] Loop error: #{e.class}: #{e.message}")
            @logger.error("[OrderbookAnalysis] #{e.backtrace.first(5).join("\n")}")
            sleep 1
          end
        end
      rescue StandardError => e
        @logger.error("[OrderbookAnalysis] Fatal error in run_loop: #{e.class}: #{e.message}")
        @logger.error("[OrderbookAnalysis] #{e.backtrace.first(10).join("\n")}")
        raise
      end

      private

      def log(message)
        @logger.info("[OrderbookAnalysis] #{message}")
      end

      # Reload just min_spread_pct from Redis for real-time UI changes
      def reload_min_spread_setting
        stored_value = ArbitrageBot.redis.hget(Services::SettingsLoader::REDIS_KEY, 'min_spread_pct')
        if stored_value
          stored_value.to_f
        else
          @settings[:min_spread_pct] || 1.0
        end
      rescue StandardError
        @settings[:min_spread_pct] || 1.0
      end

      def fetch_orderbook(venue)
        type = (venue['type'] || venue[:type]).to_sym
        depth = @settings[:orderbook_depth] || 20

        case type
        when :cex_futures, :cex_spot
          exchange = venue['exchange'] || venue[:exchange]
          symbol = venue['symbol'] || venue[:symbol]
          market_type = type == :cex_spot ? :spot : :futures
          @cex_orderbook.fetch(exchange, symbol, depth: depth, market_type: market_type)

        when :perp_dex
          dex = venue['dex'] || venue[:dex]
          symbol = venue['symbol'] || venue[:symbol]
          @perp_orderbook.fetch(dex, symbol, depth: depth)

        when :dex_spot
          # DEX doesn't have traditional orderbook, use depth profile
          dex = venue['dex'] || venue[:dex]
          token = venue['token_address'] || venue[:token_address]
          return nil unless token

          depth_data = @dex_depth.fetch(dex, token)
          return nil unless depth_data

          # Convert to orderbook format
          @dex_depth.to_orderbook_format(depth_data)

        else
          nil
        end
      rescue StandardError => e
        @logger.error("Orderbook fetch error: #{e.message}")
        nil
      end

      def orderbook_to_hash(orderbook)
        if orderbook.respond_to?(:to_h)
          h = orderbook.to_h
          {
            bids: h[:bids] || h['bids'],
            asks: h[:asks] || h['asks'],
            timing: h[:timing] || h['timing']
          }
        elsif orderbook.is_a?(Hash)
          {
            bids: orderbook[:bids] || orderbook['bids'],
            asks: orderbook[:asks] || orderbook['asks'],
            timing: orderbook[:timing] || orderbook['timing']
          }
        else
          { bids: [], asks: [] }
        end
      end

      def build_signal(spread, low_ob, high_ob, spread_result)
        timing = Services::Trackers::TimingData.new(low_ob, high_ob)

        exit_liquidity = @depth_calc.calculate_exit_liquidity(low_ob, high_ob)

        # Calculate max entry size within slippage limit
        max_slippage = @settings[:max_slippage_pct] || 1.0
        exec_calc = Services::Calculators::ExecutablePriceCalculator.new

        # Entry: buy on low asks, sell (short) on high bids
        max_buy_usd = exec_calc.max_size_within_slippage(low_ob, :buy, max_slippage)
        max_sell_usd = exec_calc.max_size_within_slippage(high_ob, :sell, max_slippage)
        max_entry_usd = [max_buy_usd, max_sell_usd].min.to_f

        # Get best prices from orderbooks
        best_ask_low = low_ob[:asks]&.first&.at(0)&.to_f || 0
        best_bid_high = high_ob[:bids]&.first&.at(0)&.to_f || 0

        # Suggested position: min of (max entry, 50% exit liquidity, hard cap)
        exit_usd = exit_liquidity[:min_exit_usd].to_f
        suggested_position = [
          max_entry_usd,
          exit_usd * 0.5,
          50_000
        ].min

        # Round to nice numbers
        suggested_position = case suggested_position
                             when 0...1_000 then (suggested_position / 100).round * 100
                             when 1_000...10_000 then (suggested_position / 500).round * 500
                             else (suggested_position / 1_000).round * 1_000
                             end.to_i

        {
          id: generate_signal_id(spread),
          pair_id: spread['pair_id'],
          symbol: spread['symbol'],
          type: spread['type'] || :auto,
          low_venue: spread['low_venue'],
          high_venue: spread['high_venue'],
          prices: {
            buy_price: spread_result.entry.buy_price.to_f,
            sell_price: spread_result.entry.sell_price.to_f,
            buy_slippage_pct: spread_result.entry.buy_slippage_pct.to_f,
            sell_slippage_pct: spread_result.entry.sell_slippage_pct.to_f,
            # Best prices from orderbook (for verification)
            best_ask_low: best_ask_low,
            best_bid_high: best_bid_high
          },
          spread: {
            nominal_pct: spread_result.nominal_spread_pct.to_f,
            real_pct: spread_result.real_spread_pct.to_f,
            loss_pct: spread_result.spread_loss_pct.to_f
          },
          liquidity: {
            exit_usd: exit_usd,
            low_bids_usd: exit_liquidity[:low_bids_usd].to_f,
            high_asks_usd: exit_liquidity[:high_asks_usd].to_f,
            max_entry_usd: max_entry_usd,
            max_buy_usd: max_buy_usd.to_f,
            max_sell_usd: max_sell_usd.to_f
          },
          timing: timing.to_h,
          position_size_usd: spread_result.position_size_usd,
          suggested_position_usd: suggested_position,
          fully_fillable: spread_result.fully_fillable,
          created_at: Time.now.to_i
        }
      end

      # Build signal from cached prices when orderbook fetch fails
      # This allows signals to proceed with reduced data quality
      def build_fallback_signal(spread)
        buy_price = (spread['buy_price'] || spread[:buy_price]).to_f
        sell_price = (spread['sell_price'] || spread[:sell_price]).to_f
        spread_pct = (spread['spread_pct'] || spread[:spread_pct]).to_f

        return nil if buy_price <= 0 || sell_price <= 0

        # Get DEX liquidity if available
        low_venue = spread['low_venue'] || spread[:low_venue] || {}
        high_venue = spread['high_venue'] || spread[:high_venue] || {}

        low_liq = (low_venue['liquidity_usd'] || low_venue[:liquidity_usd]).to_f rescue 0
        high_liq = (high_venue['liquidity_usd'] || high_venue[:liquidity_usd]).to_f rescue 0

        # Use available liquidity or default
        available_liq = [low_liq, high_liq].select { |l| l > 0 }.min || 0

        # Conservative position sizing for fallback signals
        suggested_position = if available_liq > 0
                               [available_liq * 0.1, 5000].min.to_i
                             else
                               1000 # Minimum position for CEX pairs without liquidity data
                             end

        {
          id: generate_signal_id(spread),
          pair_id: spread['pair_id'] || spread[:pair_id],
          symbol: spread['symbol'] || spread[:symbol],
          type: :fallback, # Mark as fallback signal
          low_venue: low_venue,
          high_venue: high_venue,
          prices: {
            buy_price: buy_price,
            sell_price: sell_price,
            buy_slippage_pct: 0,
            sell_slippage_pct: 0,
            best_ask_low: buy_price,
            best_bid_high: sell_price
          },
          spread: {
            nominal_pct: spread_pct,
            real_pct: spread_pct, # No slippage data available
            loss_pct: 0
          },
          liquidity: {
            exit_usd: available_liq,
            low_bids_usd: low_liq,
            high_asks_usd: high_liq,
            max_entry_usd: suggested_position,
            max_buy_usd: suggested_position,
            max_sell_usd: suggested_position
          },
          timing: { latency_ms: 0 },
          position_size_usd: suggested_position,
          suggested_position_usd: suggested_position,
          fully_fillable: false, # Can't verify without orderbook
          fallback_signal: true, # Flag for reduced confidence
          created_at: Time.now.to_i
        }
      end

      def collect_depth_history(spread, low_ob, high_ob)
        pair_id = spread['pair_id']

        low_venue_id = venue_id(spread['low_venue'])
        high_venue_id = venue_id(spread['high_venue'])

        @depth_history.collect(pair_id, low_venue_id, low_ob)
        @depth_history.collect(pair_id, high_venue_id, high_ob)
      end

      def queue_signal(signal)
        redis = ArbitrageBot.redis  # Use thread-local connection
        redis.lpush(SIGNAL_KEY, signal.to_json)
        redis.ltrim(SIGNAL_KEY, 0, 499) # Keep max 500 pending
      end

      def generate_signal_id(spread)
        "#{spread['pair_id']}_#{Time.now.to_i}_#{rand(1000)}"
      end

      def venue_id(venue)
        type = (venue['type'] || venue[:type]).to_sym
        exchange = venue['exchange'] || venue[:exchange]
        dex = venue['dex'] || venue[:dex]

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
