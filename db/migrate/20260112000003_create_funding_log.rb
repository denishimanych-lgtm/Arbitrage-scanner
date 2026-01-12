# frozen_string_literal: true

# Migration: Create funding_log table
# Stores funding rate snapshots from perpetual exchanges

SQL = <<~SQL
  -- UP
  CREATE TABLE funding_log (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    symbol VARCHAR(20) NOT NULL,
    venue VARCHAR(30) NOT NULL,
    venue_type VARCHAR(20),
    rate NUMERIC(12,8) NOT NULL,
    period_hours INTEGER DEFAULT 8,
    annualized_pct NUMERIC(8,4),
    next_funding_ts TIMESTAMPTZ
  );

  CREATE INDEX idx_funding_log_ts ON funding_log(ts);
  CREATE INDEX idx_funding_log_symbol ON funding_log(symbol, venue, ts);
  CREATE INDEX idx_funding_log_venue ON funding_log(venue, ts);

  -- DOWN
  DROP TABLE IF EXISTS funding_log;
SQL
