# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Trackers
      # Tracks user positions entered via Telegram button
      # Monitors spread convergence and sends close notifications
      class PositionTracker
        def initialize
          @logger = ArbitrageBot.logger
          @redis = ArbitrageBot.redis
        end

        # Start tracking a position
        # @param signal_id [String] UUID of the signal
        # @param user_id [Integer] Telegram user ID
        # @param symbol [String] trading symbol
        # @param pair_id [String] exchange pair identifier
        # @param entry_spread_pct [Float] spread at entry
        # @param target_spread_pct [Float, nil] target spread for close notification
        # @param telegram_msg_id [Integer, nil] message ID of the alert
        # @return [Hash, nil] created tracking record
        def start_tracking(signal_id:, user_id:, symbol:, pair_id:, entry_spread_pct:, target_spread_pct: nil, telegram_msg_id: nil)
          # Calculate default target if not provided (% of entry spread from settings)
          target = target_spread_pct || calculate_default_target(entry_spread_pct)

          sql = <<~SQL
            INSERT INTO position_tracking (
              signal_id, user_id, symbol, pair_id,
              entry_spread_pct, target_spread_pct, current_spread_pct,
              status, telegram_msg_id
            ) VALUES ($1, $2, $3, $4, $5, $6, $5, 'tracking', $7)
            RETURNING *
          SQL

          Analytics::DatabaseConnection.query_one(sql, [
            signal_id, user_id, symbol, pair_id,
            entry_spread_pct, target, telegram_msg_id
          ])
        rescue StandardError => e
          @logger.error("[PositionTracker] start_tracking error: #{e.message}")
          nil
        end

        # Get all actively tracked positions
        # @return [Array<Hash>]
        def active_positions
          sql = <<~SQL
            SELECT * FROM position_tracking
            WHERE status = 'tracking'
            ORDER BY entered_at DESC
          SQL

          Analytics::DatabaseConnection.query_all(sql)
        rescue StandardError => e
          @logger.error("[PositionTracker] active_positions error: #{e.message}")
          []
        end

        # Get positions for a specific user
        # @param user_id [Integer] Telegram user ID
        # @return [Array<Hash>]
        def user_positions(user_id)
          sql = <<~SQL
            SELECT * FROM position_tracking
            WHERE user_id = $1 AND status = 'tracking'
            ORDER BY entered_at DESC
          SQL

          Analytics::DatabaseConnection.query_all(sql, [user_id])
        rescue StandardError => e
          @logger.error("[PositionTracker] user_positions error: #{e.message}")
          []
        end

        # Update current spread for a position
        # @param id [String] position tracking ID
        # @param current_spread_pct [Float] current spread
        def update_spread(id, current_spread_pct)
          sql = <<~SQL
            UPDATE position_tracking
            SET current_spread_pct = $2
            WHERE id = $1
          SQL

          Analytics::DatabaseConnection.execute(sql, [id, current_spread_pct])
        rescue StandardError => e
          @logger.error("[PositionTracker] update_spread error: #{e.message}")
        end

        # Mark position as notified (close alert sent)
        # @param id [String] position tracking ID
        def mark_notified(id)
          sql = <<~SQL
            UPDATE position_tracking
            SET status = 'notified', notified_at = NOW()
            WHERE id = $1
          SQL

          Analytics::DatabaseConnection.execute(sql, [id])
        rescue StandardError => e
          @logger.error("[PositionTracker] mark_notified error: #{e.message}")
        end

        # Mark position as closed
        # @param id [String] position tracking ID
        def mark_closed(id)
          sql = <<~SQL
            UPDATE position_tracking
            SET status = 'closed', closed_at = NOW()
            WHERE id = $1
          SQL

          Analytics::DatabaseConnection.execute(sql, [id])
        rescue StandardError => e
          @logger.error("[PositionTracker] mark_closed error: #{e.message}")
        end

        # Check if target spread reached
        # @param position [Hash] position record
        # @param current_spread [Float] current spread
        # @return [Boolean]
        def target_reached?(position, current_spread)
          target = position[:target_spread_pct].to_f
          current_spread <= target
        end

        # Get position by ID
        # @param id [String] position tracking ID
        # @return [Hash, nil]
        def find(id)
          sql = <<~SQL
            SELECT * FROM position_tracking WHERE id = $1
          SQL

          Analytics::DatabaseConnection.query_one(sql, [id])
        rescue StandardError => e
          @logger.error("[PositionTracker] find error: #{e.message}")
          nil
        end

        # Find position by signal ID (short format)
        # @param short_signal_id [String] short signal ID (first 8 chars)
        # @param user_id [Integer] Telegram user ID
        # @return [Hash, nil]
        def find_by_short_signal_id(short_signal_id, user_id)
          sql = <<~SQL
            SELECT pt.* FROM position_tracking pt
            JOIN signals s ON s.id = pt.signal_id
            WHERE pt.user_id = $2
              AND s.id::text LIKE $1 || '%'
            ORDER BY pt.entered_at DESC
            LIMIT 1
          SQL

          Analytics::DatabaseConnection.query_one(sql, [short_signal_id, user_id])
        rescue StandardError => e
          @logger.error("[PositionTracker] find_by_short_signal_id error: #{e.message}")
          nil
        end

        private

        # Calculate default target spread based on settings
        # Default: 50% of entry spread
        def calculate_default_target(entry_spread)
          threshold_pct = load_threshold_setting
          entry_spread * (threshold_pct / 100.0)
        end

        # Load position close threshold from settings
        # @return [Float] percentage threshold (e.g., 50 means 50% of entry spread)
        def load_threshold_setting
          stored = @redis.hget(Services::SettingsLoader::REDIS_KEY, 'position_close_threshold_pct')
          stored ? stored.to_f : 50.0
        rescue StandardError
          50.0
        end
      end
    end
  end
end
