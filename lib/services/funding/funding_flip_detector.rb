# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Funding
      # Detects funding rate flips and tracks consecutive negative periods
      # Used to generate exit signals for funding rate positions
      class FundingFlipDetector
        # Configuration
        NEGATIVE_PERIODS_EXIT = 3       # Exit after N consecutive negative periods
        FLIP_THRESHOLD = 0.0001         # Rate below this is considered negative (0.01%/8h)
        HISTORY_PERIODS = 10            # Track last N periods for each symbol/venue

        REDIS_KEY_PREFIX = 'funding:history:'
        REDIS_POSITIONS_KEY = 'funding:active_positions'

        def initialize
          @logger = ArbitrageBot.logger
        end

        # Check for funding flips and exit signals
        # @param rates [Array<Hash>] current funding rates
        # @return [Array<Hash>] exit signals to send
        def check_for_exits(rates)
          exit_signals = []
          active_positions = get_active_positions

          rates.each do |rate|
            key = position_key(rate[:symbol], rate[:venue])
            next unless active_positions.include?(key)

            # Get history for this position
            history = get_history(rate[:symbol], rate[:venue])

            # Check consecutive negatives
            consecutive_negatives = count_consecutive_negatives(history)

            if consecutive_negatives >= NEGATIVE_PERIODS_EXIT
              exit_signals << build_exit_signal(rate, history, consecutive_negatives)
            end
          end

          exit_signals
        end

        # Update funding history for a symbol/venue
        # @param rate [Hash] funding rate data
        def record_rate(rate)
          key = redis_history_key(rate[:symbol], rate[:venue])

          entry = {
            rate: rate[:rate].to_f,
            ts: Time.now.to_i,
            positive: rate[:rate].to_f >= FLIP_THRESHOLD
          }

          # Add to Redis list (LPUSH for newest first)
          ArbitrageBot.redis.lpush(key, entry.to_json)
          # Trim to keep only last N entries
          ArbitrageBot.redis.ltrim(key, 0, HISTORY_PERIODS - 1)
        rescue StandardError => e
          @logger.error("[FundingFlipDetector] record_rate error: #{e.message}")
        end

        # Get funding history from Redis
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @return [Array<Hash>] history entries (newest first)
        def get_history(symbol, venue)
          key = redis_history_key(symbol, venue)
          entries = ArbitrageBot.redis.lrange(key, 0, HISTORY_PERIODS - 1)

          entries.map { |e| JSON.parse(e, symbolize_names: true) }
        rescue StandardError => e
          @logger.debug("[FundingFlipDetector] get_history error: #{e.message}")
          []
        end

        # Get history from PostgreSQL (for deeper analysis)
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @param periods [Integer] number of periods to retrieve
        # @return [Array<Hash>] history from DB
        def get_db_history(symbol, venue, periods: HISTORY_PERIODS)
          sql = <<~SQL
            SELECT rate, ts
            FROM funding_log
            WHERE symbol = $1 AND venue = $2
            ORDER BY ts DESC
            LIMIT $3
          SQL

          rows = Analytics::DatabaseConnection.query_all(sql, [symbol, venue, periods])
          rows.map do |r|
            {
              rate: r['rate'].to_f,
              ts: r['ts'],
              positive: r['rate'].to_f >= FLIP_THRESHOLD
            }
          end
        rescue StandardError => e
          @logger.debug("[FundingFlipDetector] get_db_history error: #{e.message}")
          []
        end

        # Mark a position as active (after entry alert)
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        def activate_position(symbol, venue)
          key = position_key(symbol, venue)
          ArbitrageBot.redis.sadd(REDIS_POSITIONS_KEY, key)
          @logger.info("[FundingFlipDetector] Activated position: #{key}")
        rescue StandardError => e
          @logger.error("[FundingFlipDetector] activate_position error: #{e.message}")
        end

        # Mark a position as closed (after exit)
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        def deactivate_position(symbol, venue)
          key = position_key(symbol, venue)
          ArbitrageBot.redis.srem(REDIS_POSITIONS_KEY, key)
          @logger.info("[FundingFlipDetector] Deactivated position: #{key}")
        rescue StandardError => e
          @logger.error("[FundingFlipDetector] deactivate_position error: #{e.message}")
        end

        # Get all active positions
        # @return [Array<String>] position keys
        def get_active_positions
          ArbitrageBot.redis.smembers(REDIS_POSITIONS_KEY) || []
        rescue StandardError => e
          @logger.debug("[FundingFlipDetector] get_active_positions error: #{e.message}")
          []
        end

        # Check if a position is active
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @return [Boolean]
        def position_active?(symbol, venue)
          key = position_key(symbol, venue)
          ArbitrageBot.redis.sismember(REDIS_POSITIONS_KEY, key)
        rescue StandardError
          false
        end

        # Analyze funding history for a symbol/venue
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @return [Hash] analysis results
        def analyze(symbol, venue)
          redis_history = get_history(symbol, venue)
          db_history = get_db_history(symbol, venue)

          # Use DB history if Redis is empty
          history = redis_history.any? ? redis_history : db_history

          return nil if history.empty?

          consecutive_negatives = count_consecutive_negatives(history)
          consecutive_positives = count_consecutive_positives(history)
          rates = history.map { |h| h[:rate] }

          {
            symbol: symbol,
            venue: venue,
            periods_count: history.size,
            consecutive_negatives: consecutive_negatives,
            consecutive_positives: consecutive_positives,
            current_rate: rates.first,
            avg_rate: (rates.sum / rates.size).round(6),
            min_rate: rates.min,
            max_rate: rates.max,
            trend: determine_trend(history),
            exit_recommended: consecutive_negatives >= NEGATIVE_PERIODS_EXIT,
            exit_threshold: NEGATIVE_PERIODS_EXIT
          }
        end

        # Format history for display
        # @param symbol [String] trading symbol
        # @param venue [String] venue name
        # @return [String] formatted message
        def format_history(symbol, venue)
          analysis = analyze(symbol, venue)
          return "No history for #{symbol} on #{venue}" unless analysis

          status = analysis[:exit_recommended] ? '🚨 EXIT RECOMMENDED' : '✅ OK'
          trend_emoji = case analysis[:trend]
                        when :improving then '📈'
                        when :declining then '📉'
                        else '➡️'
                        end

          lines = [
            "📊 FUNDING HISTORY | #{symbol} | #{venue}",
            "━" * 30,
            "",
            "Current: #{format_rate(analysis[:current_rate])}/8h",
            "Average: #{format_rate(analysis[:avg_rate])}/8h",
            "Range: #{format_rate(analysis[:min_rate])} to #{format_rate(analysis[:max_rate])}",
            "",
            "#{trend_emoji} Trend: #{analysis[:trend]}",
            "Consecutive negatives: #{analysis[:consecutive_negatives]}",
            "Consecutive positives: #{analysis[:consecutive_positives]}",
            "",
            "Status: #{status}",
            "Exit threshold: #{NEGATIVE_PERIODS_EXIT} consecutive negatives"
          ]

          lines.join("\n")
        end

        private

        def count_consecutive_negatives(history)
          count = 0
          history.each do |entry|
            if entry[:rate].to_f < FLIP_THRESHOLD
              count += 1
            else
              break
            end
          end
          count
        end

        def count_consecutive_positives(history)
          count = 0
          history.each do |entry|
            if entry[:rate].to_f >= FLIP_THRESHOLD
              count += 1
            else
              break
            end
          end
          count
        end

        def determine_trend(history)
          return :unknown if history.size < 3

          recent = history.first(3).map { |h| h[:rate] }
          older = history.last(3).map { |h| h[:rate] }

          recent_avg = recent.sum / recent.size
          older_avg = older.sum / older.size

          diff = recent_avg - older_avg

          if diff > FLIP_THRESHOLD
            :improving
          elsif diff < -FLIP_THRESHOLD
            :declining
          else
            :stable
          end
        end

        def build_exit_signal(rate, history, consecutive_negatives)
          avg_negative_rate = history.first(consecutive_negatives)
                                    .map { |h| h[:rate] }
                                    .sum / consecutive_negatives

          {
            type: :funding_exit,
            symbol: rate[:symbol],
            venue: rate[:venue],
            current_rate: rate[:rate],
            consecutive_negatives: consecutive_negatives,
            avg_negative_rate: avg_negative_rate,
            history: history.first(5)
          }
        end

        def position_key(symbol, venue)
          "#{symbol}:#{venue}"
        end

        def redis_history_key(symbol, venue)
          "#{REDIS_KEY_PREFIX}#{symbol}:#{venue}"
        end

        def format_rate(rate)
          pct = (rate.to_f * 100).round(4)
          "#{pct}%"
        end
      end
    end
  end
end
