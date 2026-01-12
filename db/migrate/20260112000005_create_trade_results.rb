# frozen_string_literal: true

# Migration: Create trade_results table
# Stores manual trade results from /result command

SQL = <<~SQL
  -- UP
  CREATE TABLE trade_results (
    id BIGSERIAL PRIMARY KEY,
    signal_id UUID REFERENCES signals(id),
    user_id BIGINT NOT NULL,
    pnl_pct NUMERIC(10,4),
    hold_hours NUMERIC(10,2),
    notes TEXT,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
  );

  CREATE INDEX idx_trade_results_signal ON trade_results(signal_id);
  CREATE INDEX idx_trade_results_user ON trade_results(user_id, recorded_at);
  CREATE INDEX idx_trade_results_recorded ON trade_results(recorded_at);

  -- DOWN
  DROP TABLE IF EXISTS trade_results;
SQL
