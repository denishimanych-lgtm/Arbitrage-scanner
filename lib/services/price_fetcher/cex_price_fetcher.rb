# frozen_string_literal: true

module ArbitrageBot
  module Services
    module PriceFetcher
      class CexPriceFetcher
        PriceData = Struct.new(:symbol, :bid, :ask, :last, :exchange_ts, :received_at, :market_type, keyword_init: true)

        def initialize
          @adapters = {}
        end

        # Fetch single ticker price
        def fetch(exchange, symbol, market_type: :futures)
          adapter = get_adapter(exchange)
          response = adapter.ticker(symbol, market_type: market_type)

          PriceData.new(
            symbol: symbol,
            bid: response[:bid],
            ask: response[:ask],
            last: response[:last] || ((response[:bid] + response[:ask]) / 2),
            exchange_ts: response[:timestamp],
            received_at: (Time.now.to_f * 1000).to_i,
            market_type: market_type
          )
        end

        # Fetch batch tickers for an exchange
        def fetch_batch(exchange, symbols = nil, market_type: :futures)
          adapter = get_adapter(exchange)
          response = adapter.tickers(symbols, market_type: market_type)
          received_at = (Time.now.to_f * 1000).to_i

          response.transform_values do |data|
            PriceData.new(
              symbol: data[:symbol],
              bid: data[:bid],
              ask: data[:ask],
              last: data[:last] || ((data[:bid] + data[:ask]) / 2),
              exchange_ts: data[:timestamp],
              received_at: received_at,
              market_type: market_type
            )
          end
        end

        # Fetch from all exchanges in parallel - BOTH spot and futures
        def fetch_all_exchanges(symbols = nil)
          ArbitrageBot.logger.info("[CEX] Starting fetch_all_exchanges (spot + futures)...")
          results = {}
          threads = []

          exchanges = AdapterFactory::Cex.available
          ArbitrageBot.logger.info("[CEX] Exchanges: #{exchanges.join(', ')}")

          # Fetch BOTH spot and futures for each exchange
          exchanges.each do |exchange|
            # Futures thread
            threads << Thread.new do
              begin
                prices = fetch_batch(exchange, symbols, market_type: :futures)
                Thread.current[:result] = { "#{exchange}_futures" => prices }
              rescue StandardError => e
                ArbitrageBot.logger.error("Price fetch error #{exchange} futures: #{e.message}")
                Thread.current[:result] = { "#{exchange}_futures" => {} }
              end
            end

            # Spot thread
            threads << Thread.new do
              begin
                prices = fetch_batch(exchange, symbols, market_type: :spot)
                Thread.current[:result] = { "#{exchange}_spot" => prices }
              rescue StandardError => e
                ArbitrageBot.logger.error("Price fetch error #{exchange} spot: #{e.message}")
                Thread.current[:result] = { "#{exchange}_spot" => {} }
              end
            end
          end

          ArbitrageBot.logger.info("[CEX] Started #{threads.size} threads (spot+futures), waiting...")

          threads.each_with_index do |t, i|
            # Timeout thread after 15 seconds to prevent hanging
            t.join(15)
            if t.alive?
              ArbitrageBot.logger.warn("[CEX] Thread #{i} timed out, killing...")
              t.kill
            end
            results.merge!(t[:result]) if t[:result]
          end

          ArbitrageBot.logger.info("[CEX] Fetch complete, #{results.size} exchange/market_type combinations returned")
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
