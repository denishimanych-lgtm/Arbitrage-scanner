# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Periodic job to collect funding rates and generate alerts
    class FundingRateJob
      REDIS_KEY = 'funding:rates'
      LAST_RUN_KEY = 'funding:last_run'
      STATS_KEY = 'funding:stats'

      DEFAULT_INTERVAL_SECONDS = 3600  # 1 hour

      def initialize(settings = {})
        @logger = ArbitrageBot.logger
        @collector = Services::Funding::FundingCollector.new(
          symbols: settings[:symbols]
        )
        @alerter = Services::Funding::FundingAlerter.new(settings)
        @interval = settings[:interval_seconds] || DEFAULT_INTERVAL_SECONDS
        @running = false
      end

      # Run once
      def perform
        log('Collecting funding rates...')

        rates = @collector.collect_all
        log("Collected #{rates.size} rates from #{rates.map { |r| r[:venue] }.uniq.size} venues")

        # Store in Redis for quick access
        store_rates(rates)

        # Log to PostgreSQL
        log_rates_to_db(rates)

        # Check for alerts
        alerts = @alerter.check_and_alert(rates)
        log("Generated #{alerts.size} alerts") if alerts.any?

        # Update stats
        update_stats(rates, alerts)

        {
          rates_count: rates.size,
          venues_count: rates.map { |r| r[:venue] }.uniq.size,
          alerts_count: alerts.size,
          collected_at: Time.now
        }
      rescue StandardError => e
        @logger.error("[FundingRateJob] perform error: #{e.message}")
        @logger.error(e.backtrace.first(5).join("\n"))
        nil
      end

      # Run continuously
      def run_loop
        @running = true
        log("Starting funding rate job loop (interval: #{@interval}s)")

        while @running
          begin
            perform
            ArbitrageBot.redis.set(LAST_RUN_KEY, Time.now.to_i)
            sleep @interval
          rescue StandardError => e
            @logger.error("[FundingRateJob] loop error: #{e.message}")
            sleep 60
          end
        end
      end

      def stop
        @running = false
      end

      # Get current rates from Redis
      def current_rates
        data = ArbitrageBot.redis.get(REDIS_KEY)
        return [] unless data

        JSON.parse(data, symbolize_names: true)
      rescue StandardError
        []
      end

      # Get rates for a specific symbol
      def rates_for_symbol(symbol)
        current_rates.select { |r| r[:symbol] == symbol }
      end

      # Get stats
      def stats
        stored = ArbitrageBot.redis.hgetall(STATS_KEY)
        last_run = ArbitrageBot.redis.get(LAST_RUN_KEY)

        {
          total_collections: stored['collections'].to_i,
          total_alerts: stored['alerts'].to_i,
          last_run: last_run ? Time.at(last_run.to_i) : nil,
          interval_seconds: @interval
        }
      end

      # Format rates for Telegram /funding command
      def format_for_telegram(symbol = nil)
        rates = symbol ? rates_for_symbol(symbol) : current_rates

        if rates.empty?
          return symbol ? "No funding data for #{symbol}" : "No funding data. Run collection first."
        end

        if symbol
          @alerter.format_rates_message(symbol, rates)
        else
          format_all_rates_summary(rates)
        end
      end

      private

      def store_rates(rates)
        # Serialize for Redis
        data = rates.map do |r|
          r.transform_values do |v|
            v.is_a?(BigDecimal) ? v.to_f : v
          end
        end

        ArbitrageBot.redis.setex(REDIS_KEY, @interval * 2, data.to_json)
      end

      def log_rates_to_db(rates)
        rates_to_log = rates.map do |r|
          {
            symbol: r[:symbol],
            venue: r[:venue],
            venue_type: r[:venue_type],
            rate: r[:rate].to_f,
            period_hours: r[:period_hours],
            next_funding_ts: r[:next_funding_ts]
          }
        end

        Services::Analytics::PostgresLogger.log_funding_batch(rates_to_log)
      rescue StandardError => e
        @logger.error("[FundingRateJob] log_rates_to_db error: #{e.message}")
      end

      def update_stats(rates, alerts)
        redis = ArbitrageBot.redis
        redis.hincrby(STATS_KEY, 'collections', 1)
        redis.hincrby(STATS_KEY, 'alerts', alerts.size)
        redis.hset(STATS_KEY, 'last_rates_count', rates.size)
      end

      def format_all_rates_summary(rates)
        by_symbol = rates.group_by { |r| r[:symbol] }

        lines = [
          "💰 FUNDING RATES SUMMARY",
          "━" * 30,
          ""
        ]

        by_symbol.each do |symbol, symbol_rates|
          sorted = symbol_rates.sort_by { |r| -r[:rate].to_f }
          max = sorted.first
          min = sorted.last
          spread = (max[:rate].to_f - min[:rate].to_f) * 100

          lines << "#{symbol}: #{(max[:rate].to_f * 100).round(4)}% (#{max[:venue]})"
          lines << "   Spread: #{spread.round(4)}% | #{symbol_rates.size} venues"
          lines << ""
        end

        lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"
        lines.join("\n")
      end

      def log(message)
        @logger.info("[FundingRateJob] #{message}")
      end
    end
  end
end
