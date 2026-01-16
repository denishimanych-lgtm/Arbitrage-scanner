# frozen_string_literal: true

# Migration: Create pair_statistics table
# Aggregated statistics per exchange pair for enhanced alerts

SQL = <<~SQL
  -- UP
  CREATE TABLE IF NOT EXISTS pair_statistics (
    id BIGSERIAL PRIMARY KEY,
    pair_id VARCHAR(100) NOT NULL,
    symbol VARCHAR(20) NOT NULL,

    -- Spread extremes
    max_spread_pct NUMERIC(10,4),
    min_spread_pct NUMERIC(10,4),

    -- Signal counts
    total_signals INTEGER DEFAULT 0,
    converged_count INTEGER DEFAULT 0,
    diverged_count INTEGER DEFAULT 0,
    expired_count INTEGER DEFAULT 0,

    -- Convergence timing
    avg_convergence_minutes NUMERIC(10,2),
    median_convergence_minutes NUMERIC(10,2),
    fastest_convergence_minutes NUMERIC(10,2),
    slowest_convergence_minutes NUMERIC(10,2),

    -- Success metrics
    success_rate_pct NUMERIC(5,2),

    -- Timestamps
    first_signal_at TIMESTAMPTZ,
    last_signal_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT unique_pair_stats UNIQUE(pair_id, symbol)
  );

  CREATE INDEX IF NOT EXISTS idx_pair_stats_lookup ON pair_statistics(pair_id, symbol);
  CREATE INDEX IF NOT EXISTS idx_pair_stats_symbol ON pair_statistics(symbol);
  CREATE INDEX IF NOT EXISTS idx_pair_stats_updated ON pair_statistics(updated_at DESC);

  COMMENT ON TABLE pair_statistics IS 'Aggregated convergence statistics per exchange pair';
  COMMENT ON COLUMN pair_statistics.pair_id IS 'Exchange pair like binance_spot:bybit_futures';
  COMMENT ON COLUMN pair_statistics.success_rate_pct IS 'Percentage of signals that converged';

  -- DOWN
  DROP TABLE IF EXISTS pair_statistics;
SQL
