# frozen_string_literal: true

module ArbitrageBot
  module Services
    module PriceFetcher
      class PerpDexPriceFetcher
        PriceData = Struct.new(
          :symbol, :bid, :ask, :mid, :mark_price, :index_price,
          :funding_rate, :next_funding_time, :dex, :received_at,
          keyword_init: true
        )

        def initialize
          @adapters = {}
        end

        # Fetch single ticker
        def fetch(dex, symbol)
          adapter = get_adapter(dex)
          response = adapter.ticker(symbol)

          return nil unless response

          bid = response[:bid].to_f
          ask = response[:ask].to_f

          # Skip zero or invalid prices
          return nil if bid <= 0 || ask <= 0

          PriceData.new(
            symbol: symbol,
            bid: bid,
            ask: ask,
            mid: response[:mid] || ((bid + ask) / 2),
            mark_price: response[:mark_price],
            index_price: response[:index_price],
            funding_rate: response[:funding_rate],
            next_funding_time: response[:next_funding_time],
            dex: dex,
            received_at: (Time.now.to_f * 1000).to_i
          )
        end

        # Fetch all tickers from a DEX
        def fetch_batch(dex, symbols = nil)
          adapter = get_adapter(dex)
          response = adapter.tickers(symbols)
          received_at = (Time.now.to_f * 1000).to_i

          result = {}
          response.each do |symbol, data|
            bid = data[:bid].to_f
            ask = data[:ask].to_f

            # Skip zero or invalid prices (root cause of fake spreads)
            next if bid <= 0 || ask <= 0

            result[symbol] = PriceData.new(
              symbol: data[:symbol],
              bid: bid,
              ask: ask,
              mid: data[:mid] || data[:mark_price],
              mark_price: data[:mark_price],
              index_price: data[:index_price],
              funding_rate: data[:funding_rate],
              next_funding_time: data[:next_funding_time],
              dex: dex,
              received_at: received_at
            )
          end
          result
        end

        # Fetch from all Perp DEXes
        def fetch_all_dexes(symbols = nil)
          results = {}
          threads = []

          AdapterFactory::PerpDex.available.each do |dex|
            threads << Thread.new do
              begin
                prices = fetch_batch(dex, symbols)
                Thread.current[:result] = { dex => prices }
              rescue StandardError => e
                ArbitrageBot.logger.error("PerpDEX price fetch error #{dex}: #{e.message}")
                Thread.current[:result] = { dex => {} }
              end
            end
          end

          threads.each_with_index do |t, i|
            # Timeout thread after 15 seconds to prevent hanging
            t.join(15)
            if t.alive?
              ArbitrageBot.logger.warn("[PerpDEX] Thread #{i} timed out, killing...")
              t.kill
            end
            results.merge!(t[:result]) if t[:result]
          end

          ArbitrageBot.logger.info("[PerpDEX] Fetch complete, #{results.size} dexes returned")
          results
        end

        # Fetch funding rate
        def fetch_funding_rate(dex, symbol)
          adapter = get_adapter(dex)
          adapter.funding_rate(symbol)
        end

        private

        def get_adapter(dex)
          @adapters[dex] ||= AdapterFactory::PerpDex.get(dex)
        end
      end
    end
  end
end
