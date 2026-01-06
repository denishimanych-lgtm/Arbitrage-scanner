# frozen_string_literal: true

module ArbitrageBot
  module Services
    module PriceFetcher
      class CexPriceFetcher
        PriceData = Struct.new(:symbol, :bid, :ask, :last, :exchange_ts, :received_at, keyword_init: true)

        def initialize
          @adapters = {}
        end

        # Fetch single ticker price
        def fetch(exchange, symbol)
          adapter = get_adapter(exchange)
          response = adapter.ticker(symbol)

          PriceData.new(
            symbol: symbol,
            bid: response[:bid],
            ask: response[:ask],
            last: response[:last] || ((response[:bid] + response[:ask]) / 2),
            exchange_ts: response[:timestamp],
            received_at: (Time.now.to_f * 1000).to_i
          )
        end

        # Fetch batch tickers for an exchange
        def fetch_batch(exchange, symbols = nil)
          adapter = get_adapter(exchange)
          response = adapter.tickers(symbols)
          received_at = (Time.now.to_f * 1000).to_i

          response.transform_values do |data|
            PriceData.new(
              symbol: data[:symbol],
              bid: data[:bid],
              ask: data[:ask],
              last: data[:last] || ((data[:bid] + data[:ask]) / 2),
              exchange_ts: data[:timestamp],
              received_at: received_at
            )
          end
        end

        # Fetch from all exchanges in parallel
        def fetch_all_exchanges(symbols = nil)
          results = {}
          threads = []

          AdapterFactory::Cex.available.each do |exchange|
            threads << Thread.new do
              begin
                prices = fetch_batch(exchange, symbols)
                Thread.current[:result] = { exchange => prices }
              rescue StandardError => e
                ArbitrageBot.logger.error("Price fetch error #{exchange}: #{e.message}")
                Thread.current[:result] = { exchange => {} }
              end
            end
          end

          threads.each do |t|
            t.join
            results.merge!(t[:result]) if t[:result]
          end

          results
        end

        private

        def get_adapter(exchange)
          @adapters[exchange] ||= AdapterFactory::Cex.get(exchange)
        end
      end
    end
  end
end
