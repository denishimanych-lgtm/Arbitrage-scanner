# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class OrcaAdapter < BaseAdapter
        API_URL = 'https://api.orca.so'
        WHIRLPOOL_URL = 'https://api.mainnet.orca.so/v1'

        USDC_MINT = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
        WSOL_MINT = 'So11111111111111111111111111111111111111112'

        def dex_id
          'orca'
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
          # Get whirlpools containing this token
          pools = whirlpools_by_token(contract_address)

          return nil if pools.empty?

          best_pool = pools.max_by { |p| p[:tvl] }
          {
            found: true,
            mint: contract_address,
            pool_address: best_pool[:address],
            liquidity_usd: best_pool[:tvl],
            has_liquidity: best_pool[:tvl] > 1000
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          # Orca uses whirlpool quote API
          url = "#{WHIRLPOOL_URL}/whirlpool/quote?" \
                "inputMint=#{input_mint}&outputMint=#{output_mint}" \
                "&amount=#{amount}&amountIsInput=true&slippage=#{slippage_bps / 100.0}"

          data = get(url)

          {
            in_amount: data['inAmount'].to_i,
            out_amount: data['outAmount'].to_i,
            price: calculate_price(data),
            price_impact_pct: data['priceImpact'].to_f * 100,
            route: 'orca-whirlpool'
          }
        rescue ApiError
          nil
        end

        def whirlpools_by_token(token_mint)
          data = get("#{WHIRLPOOL_URL}/whirlpool/list")

          return [] unless data['whirlpools']

          data['whirlpools']
            .select { |p| p['tokenA']['mint'] == token_mint || p['tokenB']['mint'] == token_mint }
            .map do |p|
              {
                address: p['address'],
                tvl: p['tvl'].to_f,
                volume_24h: p['volume24h'].to_f,
                token_a: p['tokenA']['mint'],
                token_b: p['tokenB']['mint']
              }
            end
        end

        private

        def calculate_price(quote_data)
          return 0 if quote_data['outAmount'].to_i.zero?

          in_amount = quote_data['inAmount'].to_f
          out_amount = quote_data['outAmount'].to_f

          in_amount / out_amount
        end
      end
    end
  end
end
