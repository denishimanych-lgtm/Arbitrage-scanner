# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Alerts
      # Groups signals by symbol for consolidated alerting
      # Instead of 5 alerts for FLOW, sends 1 with best pair + alternatives
      class SignalGrouper
        def initialize
          @logger = ArbitrageBot.logger
        end

        # Group raw signals by symbol
        # @param signals [Array<Hash>] raw signals from queue
        # @return [Hash<String, Array>] { symbol => [signals sorted by spread desc] }
        def group_by_symbol(signals)
          signals
            .group_by { |s| s['symbol'] || s[:symbol] }
            .transform_values { |v| sort_by_spread(v) }
        end

        # For each symbol, returns best signal + alternatives
        # @param signals [Array<Hash>] raw signals
        # @return [Array<Hash>] [{ symbol:, best:, others: }]
        def best_with_alternatives(signals)
          grouped = group_by_symbol(signals)

          grouped.map do |symbol, group|
            {
              symbol: symbol,
              best: group.first,
              others: group[1..4] || [] # Top 5, excluding first
            }
          end
        end

        # Group validated signals (after processing)
        # @param validated_signals [Array<ValidatedSignal>] processed signals
        # @return [Array<Hash>] [{ symbol:, best:, others: }]
        def group_validated(validated_signals)
          grouped = validated_signals.group_by(&:symbol)

          grouped.map do |symbol, group|
            sorted = group.sort_by { |s| -(s.spread[:real_pct] || 0).abs }
            {
              symbol: symbol,
              best: sorted.first,
              others: sorted[1..4] || []
            }
          end
        end

        private

        def sort_by_spread(signals)
          signals.sort_by do |s|
            spread = s['spread_pct'] || s[:spread_pct] || 0
            -spread.to_f.abs
          end
        end
      end
    end
  end
end
