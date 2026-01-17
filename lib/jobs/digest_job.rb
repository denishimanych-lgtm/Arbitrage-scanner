# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Sends digest alerts every 15 minutes
    # Accumulates signals and sends a summary with coin buttons
    class DigestJob
      DIGEST_INTERVAL = 900 # 15 minutes
      REDIS_LAST_DIGEST_KEY = 'digest:last_sent'

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @settings = settings
        @accumulator = Services::Alerts::DigestAccumulator.new
        @formatter = Services::Alerts::DigestFormatter.new
        @notifier = Services::Telegram::TelegramNotifier.new
        @mode_manager = Services::Alerts::CoinModeManager.new
        @running = false
      end

      # Run the digest loop
      def run_loop
        @running = true
        log("Starting digest job (interval: #{DIGEST_INTERVAL}s)")

        # Calculate time until next digest window
        next_window = calculate_next_digest_time
        initial_sleep = next_window - Time.now

        if initial_sleep > 0
          log("Waiting #{initial_sleep.round(0)}s until next digest window")
          sleep(initial_sleep)
        end

        while @running
          begin
            perform
            sleep(DIGEST_INTERVAL)
          rescue StandardError => e
            @logger.error("[DigestJob] loop error: #{e.message}")
            @logger.error(e.backtrace.first(5).join("\n"))
            sleep(60)
          end
        end
      end

      def stop
        @running = false
      end

      # Send digest if there are accumulated signals
      def perform
        # Cleanup expired real-time coins
        @mode_manager.cleanup_expired

        # Get signals from previous window
        signals = @accumulator.get_previous_window

        if signals.empty?
          log("No signals in previous window, skipping digest")
          check_system_health
          return nil
        end

        # Filter out coins in real-time mode (they get immediate alerts)
        realtime_coins = @mode_manager.realtime_coins
        digest_signals = signals.reject { |symbol, _| realtime_coins.include?(symbol) }

        if digest_signals.empty?
          log("All #{signals.size} signals are for real-time coins, skipping digest")
          return nil
        end

        # Format digest
        formatted = @formatter.format(digest_signals)

        unless formatted
          log("Formatter returned nil")
          return nil
        end

        # Send to Telegram with keyboard
        result = @notifier.send_alert(
          formatted[:message],
          reply_markup: formatted[:keyboard]
        )

        if result
          update_last_sent
          log("Digest sent: #{digest_signals.size} coins")
          record_digest_stats(digest_signals)
        else
          @logger.error("[DigestJob] Failed to send digest")
        end

        result
      end

      # Get current window stats
      def current_stats
        {
          accumulated_count: @accumulator.current_count,
          accumulated_symbols: @accumulator.current_symbols,
          realtime_coins: @mode_manager.realtime_coins,
          last_digest: last_digest_time,
          next_digest: calculate_next_digest_time
        }
      end

      private

      def calculate_next_digest_time
        now = Time.now.to_i
        window_start = (now / DIGEST_INTERVAL) * DIGEST_INTERVAL
        Time.at(window_start + DIGEST_INTERVAL)
      end

      def last_digest_time
        ts = ArbitrageBot.redis.get(REDIS_LAST_DIGEST_KEY)
        ts ? Time.at(ts.to_i) : nil
      end

      def update_last_sent
        ArbitrageBot.redis.set(REDIS_LAST_DIGEST_KEY, Time.now.to_i)
      end

      def check_system_health
        # If no signals for extended period, might indicate system issue
        last = last_digest_time
        return unless last

        hours_since = (Time.now - last) / 3600.0

        if hours_since > 1
          @logger.warn("[DigestJob] No digest sent for #{hours_since.round(1)} hours - check system health")

          # Send health warning to Telegram
          @notifier.send_alert(
            "⚠️ SYSTEM HEALTH WARNING\n\n" \
            "Нет сигналов уже #{hours_since.round(1)} часов.\n" \
            "Проверьте: VPN, интернет, Redis, биржи."
          )
        end
      end

      def record_digest_stats(signals)
        stats_key = 'digest:stats'
        redis = ArbitrageBot.redis

        redis.hincrby(stats_key, 'total_digests', 1)
        redis.hincrby(stats_key, 'total_coins', signals.size)
        redis.hset(stats_key, 'last_coins_count', signals.size)
        redis.hset(stats_key, 'last_sent_at', Time.now.to_i)

        # Track category distribution
        categories = {}
        signals.each_value do |cats|
          cats.each_key do |cat|
            categories[cat] ||= 0
            categories[cat] += 1
          end
        end

        categories.each do |cat, count|
          redis.hincrby(stats_key, "category_#{cat}", count)
        end
      end

      def log(message)
        @logger.info("[DigestJob] #{message}")
      end
    end
  end
end
