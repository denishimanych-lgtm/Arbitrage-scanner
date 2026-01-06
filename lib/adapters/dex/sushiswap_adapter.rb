# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class SushiswapAdapter < BaseAdapter
        SUBGRAPH_URL = 'https://api.thegraph.com/subgraphs/name/sushi-v3/v3-ethereum'

        WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
        USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'

        def dex_id
          'sushiswap'
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
            has_liquidity: best_pool['totalValueLockedUSD'].to_f > 5000,
            symbol: token['symbol']
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          pools = find_pools(input_mint, output_mint)

          return nil if pools.empty?

          pool = pools.first
          price = estimate_price_from_pool(pool, input_mint, output_mint)

          out_amount = (amount.to_f * price).to_i

          {
            in_amount: amount,
            out_amount: out_amount,
            price: 1.0 / price,
            price_impact_pct: estimate_price_impact(pool, amount),
            route: 'sushiswap-v3'
          }
        end

        private

        def graphql_query(query)
          post(SUBGRAPH_URL, body: { query: query })
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
                token0 { id symbol }
                token1 { id symbol }
                token0Price
                token1Price
                totalValueLockedUSD
              }
            }
          GRAPHQL

          data = graphql_query(query)
          data.dig('data', 'pools') || []
        end

        def estimate_price_from_pool(pool, input_mint, _output_mint)
          if pool['token0']['id'].downcase == input_mint.downcase
            pool['token1Price'].to_f
          else
            pool['token0Price'].to_f
          end
        end

        def estimate_price_impact(pool, amount)
          tvl = pool['totalValueLockedUSD'].to_f
          return 100.0 if tvl.zero?

          (amount.to_f / 1e18 / (2 * tvl) * 100).round(4)
        end
      end
    end
  end
end
