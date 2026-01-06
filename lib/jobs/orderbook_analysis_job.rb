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

        log("Analyzing: #{spread['pair_id']} (#{spread['spread_pct']}%)")

        # Fetch orderbooks
        low_orderbook = fetch_orderbook(spread['low_venue'])
        high_orderbook = fetch_orderbook(spread['high_venue'])

        unless low_orderbook && high_orderbook
          log("  Skipped: couldn't fetch orderbooks")
          return nil
        end

        # Calculate real spread with slippage
        position_size = @settings[:suggested_position_usd] || 10_000
        spread_result = @spread_calc.calculate(
          orderbook_to_hash(low_orderbook),
          orderbook_to_hash(high_orderbook),
          position_size
        )

        unless spread_result
          log("  Skipped: spread calculation failed")
          return nil
        end

        # Build signal
        signal = build_signal(spread, low_orderbook, high_orderbook, spread_result)

        # Track spread age
        @spread_tracker.record(
          spread['pair_id'],
          spread_result.real_spread_pct,
          @settings[:min_spread_pct] || 1.0
        )

        # Collect depth history
        collect_depth_history(spread, low_orderbook, high_orderbook)

        # Queue signal for liquidity checks
        queue_signal(signal)

        log("  Signal queued: real_spread=#{spread_result.real_spread_pct}%")

        signal
      end

      # Process queue continuously
      def run_loop
        log("Starting orderbook analysis loop")

        loop do
          begin
            # Pop from queue (blocking with timeout)
            _, data = @redis.brpop(QUEUE_KEY, timeout: 5)

            if data
              perform(data)
            end
          rescue StandardError => e
            @logger.error("Orderbook analysis error: #{e.message}")
            @logger.error(e.backtrace.first(5).join("\n"))
            sleep 1
          end
        end
      end

      private

      def log(message)
        @logger.info("[OrderbookAnalysis] #{message}")
      end

      def fetch_orderbook(venue)
        type = (venue['type'] || venue[:type]).to_sym
        depth = 20

        case type
        when :cex_futures, :cex_spot
          exchange = venue['exchange'] || venue[:exchange]
          symbol = venue['symbol'] || venue[:symbol]
          @cex_orderbook.fetch(exchange, symbol, depth: depth)

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

      def build_signal(spread, low_orderbook, high_orderbook, spread_result)
        timing = Services::Trackers::TimingData.new(
          orderbook_to_hash(low_orderbook),
          orderbook_to_hash(high_orderbook)
        )

        exit_liquidity = @depth_calc.calculate_exit_liquidity(
          orderbook_to_hash(low_orderbook),
          orderbook_to_hash(high_orderbook)
        )

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
            sell_slippage_pct: spread_result.entry.sell_slippage_pct.to_f
          },
          spread: {
            nominal_pct: spread_result.nominal_spread_pct.to_f,
            real_pct: spread_result.real_spread_pct.to_f,
            loss_pct: spread_result.spread_loss_pct.to_f
          },
          liquidity: {
            exit_usd: exit_liquidity[:min_exit_usd].to_f,
            low_bids_usd: exit_liquidity[:low_bids_usd].to_f,
            high_asks_usd: exit_liquidity[:high_asks_usd].to_f
          },
          timing: timing.to_h,
          position_size_usd: spread_result.position_size_usd,
          fully_fillable: spread_result.fully_fillable,
          created_at: Time.now.to_i
        }
      end

      def collect_depth_history(spread, low_orderbook, high_orderbook)
        pair_id = spread['pair_id']

        low_venue_id = venue_id(spread['low_venue'])
        high_venue_id = venue_id(spread['high_venue'])

        @depth_history.collect(pair_id, low_venue_id, orderbook_to_hash(low_orderbook))
        @depth_history.collect(pair_id, high_venue_id, orderbook_to_hash(high_orderbook))
      end

      def queue_signal(signal)
        @redis.lpush(SIGNAL_KEY, signal.to_json)
        @redis.ltrim(SIGNAL_KEY, 0, 499) # Keep max 500 pending
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
