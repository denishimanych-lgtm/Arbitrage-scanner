# frozen_string_literal: true

# Migration: Create signals table
# Stores all trading signals from all strategies

SQL = <<~SQL
  -- UP
  CREATE EXTENSION IF NOT EXISTS "pgcrypto";

  CREATE TABLE signals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    strategy VARCHAR(50) NOT NULL,
    class VARCHAR(20) NOT NULL,
    symbol VARCHAR(20) NOT NULL,
    details JSONB,
    telegram_msg_id BIGINT,
    status VARCHAR(20) DEFAULT 'sent',
    sent_at TIMESTAMPTZ,
    taken_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ
  );

  CREATE INDEX idx_signals_ts ON signals(ts);
  CREATE INDEX idx_signals_status ON signals(status);
  CREATE INDEX idx_signals_strategy ON signals(strategy, ts);
  CREATE INDEX idx_signals_symbol ON signals(symbol, ts);

  -- DOWN
  DROP TABLE IF EXISTS signals;
SQL
