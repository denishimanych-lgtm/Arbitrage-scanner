# frozen_string_literal: true

# Migration to create position_tracking table
# Tracks user positions for exit notifications

module ArbitrageBot
  module Migrations
    class CreatePositionTracking
      def up
        sql = <<~SQL
          CREATE TABLE IF NOT EXISTS position_tracking (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            signal_id UUID REFERENCES signals(id),
            user_id BIGINT NOT NULL,
            symbol VARCHAR(20) NOT NULL,
            pair_id VARCHAR(100) NOT NULL,
            entry_spread_pct DECIMAL(10,4) NOT NULL,
            target_spread_pct DECIMAL(10,4),
            current_spread_pct DECIMAL(10,4),
            status VARCHAR(20) DEFAULT 'tracking',
            entered_at TIMESTAMPTZ DEFAULT NOW(),
            notified_at TIMESTAMPTZ,
            closed_at TIMESTAMPTZ,
            telegram_msg_id BIGINT,
            CONSTRAINT position_tracking_status_check CHECK (status IN ('tracking', 'notified', 'closed'))
          );

          CREATE INDEX IF NOT EXISTS idx_position_tracking_status ON position_tracking(status);
          CREATE INDEX IF NOT EXISTS idx_position_tracking_user ON position_tracking(user_id);
          CREATE INDEX IF NOT EXISTS idx_position_tracking_pair ON position_tracking(pair_id, symbol);
        SQL

        ArbitrageBot::Services::Analytics::DatabaseConnection.execute(sql)
        ArbitrageBot.logger.info('[Migration] Created position_tracking table')
      end

      def down
        sql = <<~SQL
          DROP TABLE IF EXISTS position_tracking;
        SQL

        ArbitrageBot::Services::Analytics::DatabaseConnection.execute(sql)
        ArbitrageBot.logger.info('[Migration] Dropped position_tracking table')
      end
    end
  end
end
