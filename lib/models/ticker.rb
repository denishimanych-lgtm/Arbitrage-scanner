# frozen_string_literal: true

module ArbitrageBot
  module Models
    class Ticker
      attr_accessor :symbol, :contracts, :venues, :arbitrage_pairs, :updated_at, :is_valid, :validation_errors

      def initialize(attrs = {})
        @symbol = attrs[:symbol]
        @contracts = attrs[:contracts] || {}
        @venues = attrs[:venues] || default_venues
        @arbitrage_pairs = attrs[:arbitrage_pairs] || []
        @updated_at = attrs[:updated_at] || Time.now
        @is_valid = attrs[:is_valid].nil? ? true : attrs[:is_valid]
        @validation_errors = attrs[:validation_errors] || []
      end

      def to_h
        {
          symbol: @symbol,
          contracts: @contracts,
          venues: @venues,
          arbitrage_pairs: @arbitrage_pairs,
          updated_at: @updated_at.is_a?(Time) ? @updated_at.iso8601 : @updated_at,
          is_valid: @is_valid,
          validation_errors: @validation_errors
        }
      end

      def to_json(*args)
        to_h.to_json(*args)
      end

      def self.from_h(hash)
        hash = hash.transform_keys(&:to_sym)
        new(
          symbol: hash[:symbol],
          contracts: hash[:contracts] || {},
          venues: hash[:venues] || {},
          arbitrage_pairs: hash[:arbitrage_pairs] || [],
          updated_at: hash[:updated_at] ? Time.parse(hash[:updated_at].to_s) : Time.now,
          is_valid: hash[:is_valid],
          validation_errors: hash[:validation_errors] || []
        )
      end

      def self.from_json(json)
        from_h(JSON.parse(json))
      end

      # Add a CEX futures venue
      def add_cex_futures(exchange:, symbol:, status: 'active')
        @venues[:cex_futures] ||= []
        @venues[:cex_futures] << {
          exchange: exchange,
          symbol: symbol,
          status: status
        }
      end

      # Add a CEX spot venue
      def add_cex_spot(exchange:, symbol:, networks: [], deposit_enabled: true, withdraw_enabled: true)
        @venues[:cex_spot] ||= []
        @venues[:cex_spot] << {
          exchange: exchange,
          symbol: symbol,
          networks: networks,
          deposit_enabled: deposit_enabled,
          withdraw_enabled: withdraw_enabled
        }
      end

      # Add a DEX spot venue
      def add_dex_spot(dex:, chain:, pool_address: nil, has_liquidity: true, liquidity_usd: nil)
        @venues[:dex_spot] ||= []
        @venues[:dex_spot] << {
          dex: dex,
          chain: chain,
          pool_address: pool_address,
          has_liquidity: has_liquidity,
          liquidity_usd: liquidity_usd
        }
      end

      # Add a Perp DEX venue
      def add_perp_dex(dex:, symbol:, status: 'active')
        @venues[:perp_dex] ||= []
        @venues[:perp_dex] << {
          dex: dex,
          symbol: symbol,
          status: status
        }
      end

      # Add contract address for a chain
      def add_contract(chain:, address:)
        @contracts[chain.to_s] = address
      end

      # Get all venues flattened with type info
      def all_venues
        result = []

        (@venues[:cex_futures] || []).each do |v|
          result << v.merge(type: :cex_futures, venue_id: "#{v[:exchange]}_futures")
        end

        (@venues[:cex_spot] || []).each do |v|
          result << v.merge(type: :cex_spot, venue_id: "#{v[:exchange]}_spot")
        end

        (@venues[:dex_spot] || []).each do |v|
          result << v.merge(type: :dex_spot, venue_id: "#{v[:dex]}_#{v[:chain]}")
        end

        (@venues[:perp_dex] || []).each do |v|
          result << v.merge(type: :perp_dex, venue_id: "#{v[:dex]}_perp")
        end

        result
      end

      # Check if ticker has any shortable venue
      def has_shortable_venue?
        (@venues[:cex_futures]&.any? { |v| v[:status] == 'active' }) ||
          (@venues[:perp_dex]&.any? { |v| v[:status] == 'active' })
      end

      # Get venue count by type
      def venue_counts
        {
          cex_futures: @venues[:cex_futures]&.size || 0,
          cex_spot: @venues[:cex_spot]&.size || 0,
          dex_spot: @venues[:dex_spot]&.size || 0,
          perp_dex: @venues[:perp_dex]&.size || 0
        }
      end

      private

      def default_venues
        {
          cex_futures: [],
          cex_spot: [],
          dex_spot: [],
          perp_dex: []
        }
      end
    end
  end
end
