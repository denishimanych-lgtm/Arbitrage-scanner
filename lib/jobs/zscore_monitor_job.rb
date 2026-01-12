# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Periodic job to calculate z-scores and generate alerts
    class ZScoreMonitorJob
      REDIS_LAST_RUN_KEY = 'zscore:last_run'
      REDIS_STATS_KEY = 'zscore:stats'

      DEFAULT_INTERVAL_SECONDS = 60  # 1 minute

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @tracker = Services::ZScore::ZScoreTracker.new
        @alerter = Services::ZScore::ZScoreAlerter.new(settings)
        @interval = settings[:zscore_interval_seconds] || DEFAULT_INTERVAL_SECONDS
        @running = false
      end

      # Run once
      def perform
        log('Calculating z-scores...')

        zscores = @tracker.calculate_all
        log("Calculated #{zscores.size} z-scores")

        # Cache in Redis for quick access
        zscores.each do |zscore_data|
          @tracker.cache_zscore(zscore_data)
        end

        # Log to PostgreSQL (only those with valid z-scores)
        valid_zscores = zscores.select { |z| z[:zscore] }
        valid_zscores.each do |zscore_data|
          @tracker.log_to_db(zscore_data)
        end

        # Check for alerts
        alerts = @alerter.check_and_alert(zscores)
        log("Generated #{alerts.size} alerts") if alerts.any?

        # Update stats
        update_stats(zscores, alerts)

        {
          zscores_count: zscores.size,
          valid_count: valid_zscores.size,
          alerts_count: alerts.size,
          calculated_at: Time.now
        }
      rescue StandardError => e
        @logger.error("[ZScoreMonitorJob] perform error: #{e.message}")
        @logger.error(e.backtrace.first(5).join("\n"))
        nil
      end

      # Run continuously
      def run_loop
        @running = true
        log("Starting z-score monitor loop (interval: #{@interval}s)")

        while @running
          begin
            perform
            ArbitrageBot.redis.set(REDIS_LAST_RUN_KEY, Time.now.to_i)
            sleep @interval
          rescue StandardError => e
            @logger.error("[ZScoreMonitorJob] loop error: #{e.message}")
            sleep 10
          end
        end
      end

      def stop
        @running = false
      end

      # Get current z-scores from cache
      def current_zscores
        @tracker.current_zscores
      end

      # Get z-scores as array for display
      def zscores_array
        cached = @tracker.current_zscores
        cached.values
      end

      # Get stats
      def stats
        stored = ArbitrageBot.redis.hgetall(REDIS_STATS_KEY)
        last_run = ArbitrageBot.redis.get(REDIS_LAST_RUN_KEY)

        {
          total_calculations: stored['calculations'].to_i,
          total_alerts: stored['alerts'].to_i,
          last_run: last_run ? Time.at(last_run.to_i) : nil,
          interval_seconds: @interval,
          pairs_count: Services::ZScore::PairsConfig.pair_symbols.size
        }
      end

      # Format z-scores for Telegram /zscores command
      def format_for_telegram
        zscores = @tracker.calculate_all
        @alerter.format_zscores_message(zscores)
      end

      private

      def update_stats(zscores, alerts)
        redis = ArbitrageBot.redis
        redis.hincrby(REDIS_STATS_KEY, 'calculations', 1)
        redis.hincrby(REDIS_STATS_KEY, 'alerts', alerts.size)
        redis.hset(REDIS_STATS_KEY, 'last_zscores_count', zscores.size)

        # Store extreme z-scores
        extreme = zscores.select { |z| z[:zscore] && z[:zscore].abs >= 2.0 }
        redis.hset(REDIS_STATS_KEY, 'extreme_count', extreme.size) if extreme.any?
      end

      def log(message)
        @logger.info("[ZScoreMonitorJob] #{message}")
      end
    end
  end
end
