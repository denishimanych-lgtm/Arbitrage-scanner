# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      class LaggingExchangeDetector
        # Lagging detection result
        LaggingResult = Struct.new(
          :lagging, :lagging_exchange, :lagging_price, :median_price,
          :deviation_pct, :other_exchanges_count,
          keyword_init: true
        )

        # Default settings (can be overridden via settings)
        DEFAULT_MIN_EXCHANGES = 4
        DEFAULT_MIN_DEVIATION_PCT = 5.0
        DEFAULT_MAX_OTHER_DEVIATION_PCT = 2.0

        def initialize(settings = {})
          @redis = ArbitrageBot.redis
          @logger = ArbitrageBot.logger

          # Load configurable parameters from settings
          @min_exchanges = settings[:lagging_min_exchanges] || DEFAULT_MIN_EXCHANGES
          @min_deviation_pct = settings[:lagging_min_deviation_pct] || DEFAULT_MIN_DEVIATION_PCT
          @max_other_deviation_pct = settings[:lagging_max_other_deviation_pct] || DEFAULT_MAX_OTHER_DEVIATION_PCT
        end

        # Detect if one exchange is lagging behind majority
        # @param symbol [String] normalized symbol
        # @param prices_by_exchange [Hash] { exchange => { last: price, ... } }
        # @return [LaggingResult]
        def detect(symbol, prices_by_exchange)
          # Need at least min_exchanges exchanges
          if prices_by_exchange.size < @min_exchanges
            return LaggingResult.new(
              lagging: false,
              lagging_exchange: nil,
              lagging_price: nil,
              median_price: nil,
              deviation_pct: 0,
              other_exchanges_count: prices_by_exchange.size
            )
          end

          # Extract prices
          all_prices = prices_by_exchange.map do |exchange, data|
            price = data[:last] || data['last'] || data[:price] || data['price']
            [exchange, price.to_f]
          end.to_h

          # Calculate median
          sorted_prices = all_prices.values.sort
          median_price = calculate_median(sorted_prices)

          return no_lagging_result(0) if median_price <= 0

          # Check each exchange for deviation
          all_prices.each do |exchange, price|
            deviation_pct = ((price - median_price).abs / median_price * 100)

            next unless deviation_pct >= @min_deviation_pct

            # This exchange deviates significantly
            # Check if ALL others are close to median
            others = all_prices.except(exchange)
            others_close = others.all? do |_, other_price|
              other_dev = ((other_price - median_price).abs / median_price * 100)
              other_dev < @max_other_deviation_pct
            end

            if others_close
              # Found lagging exchange!
              @logger.info("[LaggingDetector] #{symbol}: #{exchange} lagging by #{deviation_pct.round(2)}%")

              return LaggingResult.new(
                lagging: true,
                lagging_exchange: exchange,
                lagging_price: price,
                median_price: median_price,
                deviation_pct: deviation_pct.round(2),
                other_exchanges_count: others.size
              )
            end
          end

          # No lagging exchange found
          no_lagging_result(prices_by_exchange.size)
        end

        # Detect lagging for a signal (wrapper)
        # @param signal [Hash] signal with venue info
        # @param all_prices [Hash, nil] all prices by venue (optional)
        # @return [LaggingResult]
        def detect_for_signal(signal, all_prices = nil)
          symbol = signal[:symbol] || signal['symbol']

          # If all_prices provided, use full detection
          if all_prices && !all_prices.empty?
            # Group prices by exchange/venue
            prices_by_exchange = {}

            all_prices.each do |venue_key, price_data|
              # venue_key format: "exchange:SYMBOL" or "dex:SYMBOL"
              parts = venue_key.to_s.split(':')
              exchange = parts.first

              # Only use if it matches our symbol
              base_symbol = parts.last&.upcase
              next unless base_symbol == symbol.upcase

              prices_by_exchange[exchange] = price_data
            end

            detect(symbol, prices_by_exchange)
          else
            # Without all_prices, we can't do full lagging detection
            # Return non-lagging result
            no_lagging_result(0)
          end
        end

        private

        def calculate_median(sorted_array)
          return 0 if sorted_array.empty?

          mid = sorted_array.length / 2
          if sorted_array.length.odd?
            sorted_array[mid]
          else
            (sorted_array[mid - 1] + sorted_array[mid]) / 2.0
          end
        end

        def no_lagging_result(exchange_count)
          LaggingResult.new(
            lagging: false,
            lagging_exchange: nil,
            lagging_price: nil,
            median_price: nil,
            deviation_pct: 0,
            other_exchanges_count: exchange_count
          )
        end
      end
    end
  end
end
