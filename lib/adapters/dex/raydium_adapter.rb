# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class RaydiumAdapter < BaseAdapter
        API_URL = 'https://api-v3.raydium.io'

        USDC_MINT = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
        WSOL_MINT = 'So11111111111111111111111111111111111111112'

        def dex_id
          'raydium'
        end

        def chain
          'solana'
        end

        def native_token_address
          WSOL_MINT
        end

        def usdc_address
          USDC_MINT
        end

        def find_token(contract_address)
          # Search in pools
          pools = get("#{API_URL}/pools/info/mint?mint1=#{contract_address}")

          return nil if pools['data'].nil? || pools['data'].empty?

          pool = pools['data'].first
          {
            found: true,
            mint: contract_address,
            pool_address: pool['id'],
            liquidity_usd: pool['tvl'].to_f,
            has_liquidity: pool['tvl'].to_f > 1000
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          url = "#{API_URL}/compute/swap-base-in?" \
                "inputMint=#{input_mint}&outputMint=#{output_mint}" \
                "&amount=#{amount}&slippageBps=#{slippage_bps}"

          data = get(url)

          return nil unless data['success']

          {
            in_amount: data['data']['inputAmount'].to_i,
            out_amount: data['data']['outputAmount'].to_i,
            price: calculate_price(data['data']),
            price_impact_pct: data['data']['priceImpactPct'].to_f,
            route: 'raydium'
          }
        end

        def pools_by_token(token_mint)
          data = get("#{API_URL}/pools/info/mint?mint1=#{token_mint}")

          return [] unless data['data']

          data['data'].map do |pool|
            {
              pool_id: pool['id'],
              tvl: pool['tvl'].to_f,
              volume_24h: pool['day']['volume'].to_f,
              mint_a: pool['mintA']['address'],
              mint_b: pool['mintB']['address']
            }
          end
        end

        private

        def calculate_price(quote_data)
          return 0 if quote_data['outputAmount'].to_i.zero?

          in_amount = quote_data['inputAmount'].to_f
          out_amount = quote_data['outputAmount'].to_f

          in_amount / out_amount
        end
      end
    end
  end
end
