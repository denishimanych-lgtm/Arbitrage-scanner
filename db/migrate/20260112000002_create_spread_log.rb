# frozen_string_literal: true

# Migration: Create spread_log table
# Stores all detected spreads for spatial arbitrage strategies

SQL = <<~SQL
  -- UP
  CREATE TABLE spread_log (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    symbol VARCHAR(20) NOT NULL,
    strategy VARCHAR(50) NOT NULL,
    low_venue VARCHAR(50) NOT NULL,
    high_venue VARCHAR(50) NOT NULL,
    low_price NUMERIC(24,12) NOT NULL,
    high_price NUMERIC(24,12) NOT NULL,
    spread_pct NUMERIC(10,4) NOT NULL,
    net_spread_pct NUMERIC(10,4),
    liquidity_usd NUMERIC(18,2),
    passed_validation BOOLEAN DEFAULT true,
    rejection_reason VARCHAR(100),
    signal_id UUID REFERENCES signals(id)
  );

  CREATE INDEX idx_spread_log_ts ON spread_log(ts);
  CREATE INDEX idx_spread_log_symbol ON spread_log(symbol, ts);
  CREATE INDEX idx_spread_log_strategy ON spread_log(strategy, ts);

  -- DOWN
  DROP TABLE IF EXISTS spread_log;
SQL
