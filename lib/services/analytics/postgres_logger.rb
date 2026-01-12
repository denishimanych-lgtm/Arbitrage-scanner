# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Logs trading data to PostgreSQL for analytics
      class PostgresLogger
        class << self
          # Log a spread detection to spread_log
          # @param data [Hash] spread data
          # @return [Hash, nil] inserted row or nil on error
          def log_spread(data)
            sql = <<~SQL
              INSERT INTO spread_log (
                symbol, strategy, low_venue, high_venue,
                low_price, high_price, spread_pct, net_spread_pct,
                liquidity_usd, passed_validation, rejection_reason, signal_id
              ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
              RETURNING *
            SQL

            params = [
              data[:symbol],
              data[:strategy] || 'spatial_hedged',
              data[:low_venue],
              data[:high_venue],
              data[:low_price],
              data[:high_price],
              data[:spread_pct],
              data[:net_spread_pct],
              data[:liquidity_usd],
              data.fetch(:passed_validation, true),
              data[:rejection_reason],
              data[:signal_id]
            ]

            DatabaseConnection.query_one(sql, params)
          rescue StandardError => e
            log_error('log_spread', e)
            nil
          end

          # Log funding rate to funding_log
          # @param data [Hash] funding rate data
          # @return [Hash, nil] inserted row or nil on error
          def log_funding(data)
            sql = <<~SQL
              INSERT INTO funding_log (
                symbol, venue, venue_type, rate,
                period_hours, annualized_pct, next_funding_ts
              ) VALUES ($1, $2, $3, $4, $5, $6, $7)
              RETURNING *
            SQL

            annualized = calculate_annualized(data[:rate], data[:period_hours] || 8)

            params = [
              data[:symbol],
              data[:venue],
              data[:venue_type],
              data[:rate],
              data[:period_hours] || 8,
              annualized,
              data[:next_funding_ts]
            ]

            DatabaseConnection.query_one(sql, params)
          rescue StandardError => e
            log_error('log_funding', e)
            nil
          end

          # Batch log multiple funding rates
          # @param rates [Array<Hash>] array of funding rate data
          # @return [Integer] number of rows inserted
          def log_funding_batch(rates)
            return 0 if rates.empty?

            values = rates.map.with_index do |data, i|
              offset = i * 7
              annualized = calculate_annualized(data[:rate], data[:period_hours] || 8)

              "(#{(1..7).map { |j| "$#{offset + j}" }.join(', ')})"
            end.join(', ')

            sql = <<~SQL
              INSERT INTO funding_log (
                symbol, venue, venue_type, rate,
                period_hours, annualized_pct, next_funding_ts
              ) VALUES #{values}
            SQL

            params = rates.flat_map do |data|
              annualized = calculate_annualized(data[:rate], data[:period_hours] || 8)
              [
                data[:symbol],
                data[:venue],
                data[:venue_type],
                data[:rate],
                data[:period_hours] || 8,
                annualized,
                data[:next_funding_ts]
              ]
            end

            DatabaseConnection.execute(sql, params)
            rates.size
          rescue StandardError => e
            log_error('log_funding_batch', e)
            0
          end

          # Log z-score to zscore_log
          # @param data [Hash] z-score data
          # @return [Hash, nil] inserted row or nil on error
          def log_zscore(data)
            sql = <<~SQL
              INSERT INTO zscore_log (
                pair, ratio, mean, std, zscore, signal_id
              ) VALUES ($1, $2, $3, $4, $5, $6)
              RETURNING *
            SQL

            params = [
              data[:pair],
              data[:ratio],
              data[:mean],
              data[:std],
              data[:zscore],
              data[:signal_id]
            ]

            DatabaseConnection.query_one(sql, params)
          rescue StandardError => e
            log_error('log_zscore', e)
            nil
          end

          # Get recent spreads for a symbol
          # @param symbol [String] trading symbol
          # @param limit [Integer] max rows to return
          # @return [Array<Hash>] recent spreads
          def recent_spreads(symbol: nil, limit: 100)
            sql = if symbol
                    'SELECT * FROM spread_log WHERE symbol = $1 ORDER BY ts DESC LIMIT $2'
                  else
                    'SELECT * FROM spread_log ORDER BY ts DESC LIMIT $1'
                  end

            params = symbol ? [symbol, limit] : [limit]
            DatabaseConnection.query_all(sql, params)
          rescue StandardError => e
            log_error('recent_spreads', e)
            []
          end

          # Get recent funding rates for a symbol
          # @param symbol [String] trading symbol
          # @param venue [String, nil] optional venue filter
          # @param hours [Integer] lookback hours
          # @return [Array<Hash>] recent funding rates
          def recent_funding(symbol:, venue: nil, hours: 24)
            cutoff = Time.now - (hours * 3600)

            sql = if venue
                    <<~SQL
                      SELECT * FROM funding_log
                      WHERE symbol = $1 AND venue = $2 AND ts >= $3
                      ORDER BY ts DESC
                    SQL
                  else
                    <<~SQL
                      SELECT * FROM funding_log
                      WHERE symbol = $1 AND ts >= $2
                      ORDER BY ts DESC
                    SQL
                  end

            params = venue ? [symbol, venue, cutoff] : [symbol, cutoff]
            DatabaseConnection.query_all(sql, params)
          rescue StandardError => e
            log_error('recent_funding', e)
            []
          end

          # Get z-score history for a pair
          # @param pair [String] pair name (e.g., 'BTC/ETH')
          # @param days [Integer] lookback days
          # @return [Array<Hash>] z-score history
          def zscore_history(pair:, days: 90)
            cutoff = Time.now - (days * 86_400)

            sql = <<~SQL
              SELECT * FROM zscore_log
              WHERE pair = $1 AND ts >= $2
              ORDER BY ts ASC
            SQL

            DatabaseConnection.query_all(sql, [pair, cutoff])
          rescue StandardError => e
            log_error('zscore_history', e)
            []
          end

          # Get aggregate stats for spreads
          # @param strategy [String, nil] optional strategy filter
          # @param days [Integer] lookback days
          # @return [Hash] aggregate stats
          def spread_stats(strategy: nil, days: 30)
            cutoff = Time.now - (days * 86_400)

            sql = if strategy
                    <<~SQL
                      SELECT
                        COUNT(*) as total_spreads,
                        COUNT(DISTINCT symbol) as unique_symbols,
                        AVG(spread_pct) as avg_spread,
                        MAX(spread_pct) as max_spread,
                        COUNT(*) FILTER (WHERE passed_validation) as valid_count,
                        COUNT(signal_id) as alerted_count
                      FROM spread_log
                      WHERE strategy = $1 AND ts >= $2
                    SQL
                  else
                    <<~SQL
                      SELECT
                        COUNT(*) as total_spreads,
                        COUNT(DISTINCT symbol) as unique_symbols,
                        AVG(spread_pct) as avg_spread,
                        MAX(spread_pct) as max_spread,
                        COUNT(*) FILTER (WHERE passed_validation) as valid_count,
                        COUNT(signal_id) as alerted_count
                      FROM spread_log
                      WHERE ts >= $1
                    SQL
                  end

            params = strategy ? [strategy, cutoff] : [cutoff]
            DatabaseConnection.query_one(sql, params) || {}
          rescue StandardError => e
            log_error('spread_stats', e)
            {}
          end

          private

          def calculate_annualized(rate, period_hours)
            return nil unless rate

            periods_per_year = (365.0 * 24) / period_hours
            (rate.to_f * periods_per_year).round(4)
          end

          def log_error(method, error)
            ArbitrageBot.logger.error(
              "[PostgresLogger] #{method} failed: #{error.message}"
            )
          end
        end
      end
    end
  end
end
