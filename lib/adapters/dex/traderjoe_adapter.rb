# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class TraderjoeAdapter < BaseAdapter
        SUBGRAPH_URL = 'https://api.thegraph.com/subgraphs/name/traderjoe-xyz/joe-v2-avalanche'
        API_URL = 'https://api.traderjoexyz.com'

        WAVAX = '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7'
        USDC = '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E'

        def dex_id
          'traderjoe'
        end

        def chain
          'avalanche'
        end

        def native_token_address
          WAVAX
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
              lbpairs(
                where: {
                  or: [
                    { tokenX: "#{contract_address.downcase}" }
                    { tokenY: "#{contract_address.downcase}" }
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
          pairs = data.dig('data', 'lbpairs')

          return nil unless token && pairs&.any?

          best_pair = pairs.first
          {
            found: true,
            contract: contract_address,
            pool_address: best_pair['id'],
            liquidity_usd: best_pair['totalValueLockedUSD'].to_f,
            has_liquidity: best_pair['totalValueLockedUSD'].to_f > 5000,
            symbol: token['symbol']
          }
        rescue ApiError
          nil
        end

        def quote(input_mint:, output_mint:, amount:, slippage_bps: 50)
          pairs = find_pairs(input_mint, output_mint)

          return nil if pairs.empty?

          pair = pairs.first
          price = estimate_price_from_pair(pair, input_mint, output_mint)

          out_amount = (amount.to_f * price).to_i

          {
            in_amount: amount,
            out_amount: out_amount,
            price: 1.0 / price,
            price_impact_pct: estimate_price_impact(pair, amount),
            route: 'traderjoe-v2'
          }
        end

        private

        def graphql_query(query)
          post(SUBGRAPH_URL, body: { query: query })
        end

        def find_pairs(token_a, token_b)
          query = <<~GRAPHQL
            {
              lbpairs(
                where: {
                  or: [
                    { tokenX: "#{token_a.downcase}", tokenY: "#{token_b.downcase}" }
                    { tokenX: "#{token_b.downcase}", tokenY: "#{token_a.downcase}" }
                  ]
                }
                first: 3
                orderBy: totalValueLockedUSD
                orderDirection: desc
              ) {
                id
                tokenX { id symbol }
                tokenY { id symbol }
                totalValueLockedUSD
              }
            }
          GRAPHQL

          data = graphql_query(query)
          data.dig('data', 'lbpairs') || []
        end

        def estimate_price_from_pair(pair, input_mint, _output_mint)
          # TraderJoe LB pairs have different price discovery
          # This is simplified - real implementation would query active bin
          1.0
        end

        def estimate_price_impact(pair, amount)
          tvl = pair['totalValueLockedUSD'].to_f
          return 100.0 if tvl.zero?

          (amount.to_f / 1e18 / (2 * tvl) * 100).round(4)
        end
      end
    end
  end
end
