# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArbitrageBot::Services::Alerts::AlertFormatter do
  let(:formatter) { described_class.new }

  describe '#format' do
    context 'with auto signal' do
      let(:signal) do
        ArbitrageBot::Services::Safety::SignalBuilder::ValidatedSignal.new(
          id: 'DF-BTC-S5.0-1234',
          pair_id: 'btc_jupiter_binance',
          symbol: 'BTC',
          signal_type: :auto,
          strategy_type: :DF,
          low_venue: { type: :dex_spot, dex: 'jupiter' },
          high_venue: { type: :cex_futures, exchange: 'binance' },
          prices: { buy_price: 50_000, sell_price: 52_500, buy_slippage_pct: 0.1, sell_slippage_pct: 0.1, delta: 2500 },
          spread: { nominal_pct: 5.0, real_pct: 4.8, slippage_loss_pct: 0.2, fees_pct: 0.36, net_pct: 4.44 },
          liquidity: { exit_usd: 100_000, low_bids_usd: 200_000, high_asks_usd: 300_000 },
          timing: { low_latency_ms: 100, high_latency_ms: 150 },
          position_size_usd: 10_000,
          suggested_position_usd: 10_000,
          safety_checks: { passed: true, checks_count: 7, passed_count: 7 },
          lagging_info: nil,
          fees_estimate: { total_fees_pct: 0.36 },
          actions: { entry: ['BUY BTC on Jupiter DEX', 'SHORT BTC on Binance Futures'], instructions: ['Enter in parts'] },
          links: { buy: 'https://jup.ag', sell: 'https://binance.com', chart: 'https://dexscreener.com' },
          created_at: Time.now.to_i,
          status: :valid
        )
      end

      it 'formats auto signal correctly' do
        result = formatter.format(signal)

        expect(result).to include('BTC')
        expect(result).to include('4.8%')
        expect(result).to include('DF-BTC-S5.0-1234')
        expect(result).to include('Jupiter')
        expect(result).to include('Binance')
        expect(result).to include('ACTION')
        expect(result).to include('LIQUIDITY')
      end
    end

    context 'with manual signal' do
      let(:signal) do
        ArbitrageBot::Services::Safety::SignalBuilder::ValidatedSignal.new(
          id: 'SF-ETH-S3.0-5678',
          pair_id: 'eth_binance_spot_futures',
          symbol: 'ETH',
          signal_type: :manual,
          strategy_type: :SF,
          low_venue: { type: :cex_spot, exchange: 'binance' },
          high_venue: { type: :cex_spot, exchange: 'okx' },
          prices: { buy_price: 3000, sell_price: 3090, delta: 90 },
          spread: { nominal_pct: 3.0, real_pct: 2.8, net_pct: 2.4 },
          liquidity: { exit_usd: 50_000 },
          timing: {},
          position_size_usd: 5000,
          suggested_position_usd: 5000,
          safety_checks: { passed: true },
          lagging_info: nil,
          fees_estimate: {},
          actions: { entry: ['BUY', 'SELL'], instructions: [] },
          links: {},
          created_at: Time.now.to_i,
          status: :valid
        )
      end

      it 'includes MANUAL badge' do
        result = formatter.format(signal)

        expect(result).to include('MANUAL')
        expect(result).to include('MANUAL EXECUTION REQUIRED')
      end
    end

    context 'with lagging signal' do
      let(:signal) do
        ArbitrageBot::Services::Safety::SignalBuilder::ValidatedSignal.new(
          id: 'DF-SOL-S8.0-9999',
          symbol: 'SOL',
          signal_type: :lagging,
          strategy_type: :DF,
          low_venue: { type: :dex_spot, dex: 'jupiter' },
          high_venue: { type: :cex_futures, exchange: 'mexc' },
          prices: { buy_price: 100, sell_price: 108 },
          spread: { real_pct: 8.0, net_pct: 7.5 },
          liquidity: {},
          timing: {},
          lagging_info: {
            detected: true,
            lagging_venue: 'mexc',
            deviation_pct: 5.5,
            median_price: 102.0,
            lagging_price: 108.0,
            other_exchanges_count: 4
          },
          created_at: Time.now.to_i,
          status: :valid
        )
      end

      it 'includes LAGGING warning' do
        result = formatter.format(signal)

        expect(result).to include('LAGGING')
        expect(result).to include('LAGGING EXCHANGE DETECTED')
        expect(result).to include('mexc')
        expect(result).to include('5.5%')
        expect(result).to include('4')
      end
    end
  end

  describe '#format_summary' do
    let(:signal) do
      ArbitrageBot::Services::Safety::SignalBuilder::ValidatedSignal.new(
        symbol: 'BTC',
        signal_type: :auto,
        low_venue: { type: :dex_spot, dex: 'jupiter' },
        high_venue: { type: :cex_futures, exchange: 'binance' },
        spread: { real_pct: 5.5 },
        liquidity: { exit_usd: 100_000 }
      )
    end

    it 'formats compact summary' do
      result = formatter.format_summary(signal)

      expect(result).to include('BTC')
      expect(result).to include('5.5%')
      expect(result).to include('100')
    end
  end
end
