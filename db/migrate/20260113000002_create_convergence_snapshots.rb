# frozen_string_literal: true

# Migration: Create convergence_snapshots table
# Periodic snapshots of prices during convergence tracking

SQL = <<~SQL
  -- UP
  CREATE TABLE IF NOT EXISTS convergence_snapshots (
    id BIGSERIAL PRIMARY KEY,
    signal_id UUID NOT NULL,
    snapshot_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Prices at buy venue (where we buy)
    buy_venue_bid NUMERIC(24,12),
    buy_venue_ask NUMERIC(24,12),

    -- Prices at sell venue (where we sell)
    sell_venue_bid NUMERIC(24,12),
    sell_venue_ask NUMERIC(24,12),

    -- Spread at this snapshot
    spread_pct NUMERIC(10,4),

    -- Orderbook depth (USD within slippage)
    buy_venue_bid_depth_usd NUMERIC(18,2),
    buy_venue_ask_depth_usd NUMERIC(18,2),
    sell_venue_bid_depth_usd NUMERIC(18,2),
    sell_venue_ask_depth_usd NUMERIC(18,2),

    -- Sequence for ordering
    snapshot_seq INTEGER NOT NULL,

    CONSTRAINT unique_snapshot UNIQUE(signal_id, snapshot_seq)
  );

  CREATE INDEX IF NOT EXISTS idx_snapshots_signal ON convergence_snapshots(signal_id);
  CREATE INDEX IF NOT EXISTS idx_snapshots_time ON convergence_snapshots(signal_id, snapshot_at DESC);

  COMMENT ON TABLE convergence_snapshots IS 'Periodic price/depth snapshots during convergence tracking';
  COMMENT ON COLUMN convergence_snapshots.snapshot_seq IS 'Sequence number within signal (1, 2, 3...)';
  COMMENT ON COLUMN convergence_snapshots.buy_venue_ask_depth_usd IS 'USD liquidity at ask within 1% slippage';

  -- DOWN
  DROP TABLE IF EXISTS convergence_snapshots;
SQL
