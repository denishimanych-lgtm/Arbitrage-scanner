# frozen_string_literal: true

# Migration: Create zscore_log table
# Stores z-score calculations for statistical arbitrage pairs

SQL = <<~SQL
  -- UP
  CREATE TABLE zscore_log (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    pair VARCHAR(20) NOT NULL,
    ratio NUMERIC(20,8) NOT NULL,
    mean NUMERIC(20,8),
    std NUMERIC(20,8),
    zscore NUMERIC(6,3) NOT NULL,
    signal_id UUID REFERENCES signals(id)
  );

  CREATE INDEX idx_zscore_log_ts ON zscore_log(ts);
  CREATE INDEX idx_zscore_log_pair ON zscore_log(pair, ts);

  -- DOWN
  DROP TABLE IF EXISTS zscore_log;
SQL
