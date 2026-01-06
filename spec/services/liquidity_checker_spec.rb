# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArbitrageBot::Services::Safety::LiquidityChecker do
  let(:checker) { described_class.new }
  let(:signal) { build_test_signal }

  describe '#validate' do
    context 'with valid signal' do
      it 'passes all checks' do
        result = checker.validate(signal)

        expect(result.passed?).to be true
        expect(result.failed_checks).to be_empty
      end
    end

    context 'with low exit liquidity' do
      let(:signal) do
        build_test_signal(liquidity: { exit_usd: 1000, low_bids_usd: 2000, high_asks_usd: 3000 })
      end

      it 'fails exit liquidity check' do
        result = checker.validate(signal)

        expect(result.passed?).to be false
        expect(result.failed_checks.map(&:check_name)).to include(:exit_liquidity)
      end
    end

    context 'with high slippage' do
      let(:signal) do
        build_test_signal(prices: {
          buy_price: 100, sell_price: 105,
          buy_slippage_pct: 2.0, sell_slippage_pct: 2.0
        })
      end

      it 'fails slippage check' do
        result = checker.validate(signal)

        expect(result.passed?).to be false
        expect(result.failed_checks.map(&:check_name)).to include(:max_slippage)
      end
    end

    context 'with non-shortable high venue' do
      let(:signal) do
        build_test_signal(high_venue: { type: :cex_spot, exchange: 'binance', symbol: 'BTC' })
      end

      it 'fails direction validity check' do
        result = checker.validate(signal)

        expect(result.passed?).to be false
        expect(result.failed_checks.map(&:check_name)).to include(:direction_validity)
      end
    end

    context 'with stale data' do
      let(:signal) do
        build_test_signal(created_at: Time.now.to_i - 120)
      end

      it 'fails freshness check' do
        result = checker.validate(signal)

        expect(result.passed?).to be false
        expect(result.failed_checks.map(&:check_name)).to include(:spread_freshness)
      end
    end
  end

  describe '#suggest_position_size' do
    it 'suggests 50% of exit liquidity' do
      signal = build_test_signal(liquidity: { exit_usd: 20_000, low_bids_usd: 50_000, high_asks_usd: 50_000 })
      suggested = checker.suggest_position_size(signal)

      expect(suggested).to eq(10_000)
    end

    it 'caps at 50k' do
      signal = build_test_signal(liquidity: { exit_usd: 200_000, low_bids_usd: 500_000, high_asks_usd: 500_000 })
      suggested = checker.suggest_position_size(signal)

      expect(suggested).to eq(50_000)
    end
  end
end
