# frozen_string_literal: true

ENV['APP_ENV'] = 'test'

require_relative '../config/application'
ArbitrageBot.load!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.order = :random
  Kernel.srand config.seed

  # Clean Redis before each test
  config.before(:each) do
    ArbitrageBot.redis.flushdb
  end
end

# Test helpers
module TestHelpers
  def build_test_signal(overrides = {})
    {
      id: 'TEST-BTC-S5.0-1234',
      pair_id: 'btc_jupiter_binance',
      symbol: 'BTC',
      low_venue: {
        type: :dex_spot,
        dex: 'jupiter',
        symbol: 'BTC',
        token_address: 'test_address'
      },
      high_venue: {
        type: :cex_futures,
        exchange: 'binance',
        symbol: 'BTCUSDT'
      },
      prices: {
        buy_price: 50_000.0,
        sell_price: 52_500.0,
        buy_slippage_pct: 0.1,
        sell_slippage_pct: 0.1
      },
      spread: {
        nominal_pct: 5.0,
        real_pct: 4.8,
        loss_pct: 0.2
      },
      liquidity: {
        exit_usd: 100_000,
        low_bids_usd: 200_000,
        high_asks_usd: 300_000
      },
      timing: {
        low_latency_ms: 100,
        high_latency_ms: 150
      },
      position_size_usd: 10_000,
      fully_fillable: true,
      created_at: Time.now.to_i
    }.merge(overrides)
  end

  def build_test_orderbook(side: :bids, levels: 10, base_price: 100.0)
    {
      side => (1..levels).map do |i|
        price = side == :bids ? base_price - i * 0.1 : base_price + i * 0.1
        [price, rand(1.0..10.0)]
      end,
      :asks => [],
      :bids => [],
      timing: { fetch_time_ms: 50 }
    }.tap do |ob|
      ob[side == :bids ? :asks : :bids] = []
    end
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
