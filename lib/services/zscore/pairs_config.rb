# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Configuration for z-score pairs trading
      # Thresholds are externalized via settings.yml / Redis / ENV
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

        # Default Z-score thresholds (can be overridden via settings)
        DEFAULT_ENTRY_THRESHOLD = 2.0      # |z| > 2.0 to enter
        DEFAULT_STOP_THRESHOLD = 3.5       # |z| > 3.5 to stop out
        DEFAULT_EXIT_THRESHOLD = 0.5       # |z| < 0.5 to exit

        # Rolling window defaults
        DEFAULT_LOOKBACK_DAYS = 90
        DEFAULT_MIN_DATA_POINTS = 30

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

          # Get thresholds from settings (externalized)
          # @return [Hash] entry, stop, exit thresholds
          def thresholds
            settings = load_settings
            {
              entry: settings[:zscore_entry_threshold] || DEFAULT_ENTRY_THRESHOLD,
              stop: settings[:zscore_stop_threshold] || DEFAULT_STOP_THRESHOLD,
              exit: settings[:zscore_exit_threshold] || DEFAULT_EXIT_THRESHOLD
            }
          end

          # Get lookback days from settings
          # @return [Integer] lookback period in days
          def lookback_days
            settings = load_settings
            settings[:zscore_lookback_days] || DEFAULT_LOOKBACK_DAYS
          end

          # Get minimum data points from settings
          # @return [Integer] minimum data points
          def min_data_points
            settings = load_settings
            settings[:zscore_min_data_points] || DEFAULT_MIN_DATA_POINTS
          end

          # Update thresholds at runtime (persists to Redis)
          # @param entry [Float] entry threshold
          # @param stop [Float] stop threshold
          # @param exit [Float] exit threshold
          def update_thresholds(entry: nil, stop: nil, exit_val: nil)
            settings_loader = SettingsLoader.new
            settings_loader.load

            settings_loader.set(:zscore_entry_threshold, entry) if entry
            settings_loader.set(:zscore_stop_threshold, stop) if stop
            settings_loader.set(:zscore_exit_threshold, exit_val) if exit_val

            # Clear cached settings
            @cached_settings = nil

            thresholds
          end

          # Format thresholds for display
          # @return [String] formatted message
          def format_thresholds
            t = thresholds
            <<~MSG.strip
              📊 Z-SCORE THRESHOLDS:
                 Entry: |z| > #{t[:entry]}
                 Stop:  |z| > #{t[:stop]}
                 Exit:  |z| < #{t[:exit]}
                 Lookback: #{lookback_days} days
                 Min points: #{min_data_points}
            MSG
          end

          private

          def load_pairs
            # Could load from config file in future
            DEFAULT_PAIRS.dup
          end

          def load_settings
            return @cached_settings if @cached_settings

            begin
              loader = SettingsLoader.new
              @cached_settings = loader.load
            rescue StandardError => e
              ArbitrageBot.logger.debug("[PairsConfig] Settings load error: #{e.message}")
              @cached_settings = {}
            end

            @cached_settings
          end
        end
      end
    end
  end
end
