# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Defi
      # Adapter for Curve Finance pools
      # Used to monitor pool imbalances as early stress signals
      class CurveAdapter
        # Curve 3pool contract on Ethereum mainnet
        THREEPOOL_ADDRESS = '0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7'

        # Token indices in 3pool
        THREEPOOL_TOKENS = {
          'DAI' => 0,
          'USDC' => 1,
          'USDT' => 2
        }.freeze

        # Curve API endpoints
        CURVE_API = 'https://api.curve.fi/api'
        DEFILLAMA_API = 'https://yields.llama.fi/pools'

        REDIS_KEY = 'curve:3pool'
        CACHE_TTL = 300  # 5 minutes

        class << self
          # Get 3pool balances and TVL
          # @return [Hash] pool data with balances
          def get_3pool
            # Try cache first
            cached = get_cached
            return cached if cached

            # Fetch fresh data
            data = fetch_3pool_data
            cache_data(data) if data
            data
          end

          # Get balance percentage for a specific stablecoin
          # @param symbol [String] DAI, USDC, or USDT
          # @return [Float, nil] percentage of pool (0-100)
          def balance_pct(symbol)
            pool = get_3pool
            return nil unless pool && pool[:balances]

            pool[:balances][symbol.upcase]&.dig(:pct)
          end

          # Check if pool is stressed (one asset > 70%)
          # @return [Hash, nil] stress info or nil if healthy
          def stress_check
            pool = get_3pool
            return nil unless pool && pool[:balances]

            stressed = pool[:balances].find { |_, v| v[:pct] && v[:pct] > 70 }
            return nil unless stressed

            {
              stressed: true,
              token: stressed[0],
              pct: stressed[1][:pct],
              message: "#{stressed[0]} at #{stressed[1][:pct].round(1)}% of pool"
            }
          end

          # Format 3pool status for alerts
          # @return [String] formatted message
          def format_3pool_status
            pool = get_3pool

            unless pool && pool[:balances]
              return "Curve 3pool: Data unavailable"
            end

            stress = stress_check
            emoji = stress ? "🔴" : "🟢"

            lines = ["#{emoji} CURVE 3POOL:"]

            %w[USDC USDT DAI].each do |token|
              bal = pool[:balances][token]
              next unless bal

              pct = bal[:pct]&.round(1) || 0
              stress_marker = pct > 70 ? " (STRESS!)" : ""
              lines << "   #{token}: #{pct}%#{stress_marker}"
            end

            if pool[:tvl]
              tvl_m = (pool[:tvl] / 1_000_000).round(1)
              lines << "   TVL: $#{tvl_m}M"
            end

            lines.join("\n")
          end

          private

          def fetch_3pool_data
            # Try Curve API first
            data = fetch_from_curve_api
            return data if data

            # Fallback to DeFiLlama
            fetch_from_defillama
          rescue StandardError => e
            ArbitrageBot.logger.error("[CurveAdapter] fetch error: #{e.message}")
            nil
          end

          def fetch_from_curve_api
            uri = URI("#{CURVE_API}/getPools/ethereum/main")

            http = Support::SslConfig.create_http(uri, timeout: 10)
            response = http.get(uri.request_uri)
            return nil unless response.code == '200'

            data = JSON.parse(response.body)
            pools = data.dig('data', 'poolData') || []

            # Find 3pool
            threepool = pools.find { |p| p['address']&.downcase == THREEPOOL_ADDRESS.downcase }
            return nil unless threepool

            parse_curve_pool(threepool)
          rescue StandardError => e
            ArbitrageBot.logger.debug("[CurveAdapter] Curve API error: #{e.message}")
            nil
          end

          def fetch_from_defillama
            uri = URI(DEFILLAMA_API)

            http = Support::SslConfig.create_http(uri, timeout: 10)
            response = http.get(uri.request_uri)
            return nil unless response.code == '200'

            data = JSON.parse(response.body)
            pools = data['data'] || []

            # Find Curve 3pool
            threepool = pools.find do |p|
              p['project'] == 'curve-dex' &&
                p['symbol']&.include?('3CRV') &&
                p['chain'] == 'Ethereum'
            end

            return nil unless threepool

            parse_defillama_pool(threepool)
          rescue StandardError => e
            ArbitrageBot.logger.debug("[CurveAdapter] DeFiLlama error: #{e.message}")
            nil
          end

          def parse_curve_pool(pool)
            coins = pool['coins'] || []
            total_usd = pool['usdTotal'].to_f

            return nil if total_usd.zero?

            balances = {}
            coins.each do |coin|
              symbol = coin['symbol']&.upcase
              next unless THREEPOOL_TOKENS.key?(symbol)

              usd_value = coin['poolBalance'].to_f * coin['usdPrice'].to_f
              balances[symbol] = {
                balance: coin['poolBalance'].to_f,
                usd: usd_value,
                pct: (usd_value / total_usd * 100)
              }
            end

            {
              address: THREEPOOL_ADDRESS,
              name: '3pool',
              tvl: total_usd,
              balances: balances,
              fetched_at: Time.now
            }
          end

          def parse_defillama_pool(pool)
            tvl = pool['tvlUsd'].to_f
            return nil if tvl.zero?

            # DeFiLlama doesn't give individual token balances
            # Estimate based on TVL (assume equal split as default)
            # This is a fallback - not as accurate
            third = tvl / 3

            {
              address: THREEPOOL_ADDRESS,
              name: '3pool',
              tvl: tvl,
              balances: {
                'DAI' => { balance: nil, usd: third, pct: 33.3 },
                'USDC' => { balance: nil, usd: third, pct: 33.3 },
                'USDT' => { balance: nil, usd: third, pct: 33.3 }
              },
              estimated: true,
              fetched_at: Time.now
            }
          end

          def get_cached
            data = ArbitrageBot.redis.get(REDIS_KEY)
            return nil unless data

            parsed = JSON.parse(data, symbolize_names: true)
            # Check if still fresh
            fetched_at = parsed[:fetched_at]
            if fetched_at && (Time.now - Time.parse(fetched_at.to_s)) < CACHE_TTL
              parsed
            end
          rescue StandardError
            nil
          end

          def cache_data(data)
            serialized = data.transform_values do |v|
              v.is_a?(Time) ? v.iso8601 : v
            end
            ArbitrageBot.redis.setex(REDIS_KEY, CACHE_TTL, serialized.to_json)
          rescue StandardError => e
            ArbitrageBot.logger.debug("[CurveAdapter] cache error: #{e.message}")
          end
        end
      end
    end
  end
end
