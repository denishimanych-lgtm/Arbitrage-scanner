# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Funding
      # Collects funding rates from all perp venues
      class FundingCollector
        # CEX with perp futures
        CEX_PERPS = {
          binance_futures: { adapter: 'BinanceAdapter', suffix: 'USDT' },
          bybit_futures: { adapter: 'BybitAdapter', suffix: 'USDT' },
          okx_futures: { adapter: 'OkxAdapter', suffix: '-USDT-SWAP' },
          gate_futures: { adapter: 'GateAdapter', suffix: '_USDT' },
          bitget_futures: { adapter: 'BitgetAdapter', suffix: 'USDT' },
          kucoin_futures: { adapter: 'KucoinAdapter', suffix: 'USDTM' },
          htx_futures: { adapter: 'HtxAdapter', suffix: '-USDT' },
          mexc_futures: { adapter: 'MexcAdapter', suffix: '_USDT' }
        }.freeze

        # Perp DEXes
        PERP_DEXES = {
          hyperliquid: { adapter: 'HyperliquidAdapter', suffix: '' },
          dydx: { adapter: 'DydxAdapter', suffix: '-USD' },
          vertex: { adapter: 'VertexAdapter', suffix: '' },
          gmx: { adapter: 'GmxAdapter', suffix: '' }
        }.freeze

        # Top symbols to monitor funding
        DEFAULT_SYMBOLS = %w[BTC ETH SOL XRP DOGE AVAX LINK DOT MATIC ADA].freeze

        def initialize(symbols: nil)
          @symbols = symbols || DEFAULT_SYMBOLS
          @logger = ArbitrageBot.logger
          @adapters = {}
        end

        # Collect funding rates from all venues for all symbols
        # @return [Array<Hash>] array of funding rate data
        def collect_all
          results = []

          @symbols.each do |symbol|
            rates = collect_for_symbol(symbol)
            results.concat(rates)
          end

          results
        end

        # Collect funding rates for a single symbol
        # @param symbol [String] base symbol like 'BTC', 'ETH'
        # @return [Array<Hash>] funding rates from all venues
        def collect_for_symbol(symbol)
          results = []

          # Collect from CEX perps
          CEX_PERPS.each do |venue_key, config|
            rate = fetch_rate(venue_key, config, symbol, :cex_perp)
            results << rate if rate
          end

          # Collect from perp DEXes
          PERP_DEXES.each do |venue_key, config|
            rate = fetch_rate(venue_key, config, symbol, :dex_perp)
            results << rate if rate
          end

          results
        end

        # Get current rates summary (highest and lowest)
        # @param symbol [String] base symbol
        # @return [Hash] summary with max/min rates
        def rates_summary(symbol)
          rates = collect_for_symbol(symbol)
          return nil if rates.empty?

          sorted = rates.sort_by { |r| -r[:rate].to_f }

          {
            symbol: symbol,
            max: sorted.first,
            min: sorted.last,
            spread: (sorted.first[:rate] - sorted.last[:rate]).to_f.round(6),
            venues_count: rates.size,
            collected_at: Time.now
          }
        end

        # Get all cached funding rates (from Redis)
        # @return [Array<Hash>] all cached rates
        def all_rates
          json = ArbitrageBot.redis.get('funding:rates')
          return [] unless json

          data = JSON.parse(json, symbolize_names: true)
          data.is_a?(Array) ? data : []
        rescue StandardError => e
          @logger.debug("[FundingCollector] all_rates error: #{e.message}")
          []
        end

        private

        def fetch_rate(venue_key, config, symbol, venue_type)
          adapter = get_adapter(config[:adapter])
          return nil unless adapter

          perp_symbol = format_perp_symbol(symbol, config[:suffix], venue_key)

          begin
            rate_data = adapter.funding_rate(perp_symbol)
            return nil unless rate_data && rate_data[:rate]

            {
              symbol: symbol,
              venue: venue_key.to_s,
              venue_type: venue_type.to_s,
              perp_symbol: perp_symbol,
              rate: rate_data[:rate],
              annualized_pct: annualize_rate(rate_data[:rate], rate_data[:interval_hours] || 8),
              next_funding_ts: rate_data[:next_funding_time] ? Time.at(rate_data[:next_funding_time] / 1000) : nil,
              period_hours: rate_data[:interval_hours] || 8,
              collected_at: Time.now
            }
          rescue StandardError => e
            @logger.debug("[FundingCollector] #{venue_key}/#{symbol} error: #{e.message}")
            nil
          end
        end

        def get_adapter(adapter_name)
          @adapters[adapter_name] ||= begin
            klass = Adapters::Cex.const_get(adapter_name)
            klass.new
          rescue NameError
            begin
              klass = Adapters::PerpDex.const_get(adapter_name)
              klass.new
            rescue NameError
              @logger.warn("[FundingCollector] Adapter not found: #{adapter_name}")
              nil
            end
          end
        end

        def format_perp_symbol(symbol, suffix, venue_key)
          case venue_key
          when :okx_futures
            "#{symbol}#{suffix}"
          when :dydx
            "#{symbol}#{suffix}"
          when :hyperliquid, :vertex, :gmx
            symbol
          else
            "#{symbol}#{suffix}"
          end
        end

        def annualize_rate(rate, period_hours)
          return nil unless rate

          periods_per_year = (365.0 * 24) / period_hours
          (rate.to_f * periods_per_year * 100).round(2)
        end
      end
    end
  end
end
