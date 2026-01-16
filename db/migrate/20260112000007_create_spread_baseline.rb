# frozen_string_literal: true

# Migration: Create spread baseline table
# Background spread statistics - captures "normal" spread behavior
# to understand if current spread is an anomaly or the norm

SQL = <<~SQL
  -- UP
  CREATE TABLE IF NOT EXISTS spread_baseline (
    id BIGSERIAL PRIMARY KEY,
    pair_id VARCHAR(100) NOT NULL,
    symbol VARCHAR(20) NOT NULL,
    hour_bucket TIMESTAMPTZ NOT NULL,
    samples_count INTEGER DEFAULT 0,
    avg_spread_pct NUMERIC(10,4),
    min_spread_pct NUMERIC(10,4),
    max_spread_pct NUMERIC(10,4),
    stddev_spread_pct NUMERIC(10,4),
    p50_spread_pct NUMERIC(10,4),
    p95_spread_pct NUMERIC(10,4),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT unique_baseline_hour UNIQUE(pair_id, symbol, hour_bucket)
  );

  CREATE INDEX IF NOT EXISTS idx_baseline_pair_symbol ON spread_baseline(pair_id, symbol);
  CREATE INDEX IF NOT EXISTS idx_baseline_hour ON spread_baseline(hour_bucket);
  CREATE INDEX IF NOT EXISTS idx_baseline_lookup ON spread_baseline(pair_id, symbol, hour_bucket DESC);

  COMMENT ON TABLE spread_baseline IS 'Hourly aggregated spread statistics for understanding normal spread behavior';
  COMMENT ON COLUMN spread_baseline.pair_id IS 'Exchange pair like binance_spot:bybit_futures';
  COMMENT ON COLUMN spread_baseline.hour_bucket IS 'Start of the hour for this aggregation';
  COMMENT ON COLUMN spread_baseline.p50_spread_pct IS 'Median spread (50th percentile)';
  COMMENT ON COLUMN spread_baseline.p95_spread_pct IS '95th percentile spread';

  -- DOWN
  DROP TABLE IF EXISTS spread_baseline;
SQL
