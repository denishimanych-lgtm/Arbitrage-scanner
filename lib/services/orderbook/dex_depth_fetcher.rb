# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Orderbook
      class DexDepthFetcher
        # Quote amounts in USD for depth profiling
        QUOTE_AMOUNTS_USD = [100, 500, 1000, 2500, 5000, 10_000].freeze

        # USDC decimals by chain
        USDC_DECIMALS = {
          'solana' => 6,
          'ethereum' => 6,
          'bsc' => 18,
          'arbitrum' => 6,
          'avalanche' => 6
        }.freeze

        DepthData = Struct.new(
          :dex, :chain, :token_address, :depth_points, :best_price, :timing,
          keyword_init: true
        )

        DepthPoint = Struct.new(
          :amount_usd, :price, :price_impact_pct, :output_amount, :effective_price,
          keyword_init: true
        )

        TimingInfo = Struct.new(
          :request_at, :response_at, :latency_ms,
          keyword_init: true
        )

        def initialize
          @adapters = {}
        end

        # Fetch depth profile for a token
        def fetch(dex, token_address, quote_amounts: QUOTE_AMOUNTS_USD)
          adapter = get_adapter(dex)
          usdc = adapter.usdc_address
          chain = adapter.chain

          request_at = Time.now
          depth_points = []

          quote_amounts.each do |amount_usd|
            begin
              amount = usd_to_base_units(amount_usd, chain)

              response = adapter.quote(
                input_mint: usdc,
                output_mint: token_address,
                amount: amount
              )

              next unless response && response[:out_amount].to_i > 0

              effective_price = BigDecimal(amount_usd.to_s) / BigDecimal(response[:out_amount].to_s)

              depth_points << DepthPoint.new(
                amount_usd: amount_usd,
                price: effective_price,
                price_impact_pct: BigDecimal(response[:price_impact_pct].to_s),
                output_amount: response[:out_amount],
                effective_price: effective_price
              )
            rescue StandardError => e
              ArbitrageBot.logger.debug("DEX depth quote error #{dex}/#{amount_usd}: #{e.message}")
            end
          end

          response_at = Time.now
          latency_ms = ((response_at - request_at) * 1000).round

          return nil if depth_points.empty?

          DepthData.new(
            dex: dex,
            chain: chain,
            token_address: token_address,
            depth_points: depth_points,
            best_price: depth_points.first.price,
            timing: TimingInfo.new(
              request_at: request_at.to_f,
              response_at: response_at.to_f,
              latency_ms: latency_ms
            )
          )
        end

        # Simulate orderbook from depth data
        def to_orderbook_format(depth_data, base_price: nil)
          return nil unless depth_data&.depth_points&.any?

          base = base_price || depth_data.best_price

          # Create synthetic bid/ask levels from depth points
          asks = depth_data.depth_points.map do |point|
            qty = point.output_amount.to_f
            [point.price, BigDecimal(qty.to_s)]
          end

          # Bids are inverse (selling token for USDC)
          bids = depth_data.depth_points.map do |point|
            # Apply symmetric spread
            bid_price = point.price * BigDecimal('0.995') # 0.5% spread
            qty = point.output_amount.to_f
            [bid_price, BigDecimal(qty.to_s)]
          end.reverse

          {
            bids: bids,
            asks: asks,
            type: :dex_synthetic,
            timestamp: (Time.now.to_f * 1000).to_i
          }
        end

        private

        def get_adapter(dex)
          @adapters[dex] ||= AdapterFactory::Dex.get(dex)
        end

        def usd_to_base_units(amount_usd, chain)
          decimals = USDC_DECIMALS[chain] || 6
          (amount_usd * (10**decimals)).to_i
        end
      end
    end
  end
end
