# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class JupiterAdapter < BaseAdapter
        # Jupiter API endpoints (v6 is the latest stable)
        # Using public endpoints - may have rate limits
        API_URL = 'https://quote-api.jup.ag/v6'
        PRICE_URL = 'https://api.jup.ag/price/v2'  # Updated to v2
        TOKEN_LIST_URL = 'https://token.jup.ag/all'

        # Fallback timeout for DNS issues
        DNS_TIMEOUT = 5

        USDC_MINT = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
        WSOL_MINT = 'So11111111111111111111111111111111111111112'

        def dex_id
          'jupiter'
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
          # Try to get a quote to verify token exists and has liquidity
          quote = quote(
            input_mint: USDC_MINT,
            output_mint: contract_address,
            amount: 1_000_000 # 1 USDC
          )

          return nil unless quote

          {
            found: true,
            mint: contract_address,
            liquidity_usd: estimate_liquidity(contract_address),
            has_liquidity: true
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          url = "#{API_URL}/quote?inputMint=#{input_mint}&outputMint=#{output_mint}" \
                "&amount=#{amount}&slippageBps=#{slippage_bps}"

          data = get(url)

          {
            in_amount: data['inAmount'].to_i,
            out_amount: data['outAmount'].to_i,
            price: calculate_price(data),
            price_impact_pct: data['priceImpactPct'].to_f,
            route: data['routePlan']&.map { |r| r['swapInfo']['label'] }&.join(' -> ')
          }
        end

        def price(token_mint)
          url = "#{PRICE_URL}/price?ids=#{token_mint}"
          data = get(url)

          price_data = data['data'][token_mint]
          return nil unless price_data

          {
            price: BigDecimal(price_data['price'].to_s),
            timestamp: Time.now.to_i
          }
        end

        def all_tokens
          @all_tokens ||= begin
            data = get(TOKEN_LIST_URL)
            data.map { |t| { address: t['address'], symbol: t['symbol'], name: t['name'] } }
          end
        end

        private

        def calculate_price(quote_data)
          return 0 if quote_data['outAmount'].to_i.zero?

          in_amount = quote_data['inAmount'].to_f
          out_amount = quote_data['outAmount'].to_f

          # Price = input / output (how much input per 1 output)
          in_amount / out_amount
        end

        def estimate_liquidity(token_mint)
          # Estimate liquidity by checking price impact at different sizes
          amounts = [10_000_000, 100_000_000, 1_000_000_000] # 10, 100, 1000 USDC

          amounts.each do |amount|
            begin
              q = quote(input_mint: USDC_MINT, output_mint: token_mint, amount: amount)
              # If price impact > 5%, previous amount is rough liquidity estimate
              return amount / 1_000_000.0 if q[:price_impact_pct] > 5.0
            rescue ApiError
              return amount / 1_000_000.0
            end
          end

          1000.0 # Default if all quotes succeed
        end
      end
    end
  end
end
