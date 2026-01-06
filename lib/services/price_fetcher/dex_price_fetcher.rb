# frozen_string_literal: true

module ArbitrageBot
  module Services
    module PriceFetcher
      class DexPriceFetcher
        PriceData = Struct.new(
          :symbol, :price, :price_impact_pct, :output_amount,
          :dex, :chain, :received_at,
          keyword_init: true
        )

        # Standard quote amounts in USD
        QUOTE_AMOUNTS_USD = [100, 500, 1000, 2500, 5000, 10_000].freeze

        # USDC decimals by chain
        USDC_DECIMALS = {
          'solana' => 6,
          'ethereum' => 6,
          'bsc' => 18,
          'arbitrum' => 6,
          'avalanche' => 6
        }.freeze

        def initialize
          @adapters = {}
        end

        # Fetch price for a token on a specific DEX
        def fetch(dex, token_address, amount_usd = 1000)
          adapter = get_adapter(dex)
          usdc = adapter.usdc_address
          chain = adapter.chain

          amount = usd_to_base_units(amount_usd, chain)

          response = adapter.quote(
            input_mint: usdc,
            output_mint: token_address,
            amount: amount
          )

          return nil unless response

          price = calculate_price(response, amount_usd)

          PriceData.new(
            symbol: nil,
            price: price,
            price_impact_pct: response[:price_impact_pct],
            output_amount: response[:out_amount],
            dex: dex,
            chain: chain,
            received_at: (Time.now.to_f * 1000).to_i
          )
        end

        # Fetch depth profile (prices at different amounts)
        def fetch_depth_profile(dex, token_address)
          adapter = get_adapter(dex)
          usdc = adapter.usdc_address
          chain = adapter.chain
          received_at = (Time.now.to_f * 1000).to_i

          depth_data = QUOTE_AMOUNTS_USD.map do |amount_usd|
            begin
              amount = usd_to_base_units(amount_usd, chain)

              response = adapter.quote(
                input_mint: usdc,
                output_mint: token_address,
                amount: amount
              )

              next nil unless response

              {
                amount_usd: amount_usd,
                price: calculate_price(response, amount_usd),
                price_impact_pct: response[:price_impact_pct],
                output_amount: response[:out_amount]
              }
            rescue StandardError
              nil
            end
          end.compact

          return nil if depth_data.empty?

          {
            dex: dex,
            chain: chain,
            depth_data: depth_data,
            best_price: depth_data.first[:price],
            received_at: received_at
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

        def calculate_price(response, amount_usd)
          return BigDecimal('0') if response[:out_amount].to_i.zero?

          # Price = USD spent / tokens received
          BigDecimal(amount_usd.to_s) / BigDecimal(response[:out_amount].to_s)
        end
      end
    end
  end
end
