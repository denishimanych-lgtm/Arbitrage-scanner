# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      # Calculates safety buffer for manual arbitrage based on volatility and transfer time
      # Used to ensure spread > expected adverse price move during token transfer
      class VolatilityBuffer
        # Volatility per minute (%) by asset - calibrated from historical data
        # Higher = more volatile = larger buffer needed
        VOLATILITY_PER_MIN = {
          'BTC' => 0.15,
          'ETH' => 0.20,
          'SOL' => 0.30,
          'BNB' => 0.20,
          'XRP' => 0.35,
          'ADA' => 0.35,
          'DOGE' => 0.50,
          'SHIB' => 0.60,
          'AVAX' => 0.35,
          'DOT' => 0.30,
          'MATIC' => 0.35,
          'LINK' => 0.30,
          'UNI' => 0.35,
          'ATOM' => 0.30,
          'LTC' => 0.25,
          'BCH' => 0.25,
          'NEAR' => 0.40,
          'APT' => 0.45,
          'ARB' => 0.40,
          'OP' => 0.40,
          'FIL' => 0.40,
          'ICP' => 0.45,
          'HBAR' => 0.40,
          'VET' => 0.40,
          'ALGO' => 0.35,
          'FTM' => 0.50,
          'SAND' => 0.50,
          'MANA' => 0.50,
          'AXS' => 0.55,
          'AAVE' => 0.35,
          'MKR' => 0.30,
          'CRV' => 0.45,
          'LDO' => 0.45,
          'SNX' => 0.45,
          'COMP' => 0.40,
          'YFI' => 0.40,
          'SUSHI' => 0.50,
          'default' => 0.40  # Conservative default for unknown assets
        }.freeze

        # Transfer time in minutes by network
        # Time from withdraw initiation to deposit confirmation
        TRANSFER_TIME_MIN = {
          'SOL' => 1,        # Solana - very fast
          'SOLANA' => 1,
          'ARB' => 2,        # Arbitrum
          'ARBITRUM' => 2,
          'OP' => 2,         # Optimism
          'OPTIMISM' => 2,
          'BASE' => 2,       # Base
          'AVAXC' => 2,      # Avalanche C-Chain
          'AVAX' => 2,
          'MATIC' => 5,      # Polygon
          'POLYGON' => 5,
          'BSC' => 3,        # BNB Smart Chain
          'BEP20' => 3,
          'FTM' => 3,        # Fantom
          'FANTOM' => 3,
          'NEAR' => 2,       # NEAR
          'TRX' => 3,        # Tron
          'TRON' => 3,
          'TRC20' => 3,
          'ALGO' => 4,       # Algorand
          'XLM' => 5,        # Stellar
          'ATOM' => 7,       # Cosmos
          'COSMOS' => 7,
          'DOT' => 10,       # Polkadot
          'ERC20' => 12,     # Ethereum mainnet
          'ETH' => 12,
          'ETHEREUM' => 12,
          'LTC' => 15,       # Litecoin
          'BCH' => 30,       # Bitcoin Cash
          'BTC' => 40,       # Bitcoin - slowest
          'BITCOIN' => 40,
          'default' => 15    # Conservative default
        }.freeze

        # Safety multiplier - how many standard deviations of protection
        # 3 sigma = 99.7% confidence interval
        SAFETY_MULTIPLIER = 3.0

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Calculate required safety buffer for a manual arbitrage trade
        # @param symbol [String] trading symbol (e.g., 'BTC', 'ETH')
        # @param network [String] transfer network (e.g., 'SOL', 'ETH', 'ARB')
        # @return [Hash] buffer details
        def calculate_buffer(symbol, network = nil)
          vol_per_min = volatility_for(symbol)
          transfer_time = transfer_time_for(network || guess_network(symbol))

          # Expected volatility during transfer = √(time) × vol_per_min
          # (Brownian motion - volatility scales with √time)
          expected_vol = Math.sqrt(transfer_time) * vol_per_min

          # Safety buffer = expected_vol × safety_multiplier
          safety_buffer = expected_vol * SAFETY_MULTIPLIER

          {
            symbol: symbol,
            network: network,
            volatility_per_min: vol_per_min,
            transfer_time_min: transfer_time,
            expected_volatility_pct: expected_vol.round(3),
            safety_buffer_pct: safety_buffer.round(3),
            min_spread_required_pct: safety_buffer.round(2)
          }
        end

        # Check if spread is sufficient for manual arbitrage
        # @param symbol [String] trading symbol
        # @param spread_pct [Float] current spread percentage
        # @param network [String] transfer network
        # @return [Hash] validation result
        def validate_spread(symbol, spread_pct, network = nil)
          buffer = calculate_buffer(symbol, network)
          sufficient = spread_pct >= buffer[:safety_buffer_pct]

          {
            valid: sufficient,
            spread_pct: spread_pct,
            required_pct: buffer[:safety_buffer_pct],
            margin_pct: (spread_pct - buffer[:safety_buffer_pct]).round(2),
            buffer_details: buffer,
            message: if sufficient
                       "Spread #{spread_pct}% > buffer #{buffer[:safety_buffer_pct]}% ✓"
                     else
                       "Spread #{spread_pct}% < buffer #{buffer[:safety_buffer_pct]}% - RISKY"
                     end
          }
        end

        # Get best network for transfer (fastest with acceptable fees)
        # @param available_networks [Array<String>] networks available on both exchanges
        # @return [String] recommended network
        def best_network(available_networks)
          return nil if available_networks.nil? || available_networks.empty?

          # Sort by transfer time, pick fastest
          available_networks.min_by { |n| transfer_time_for(n.to_s.upcase) }
        end

        # Format buffer info for alert message
        # @param symbol [String] trading symbol
        # @param network [String] transfer network
        # @return [String] formatted message
        def format_for_alert(symbol, network = nil)
          buffer = calculate_buffer(symbol, network)

          <<~MSG.strip
            ⏱ TRANSFER RISK:
               Network: #{buffer[:network] || 'auto'}
               Time: ~#{buffer[:transfer_time_min]} min
               Volatility: #{buffer[:volatility_per_min]}%/min
               Safety buffer: #{buffer[:safety_buffer_pct]}%
          MSG
        end

        private

        def volatility_for(symbol)
          normalized = symbol.to_s.upcase.gsub(/USDT?$/, '')
          VOLATILITY_PER_MIN[normalized] || VOLATILITY_PER_MIN['default']
        end

        def transfer_time_for(network)
          normalized = network.to_s.upcase
          TRANSFER_TIME_MIN[normalized] || TRANSFER_TIME_MIN['default']
        end

        # Guess the native network for a symbol
        def guess_network(symbol)
          normalized = symbol.to_s.upcase.gsub(/USDT?$/, '')

          case normalized
          when 'BTC' then 'BTC'
          when 'ETH' then 'ETH'
          when 'SOL' then 'SOL'
          when 'BNB' then 'BSC'
          when 'MATIC' then 'MATIC'
          when 'AVAX' then 'AVAXC'
          when 'FTM' then 'FTM'
          when 'ARB' then 'ARB'
          when 'OP' then 'OP'
          when 'NEAR' then 'NEAR'
          when 'ATOM' then 'ATOM'
          when 'DOT' then 'DOT'
          when 'ALGO' then 'ALGO'
          when 'XLM' then 'XLM'
          when 'TRX' then 'TRX'
          when 'LTC' then 'LTC'
          when 'BCH' then 'BCH'
          else 'ERC20' # Default to Ethereum for ERC20 tokens
          end
        end
      end
    end
  end
end
