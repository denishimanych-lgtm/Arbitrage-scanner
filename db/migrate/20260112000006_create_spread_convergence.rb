# frozen_string_literal: true

# Migration: Create spread convergence tracking table
# Tracks whether spreads converge after signals are sent

SQL = <<~SQL
  -- UP
  CREATE TABLE IF NOT EXISTS spread_convergence (
    id BIGSERIAL PRIMARY KEY,
    signal_id UUID REFERENCES signals(id),
    symbol VARCHAR(20) NOT NULL,
    pair_id VARCHAR(100) NOT NULL,
    initial_spread_pct NUMERIC(10,4) NOT NULL,
    current_spread_pct NUMERIC(10,4),
    min_spread_pct NUMERIC(10,4),
    max_spread_pct NUMERIC(10,4),
    converged BOOLEAN DEFAULT FALSE,
    converged_at TIMESTAMPTZ,
    diverged BOOLEAN DEFAULT FALSE,
    diverged_at TIMESTAMPTZ,
    checks_count INTEGER DEFAULT 0,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_checked_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ,
    close_reason VARCHAR(50),
    CONSTRAINT unique_signal_convergence UNIQUE (signal_id)
  );

  CREATE INDEX IF NOT EXISTS idx_convergence_symbol ON spread_convergence(symbol);
  CREATE INDEX IF NOT EXISTS idx_convergence_pair ON spread_convergence(pair_id);
  CREATE INDEX IF NOT EXISTS idx_convergence_started ON spread_convergence(started_at);
  CREATE INDEX IF NOT EXISTS idx_convergence_active ON spread_convergence(closed_at) WHERE closed_at IS NULL;

  -- DOWN
  DROP TABLE IF EXISTS spread_convergence;
SQL
