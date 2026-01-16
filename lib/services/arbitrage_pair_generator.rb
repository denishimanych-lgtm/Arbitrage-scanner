# frozen_string_literal: true

module ArbitrageBot
  module Services
    class ArbitragePairGenerator
      # Venue types that support shorting
      SHORTABLE_VENUE_TYPES = %i[cex_futures perp_dex].freeze

      # Preferred transfer networks in order of priority
      PREFERRED_NETWORKS = %w[solana arbitrum bsc avalanche ethereum].freeze

      ArbitragePair = Struct.new(
        :id, :symbol, :type, :low_venue, :high_venue,
        :requires_transfer, :transfer_network, :created_at,
        keyword_init: true
      )

      def generate(ticker)
        pairs = []
        all_venues = ticker.all_venues

        # Skip if less than 2 venues
        return pairs if all_venues.size < 2

        # Deduplicate venues by venue_id
        unique_venues = all_venues.uniq { |v| v[:venue_id] }

        # Generate all combinations
        unique_venues.combination(2).each do |venue1, venue2|
          # Skip if same venue_id (shouldn't happen after dedup, but safety check)
          next if venue1[:venue_id] == venue2[:venue_id]

          pair = build_pair(ticker, venue1, venue2)
          pairs << pair if pair
        end

        pairs
      end

      private

      def build_pair(ticker, venue1, venue2)
        v1_shortable = SHORTABLE_VENUE_TYPES.include?(venue1[:type])
        v2_shortable = SHORTABLE_VENUE_TYPES.include?(venue2[:type])

        # Determine pair type and direction
        if v1_shortable && v2_shortable
          # Both shortable - can go either direction
          build_auto_pair(ticker, venue1, venue2, :bidirectional)
        elsif v1_shortable
          # venue1 is high (short), venue2 is low (long)
          build_auto_pair(ticker, venue2, venue1, :unidirectional)
        elsif v2_shortable
          # venue2 is high (short), venue1 is low (long)
          build_auto_pair(ticker, venue1, venue2, :unidirectional)
        else
          # Neither shortable - manual arbitrage
          build_manual_pair(ticker, venue1, venue2)
        end
      end

      def build_auto_pair(ticker, low_venue, high_venue, direction)
        pair_id = generate_pair_id(low_venue, high_venue)

        ArbitragePair.new(
          id: pair_id,
          symbol: ticker.symbol,
          type: :auto,
          low_venue: format_venue(low_venue),
          high_venue: format_venue(high_venue),
          requires_transfer: requires_transfer?(low_venue, high_venue),
          transfer_network: find_transfer_network(ticker, low_venue, high_venue),
          created_at: Time.now.iso8601
        )
      end

      def build_manual_pair(ticker, venue1, venue2)
        # For manual pairs, determine which is "low" based on typical spread patterns
        # DEX usually has higher prices than CEX due to slippage
        low_venue, high_venue = order_manual_venues(venue1, venue2)

        pair_id = generate_pair_id(low_venue, high_venue)

        ArbitragePair.new(
          id: pair_id,
          symbol: ticker.symbol,
          type: :manual,
          low_venue: format_venue(low_venue),
          high_venue: format_venue(high_venue),
          requires_transfer: requires_transfer?(low_venue, high_venue),
          transfer_network: find_transfer_network(ticker, low_venue, high_venue),
          created_at: Time.now.iso8601
        )
      end

      def order_manual_venues(venue1, venue2)
        # Priority: CEX spot < DEX spot (CEX typically cheaper)
        priority = { cex_spot: 1, dex_spot: 2 }

        p1 = priority[venue1[:type]] || 0
        p2 = priority[venue2[:type]] || 0

        p1 <= p2 ? [venue1, venue2] : [venue2, venue1]
      end

      def requires_transfer?(venue1, venue2)
        # Transfer required if venues are on different platforms
        return false if same_platform?(venue1, venue2)

        # No transfer needed between CEX futures and spot on same exchange
        return false if same_exchange_spot_futures?(venue1, venue2)

        true
      end

      def same_platform?(venue1, venue2)
        venue1[:venue_id] == venue2[:venue_id]
      end

      def same_exchange_spot_futures?(venue1, venue2)
        return false unless [venue1[:type], venue2[:type]].sort == %i[cex_futures cex_spot]

        exchange1 = venue1[:exchange]
        exchange2 = venue2[:exchange]

        exchange1 == exchange2
      end

      def find_transfer_network(ticker, low_venue, high_venue)
        return nil unless requires_transfer?(low_venue, high_venue)

        # Find common networks between venues
        low_networks = extract_networks(low_venue)
        high_networks = extract_networks(high_venue)

        # If either venue is DEX, the network is the chain
        if low_venue[:type] == :dex_spot
          return low_venue[:chain]
        end
        if high_venue[:type] == :dex_spot
          return high_venue[:chain]
        end

        # Find intersection of available networks
        common = low_networks & high_networks

        return nil if common.empty?

        # Return preferred network
        PREFERRED_NETWORKS.find { |n| common.include?(n) } || common.first
      end

      def extract_networks(venue)
        case venue[:type]
        when :dex_spot
          [venue[:chain]]
        when :cex_spot
          venue[:networks]&.map { |n| n.is_a?(Hash) ? n[:chain] : n } || []
        when :cex_futures, :perp_dex
          # Futures don't have direct networks for transfer
          []
        else
          []
        end
      end

      def format_venue(venue)
        {
          type: venue[:type],
          venue_id: venue[:venue_id],
          exchange: venue[:exchange],
          dex: venue[:dex],
          symbol: venue[:symbol],
          chain: venue[:chain]
        }.compact
      end

      def generate_pair_id(low_venue, high_venue)
        "#{low_venue[:venue_id]}:#{high_venue[:venue_id]}"
      end
    end
  end
end
