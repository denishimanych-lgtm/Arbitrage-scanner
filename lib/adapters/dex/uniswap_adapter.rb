# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class UniswapAdapter < BaseAdapter
        # Using Uniswap subgraph for pool discovery
        # Note: The Graph hosted service is deprecated, using gateway requires API key
        # Set THEGRAPH_API_KEY env variable for full functionality
        SUBGRAPH_URL_TEMPLATE = 'https://gateway.thegraph.com/api/%s/subgraphs/id/5zvR82QoaXYFyDEKLZ9t6v9adgnptxYpKpSbxtgVENFV'
        FALLBACK_SUBGRAPH_URL = 'https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3'  # May return 301
        QUOTE_API_URL = 'https://api.uniswap.org/v2'

        WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
        USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
        USDT = '0xdAC17F958D2ee523a2206206994597C13D831ec7'

        def dex_id
          'uniswap'
        end

        def chain
          'ethereum'
        end

        def native_token_address
          WETH
        end

        def usdc_address
          USDC
        end

        def find_token(contract_address)
          query = <<~GRAPHQL
            {
              token(id: "#{contract_address.downcase}") {
                id
                symbol
                name
                totalValueLockedUSD
                volumeUSD
              }
              pools(
                where: {
                  or: [
                    { token0: "#{contract_address.downcase}" }
                    { token1: "#{contract_address.downcase}" }
                  ]
                }
                first: 5
                orderBy: totalValueLockedUSD
                orderDirection: desc
              ) {
                id
                totalValueLockedUSD
              }
            }
          GRAPHQL

          data = graphql_query(query)

          token = data.dig('data', 'token')
          pools = data.dig('data', 'pools')

          return nil unless token && pools&.any?

          best_pool = pools.first
          {
            found: true,
            contract: contract_address,
            pool_address: best_pool['id'],
            liquidity_usd: best_pool['totalValueLockedUSD'].to_f,
            has_liquidity: best_pool['totalValueLockedUSD'].to_f > 10_000,
            symbol: token['symbol']
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          # Using Uniswap quoter - this is simplified
          # In production, you'd use the on-chain quoter contract
          pools = find_pools(input_mint, output_mint)

          return nil if pools.empty?

          # Estimate based on pool price
          pool = pools.first
          price = estimate_price_from_pool(pool, input_mint, output_mint)

          out_amount = (amount.to_f * price).to_i

          {
            in_amount: amount,
            out_amount: out_amount,
            price: 1.0 / price,
            price_impact_pct: estimate_price_impact(pool, amount),
            route: 'uniswap-v3'
          }
        end

        private

        def graphql_query(query)
          url = subgraph_url
          post(url, body: { query: query })
        end

        def subgraph_url
          api_key = ENV['THEGRAPH_API_KEY']
          if api_key && !api_key.empty?
            format(SUBGRAPH_URL_TEMPLATE, api_key)
          else
            ArbitrageBot.logger.warn('[Uniswap] THEGRAPH_API_KEY not set, using fallback (may be rate limited)')
            FALLBACK_SUBGRAPH_URL
          end
        end

        def find_pools(token_a, token_b)
          query = <<~GRAPHQL
            {
              pools(
                where: {
                  or: [
                    { token0: "#{token_a.downcase}", token1: "#{token_b.downcase}" }
                    { token0: "#{token_b.downcase}", token1: "#{token_a.downcase}" }
                  ]
                }
                first: 3
                orderBy: totalValueLockedUSD
                orderDirection: desc
              ) {
                id
                token0 { id symbol decimals }
                token1 { id symbol decimals }
                token0Price
                token1Price
                totalValueLockedUSD
              }
            }
          GRAPHQL

          data = graphql_query(query)
          data.dig('data', 'pools') || []
        end

        def estimate_price_from_pool(pool, input_mint, output_mint)
          if pool['token0']['id'].downcase == input_mint.downcase
            pool['token1Price'].to_f
          else
            pool['token0Price'].to_f
          end
        end

        def estimate_price_impact(pool, amount)
          tvl = pool['totalValueLockedUSD'].to_f
          return 100.0 if tvl.zero?

          # Rough estimate: impact = trade_size / (2 * tvl) * 100
          (amount.to_f / 1e18 / (2 * tvl) * 100).round(4)
        end
      end
    end
  end
end
