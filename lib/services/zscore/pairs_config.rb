# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Configuration for z-score pairs trading
      class PairsConfig
        # Default pairs for statistical arbitrage
        # Format: [base_symbol, quote_symbol, description]
        DEFAULT_PAIRS = [
          ['BTC', 'ETH', 'Bitcoin vs Ethereum - major cryptos'],
          ['SOL', 'ETH', 'Solana vs Ethereum - L1 comparison'],
          ['LTC', 'BCH', 'Litecoin vs Bitcoin Cash - BTC forks'],
          ['LINK', 'UNI', 'Chainlink vs Uniswap - DeFi tokens'],
          ['AVAX', 'SOL', 'Avalanche vs Solana - alt L1s'],
          ['MATIC', 'ARB', 'Polygon vs Arbitrum - L2s'],
          ['DOGE', 'SHIB', 'Doge vs Shiba - meme coins']
        ].freeze

        # Z-score thresholds
        ENTRY_THRESHOLD = 2.0      # |z| > 2.0 to enter
        STOP_THRESHOLD = 3.5       # |z| > 3.5 to stop out
        EXIT_THRESHOLD = 0.5       # |z| < 0.5 to exit

        # Rolling window for mean/std calculation
        LOOKBACK_DAYS = 90
        MIN_DATA_POINTS = 30       # Minimum points before calculating z-score

        class << self
          def pairs
            @pairs ||= load_pairs
          end

          def pair_symbols
            pairs.map { |p| "#{p[0]}/#{p[1]}" }
          end

          def find_pair(pair_str)
            base, quote = pair_str.upcase.split('/')
            pairs.find { |p| p[0] == base && p[1] == quote }
          end

          def thresholds
            {
              entry: ENTRY_THRESHOLD,
              stop: STOP_THRESHOLD,
              exit: EXIT_THRESHOLD
            }
          end

          def lookback_days
            LOOKBACK_DAYS
          end

          def min_data_points
            MIN_DATA_POINTS
          end

          private

          def load_pairs
            # Could load from config file in future
            DEFAULT_PAIRS.dup
          end
        end
      end
    end
  end
end
