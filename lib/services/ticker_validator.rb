# frozen_string_literal: true

module ArbitrageBot
  module Services
    class TickerValidator
      ValidationResult = Struct.new(:valid, :errors, :warnings, keyword_init: true)

      def initialize
        @errors = []
        @warnings = []
      end

      def validate(ticker)
        @errors = []
        @warnings = []

        check_contract_consistency(ticker)
        check_dex_contract_match(ticker)
        check_venue_activity(ticker)
        check_minimum_venues(ticker)

        ValidationResult.new(
          valid: @errors.empty?,
          errors: @errors,
          warnings: @warnings
        )
      end

      private

      # Check that contract addresses are consistent across CEX exchanges
      def check_contract_consistency(ticker)
        cex_contracts = extract_cex_contracts(ticker)

        return if cex_contracts.empty?

        # Group by chain and check consistency
        by_chain = cex_contracts.group_by { |c| c[:chain] }

        by_chain.each do |chain, contracts|
          addresses = contracts.map { |c| c[:address]&.downcase }.compact.uniq

          if addresses.size > 1
            @errors << {
              check: :contract_consistency,
              message: "Contract mismatch on #{chain}: #{addresses.join(', ')}",
              chain: chain,
              addresses: addresses
            }
          end
        end
      end

      # Check that DEX token contracts match CEX contracts
      def check_dex_contract_match(ticker)
        return unless ticker.venues[:dex_spot]&.any?

        ticker.venues[:dex_spot].each do |dex|
          chain = dex[:chain]
          cex_contract = ticker.contracts[chain]

          next unless cex_contract && dex[:pool_address]

          # For DEX, we check if the token is in the pool
          # This is a simplified check - real implementation would verify on-chain
          dex_contract = dex[:token_contract] || dex[:pool_address]

          if cex_contract && dex_contract && cex_contract.downcase != dex_contract.downcase
            @warnings << {
              check: :dex_contract_match,
              message: "DEX #{dex[:dex]} may have different contract",
              dex: dex[:dex],
              chain: chain,
              cex_contract: cex_contract,
              dex_contract: dex_contract
            }
          end
        end
      end

      # Check that venues are active/have liquidity
      def check_venue_activity(ticker)
        # Check CEX futures
        ticker.venues[:cex_futures]&.each do |venue|
          unless venue[:status] == 'active'
            @warnings << {
              check: :venue_activity,
              message: "CEX futures #{venue[:exchange]} is not active",
              venue: venue
            }
          end
        end

        # Check CEX spot
        ticker.venues[:cex_spot]&.each do |venue|
          unless venue[:status] == 'active' || venue[:status].nil?
            @warnings << {
              check: :venue_activity,
              message: "CEX spot #{venue[:exchange]} is not active",
              venue: venue
            }
          end
        end

        # Check DEX liquidity
        ticker.venues[:dex_spot]&.each do |venue|
          unless venue[:has_liquidity]
            @errors << {
              check: :venue_activity,
              message: "DEX #{venue[:dex]} has no liquidity",
              venue: venue
            }
          end
        end

        # Check Perp DEX
        ticker.venues[:perp_dex]&.each do |venue|
          unless venue[:status] == 'active'
            @warnings << {
              check: :venue_activity,
              message: "Perp DEX #{venue[:dex]} is not active",
              venue: venue
            }
          end
        end
      end

      # Check minimum venue requirements
      def check_minimum_venues(ticker)
        total_venues = ticker.all_venues.size

        if total_venues < 2
          @errors << {
            check: :minimum_venues,
            message: 'Ticker needs at least 2 venues for arbitrage',
            venue_count: total_venues
          }
        end

        # Warning if no shortable venue
        unless ticker.has_shortable_venue?
          @warnings << {
            check: :shortable_venue,
            message: 'No shortable venue (futures/perp) - only manual arbitrage possible'
          }
        end
      end

      def extract_cex_contracts(ticker)
        contracts = []

        # From CEX spot venues that have network info
        ticker.venues[:cex_spot]&.each do |spot|
          next unless spot[:networks]

          spot[:networks].each do |network|
            next unless network.is_a?(Hash) && network[:contract]

            contracts << {
              exchange: spot[:exchange],
              chain: network[:chain],
              address: network[:contract]
            }
          end
        end

        # From ticker contracts hash
        ticker.contracts.each do |chain, address|
          contracts << {
            exchange: 'master',
            chain: chain,
            address: address
          }
        end

        contracts
      end
    end
  end
end
