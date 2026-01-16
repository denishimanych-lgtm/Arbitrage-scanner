# frozen_string_literal: true

# Migration: Create convergence_analysis table
# Analysis of WHY spread converged (which venue moved, arb activity detection)

SQL = <<~SQL
  -- UP
  CREATE TABLE IF NOT EXISTS convergence_analysis (
    id BIGSERIAL PRIMARY KEY,
    signal_id UUID NOT NULL UNIQUE,

    -- Initial state (at signal creation)
    initial_buy_price NUMERIC(24,12),
    initial_sell_price NUMERIC(24,12),
    initial_spread_pct NUMERIC(10,4),

    -- Final state (at convergence or close)
    final_buy_price NUMERIC(24,12),
    final_sell_price NUMERIC(24,12),
    final_spread_pct NUMERIC(10,4),

    -- Price movement analysis
    buy_venue_change_pct NUMERIC(10,4),
    sell_venue_change_pct NUMERIC(10,4),

    -- Convergence reason classification
    -- 'buy_up' - buy venue price increased
    -- 'sell_down' - sell venue price decreased
    -- 'both' - both venues moved toward each other
    -- 'arb_activity' - detected arbitrage activity (depth drop + fast convergence)
    -- 'unknown' - can't determine
    convergence_reason VARCHAR(50),

    -- Orderbook change indicators
    buy_depth_change_pct NUMERIC(10,4),
    sell_depth_change_pct NUMERIC(10,4),

    -- Timing
    convergence_duration_minutes NUMERIC(10,2),
    snapshots_count INTEGER DEFAULT 0,

    -- Timestamps
    analyzed_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT fk_analysis_signal FOREIGN KEY (signal_id)
      REFERENCES signals(id) ON DELETE CASCADE
  );

  CREATE INDEX IF NOT EXISTS idx_analysis_signal ON convergence_analysis(signal_id);
  CREATE INDEX IF NOT EXISTS idx_analysis_reason ON convergence_analysis(convergence_reason);
  CREATE INDEX IF NOT EXISTS idx_analysis_time ON convergence_analysis(analyzed_at DESC);

  COMMENT ON TABLE convergence_analysis IS 'Post-convergence analysis explaining why spread converged';
  COMMENT ON COLUMN convergence_analysis.convergence_reason IS 'Classification: buy_up, sell_down, both, arb_activity, unknown';
  COMMENT ON COLUMN convergence_analysis.buy_depth_change_pct IS 'Change in buy venue depth (negative = depth decreased)';

  -- DOWN
  DROP TABLE IF EXISTS convergence_analysis;
SQL
