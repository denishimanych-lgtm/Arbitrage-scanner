# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Repository for signal CRUD operations
      class SignalRepository
        # Signal statuses
        STATUS_SENT = 'sent'
        STATUS_TAKEN = 'taken'
        STATUS_CLOSED = 'closed'
        STATUS_EXPIRED = 'expired'

        # Strategy classes
        CLASS_RISK_PREMIUM = 'risk_premium'
        CLASS_SPECULATIVE = 'speculative'

        class << self
          # Create a new signal
          # @param data [Hash] signal data
          # @return [Hash, nil] created signal or nil on error
          def create(data)
            sql = <<~SQL
              INSERT INTO signals (
                strategy, class, symbol, details,
                telegram_msg_id, status, sent_at
              ) VALUES ($1, $2, $3, $4, $5, $6, NOW())
              RETURNING *
            SQL

            params = [
              data[:strategy],
              data[:class] || infer_class(data[:strategy]),
              data[:symbol],
              data[:details]&.to_json,
              data[:telegram_msg_id],
              STATUS_SENT
            ]

            DatabaseConnection.query_one(sql, params)
          rescue StandardError => e
            log_error('create', e)
            nil
          end

          # Find signal by ID (full UUID, short prefix, or prefixed short ID)
          # @param id [String] full UUID, short prefix, or prefixed ID like "hedge_abc12345"
          # @return [Hash, nil] signal or nil
          def find(id)
            return nil if id.nil? || id.empty?

            # Extract UUID part if prefixed (e.g., "hedge_abc12345" -> "abc12345")
            search_id = extract_uuid_part(id)

            # Support short IDs (first 8 chars of UUID)
            if search_id.length < 36
              sql = 'SELECT * FROM signals WHERE id::text LIKE $1 LIMIT 1'
              DatabaseConnection.query_one(sql, ["#{search_id}%"])
            else
              sql = 'SELECT * FROM signals WHERE id = $1'
              DatabaseConnection.query_one(sql, [search_id])
            end
          rescue StandardError => e
            log_error('find', e)
            nil
          end

          # Find signal by short ID prefix
          # @param short_id [String] first N chars of UUID
          # @return [Hash, nil] signal or nil
          def find_by_short_id(short_id)
            return nil if short_id.nil? || short_id.length < 4

            sql = 'SELECT * FROM signals WHERE id::text LIKE $1 ORDER BY ts DESC LIMIT 1'
            DatabaseConnection.query_one(sql, ["#{short_id}%"])
          rescue StandardError => e
            log_error('find_by_short_id', e)
            nil
          end

          # Mark signal as taken
          # @param id [String] signal ID
          # @return [Hash, nil] updated signal or nil
          def mark_taken(id)
            update_status(id, STATUS_TAKEN, taken_at: 'NOW()')
          end

          # Mark signal as closed with result
          # @param id [String] signal ID
          # @return [Hash, nil] updated signal or nil
          def mark_closed(id)
            update_status(id, STATUS_CLOSED, closed_at: 'NOW()')
          end

          # Update telegram message ID
          # @param id [String] signal ID
          # @param msg_id [Integer] Telegram message ID
          # @return [Hash, nil] updated signal or nil
          def update_telegram_msg_id(id, msg_id)
            sql = <<~SQL
              UPDATE signals SET telegram_msg_id = $1
              WHERE id = $2 OR id::text LIKE $3
              RETURNING *
            SQL

            DatabaseConnection.query_one(sql, [msg_id, id, "#{id}%"])
          rescue StandardError => e
            log_error('update_telegram_msg_id', e)
            nil
          end

          # Get recent signals
          # @param limit [Integer] max rows
          # @param strategy [String, nil] optional strategy filter
          # @param status [String, nil] optional status filter
          # @return [Array<Hash>] signals
          def recent(limit: 10, strategy: nil, status: nil)
            conditions = ['1=1']
            params = []

            if strategy
              params << strategy
              conditions << "strategy = $#{params.size}"
            end

            if status
              params << status
              conditions << "status = $#{params.size}"
            end

            params << limit

            sql = <<~SQL
              SELECT * FROM signals
              WHERE #{conditions.join(' AND ')}
              ORDER BY ts DESC
              LIMIT $#{params.size}
            SQL

            DatabaseConnection.query_all(sql, params)
          rescue StandardError => e
            log_error('recent', e)
            []
          end

          # Get signal statistics
          # @param days [Integer] lookback period
          # @param strategy [String, nil] optional strategy filter
          # @return [Hash] statistics
          def stats(days: 30, strategy: nil)
            cutoff = Time.now - (days * 86_400)

            sql = if strategy
                    <<~SQL
                      SELECT
                        COUNT(*) as total_signals,
                        COUNT(*) FILTER (WHERE status = 'sent') as sent_count,
                        COUNT(*) FILTER (WHERE status = 'taken') as taken_count,
                        COUNT(*) FILTER (WHERE status = 'closed') as closed_count,
                        COUNT(DISTINCT symbol) as unique_symbols
                      FROM signals
                      WHERE strategy = $1 AND ts >= $2
                    SQL
                  else
                    <<~SQL
                      SELECT
                        COUNT(*) as total_signals,
                        COUNT(*) FILTER (WHERE status = 'sent') as sent_count,
                        COUNT(*) FILTER (WHERE status = 'taken') as taken_count,
                        COUNT(*) FILTER (WHERE status = 'closed') as closed_count,
                        COUNT(DISTINCT symbol) as unique_symbols
                      FROM signals
                      WHERE ts >= $1
                    SQL
                  end

            params = strategy ? [strategy, cutoff] : [cutoff]
            DatabaseConnection.query_one(sql, params) || {}
          rescue StandardError => e
            log_error('stats', e)
            {}
          end

          # Get signals by strategy with stats
          # @param days [Integer] lookback period
          # @return [Array<Hash>] strategy stats
          def stats_by_strategy(days: 30)
            cutoff = Time.now - (days * 86_400)

            sql = <<~SQL
              SELECT
                strategy,
                COUNT(*) as total_signals,
                COUNT(*) FILTER (WHERE status = 'taken') as taken_count,
                COUNT(*) FILTER (WHERE status = 'closed') as closed_count
              FROM signals
              WHERE ts >= $1
              GROUP BY strategy
              ORDER BY total_signals DESC
            SQL

            DatabaseConnection.query_all(sql, [cutoff])
          rescue StandardError => e
            log_error('stats_by_strategy', e)
            []
          end

          # Expire old signals that were never taken
          # @param hours [Integer] age threshold
          # @return [Integer] number of expired signals
          def expire_old(hours: 24)
            cutoff = Time.now - (hours * 3600)

            sql = <<~SQL
              UPDATE signals
              SET status = $1, closed_at = NOW()
              WHERE status = $2 AND ts < $3
            SQL

            result = DatabaseConnection.execute(sql, [STATUS_EXPIRED, STATUS_SENT, cutoff])
            result.cmd_tuples
          rescue StandardError => e
            log_error('expire_old', e)
            0
          end

          # Generate short ID for display with strategy prefix
          # @param full_id [String] full UUID
          # @param strategy [String, nil] strategy name for prefix
          # @return [String] short ID with prefix (e.g., "hedge_abc12345")
          def short_id(full_id, strategy = nil)
            uuid_part = full_id.to_s[0, 8]

            # If strategy not provided, try to look it up
            if strategy.nil?
              signal = find(full_id)
              strategy = signal[:strategy] if signal
            end

            prefix = strategy_prefix(strategy)
            prefix.empty? ? uuid_part : "#{prefix}_#{uuid_part}"
          end

          # Extract UUID from prefixed short ID
          # @param prefixed_id [String] ID like "hedge_abc12345" or just "abc12345"
          # @return [String] UUID part only
          def extract_uuid_part(prefixed_id)
            return prefixed_id unless prefixed_id.include?('_')

            prefixed_id.split('_').last
          end

          # Get strategy prefix for short IDs
          # @param strategy [String] strategy name
          # @return [String] prefix
          def strategy_prefix(strategy)
            case strategy
            when 'spatial_hedged' then 'hedge'
            when 'spatial_manual' then 'manual'
            when 'funding' then 'fund'
            when 'funding_spread' then 'fspread'
            when 'zscore' then 'stat'
            when 'stablecoin_depeg' then 'depeg'
            else ''
            end
          end

          private

          def update_status(id, status, extra_fields = {})
            set_clauses = ['status = $1']
            params = [status]

            extra_fields.each do |field, value|
              if value == 'NOW()'
                set_clauses << "#{field} = NOW()"
              else
                params << value
                set_clauses << "#{field} = $#{params.size}"
              end
            end

            # Support both full UUID and short prefix
            sql = <<~SQL
              UPDATE signals SET #{set_clauses.join(', ')}
              WHERE id = $#{params.size + 1} OR id::text LIKE $#{params.size + 2}
              RETURNING *
            SQL

            params << id
            params << "#{id}%"

            DatabaseConnection.query_one(sql, params)
          rescue StandardError => e
            log_error('update_status', e)
            nil
          end

          def infer_class(strategy)
            case strategy
            when 'spatial_hedged', 'funding', 'funding_spread'
              CLASS_RISK_PREMIUM
            when 'spatial_manual', 'zscore', 'depeg'
              CLASS_SPECULATIVE
            else
              CLASS_SPECULATIVE
            end
          end

          def log_error(method, error)
            ArbitrageBot.logger.error(
              "[SignalRepository] #{method} failed: #{error.message}"
            )
          end
        end
      end
    end
  end
end
