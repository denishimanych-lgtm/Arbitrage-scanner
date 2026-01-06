# frozen_string_literal: true

module ArbitrageBot
  class Orchestrator
    attr_reader :options, :threads, :running

    def initialize(options = {})
      @options = {
        discovery: true,
        price_monitor: true,
        alerts: true,
        telegram_bot: true
      }.merge(options)

      @logger = ArbitrageBot.logger
      @redis = ArbitrageBot.redis
      @threads = {}
      @running = false

      # Load settings
      @settings = Services::SettingsLoader.new.load

      # Initialize components
      init_components
    end

    def start
      @running = true
      log('Starting Orchestrator...')

      # Run discovery first (blocking)
      if @options[:discovery]
        run_discovery
      end

      # Start background workers
      start_workers

      # Keep main thread alive
      monitor_loop
    end

    def shutdown
      log('Shutting down...')
      @running = false

      # Stop all threads
      @threads.each do |name, thread|
        log("Stopping #{name}...")
        thread.kill if thread.alive?
      end

      # Save stats
      save_stats

      # Close Redis connections
      @redis.quit rescue nil

      log('Shutdown complete')
    end

    def status
      {
        running: @running,
        uptime: @start_time ? Time.now - @start_time : 0,
        threads: @threads.transform_values { |t| t.alive? ? 'running' : 'stopped' },
        redis: redis_connected?,
        settings: @settings.slice(:min_spread_pct, :alert_cooldown_seconds),
        stats: load_stats
      }
    end

    private

    def init_components
      @discovery_job = Jobs::TickerDiscoveryJob.new
      @price_monitor = Jobs::PriceMonitorJob.new(@settings)
      @orderbook_job = Jobs::OrderbookAnalysisJob.new(@settings)
      @alert_job = Jobs::AlertJob.new(@settings)

      if @options[:telegram_bot]
        @telegram_bot = Services::Telegram::Bot.new(orchestrator: self)
      end
    end

    def run_discovery
      log('Running initial ticker discovery...')
      begin
        result = @discovery_job.perform
        log("Discovery complete: #{result[:symbols_count]} symbols, #{result[:pairs_count]} pairs")
      rescue StandardError => e
        log("Discovery failed: #{e.message}", :error)
      end
    end

    def start_workers
      @start_time = Time.now

      # Price monitor thread
      if @options[:price_monitor]
        @threads[:price_monitor] = Thread.new do
          Thread.current.name = 'price_monitor'
          loop do
            break unless @running
            begin
              @price_monitor.perform
            rescue StandardError => e
              log("Price monitor error: #{e.message}", :error)
            end
            sleep(@settings[:price_update_interval_sec] || 1)
          end
        end
        log('Started price monitor')
      end

      # Orderbook analysis thread
      if @options[:price_monitor]
        @threads[:orderbook] = Thread.new do
          Thread.current.name = 'orderbook'
          begin
            @orderbook_job.run_loop
          rescue StandardError => e
            log("Orderbook job error: #{e.message}", :error)
          end
        end
        log('Started orderbook analysis')
      end

      # Alert worker thread
      if @options[:alerts]
        @threads[:alerts] = Thread.new do
          Thread.current.name = 'alerts'
          begin
            @alert_job.run_loop
          rescue StandardError => e
            log("Alert job error: #{e.message}", :error)
          end
        end
        log('Started alert worker')
      end

      # Telegram bot thread
      if @options[:telegram_bot] && @telegram_bot
        @threads[:telegram] = Thread.new do
          Thread.current.name = 'telegram'
          begin
            @telegram_bot.run
          rescue StandardError => e
            log("Telegram bot error: #{e.message}", :error)
          end
        end
        log('Started Telegram bot')
      end

      # Health check thread
      @threads[:health] = Thread.new do
        Thread.current.name = 'health'
        loop do
          break unless @running
          perform_health_check
          sleep 60
        end
      end
      log('Started health monitor')
    end

    def monitor_loop
      log('All workers started. Monitoring...')

      loop do
        break unless @running

        # Check thread health
        @threads.each do |name, thread|
          unless thread.alive?
            log("Thread #{name} died, restarting...", :warn)
            restart_thread(name)
          end
        end

        sleep 5
      end
    end

    def restart_thread(name)
      case name
      when :price_monitor
        @threads[:price_monitor] = Thread.new { price_monitor_loop }
      when :orderbook
        @threads[:orderbook] = Thread.new { @orderbook_job.run_loop }
      when :alerts
        @threads[:alerts] = Thread.new { @alert_job.run_loop }
      when :telegram
        @threads[:telegram] = Thread.new { @telegram_bot&.run }
      end
    end

    def perform_health_check
      checks = {
        redis: redis_connected?,
        threads: @threads.values.all?(&:alive?),
        price_freshness: check_price_freshness
      }

      unless checks.values.all?
        failed = checks.reject { |_, v| v }.keys
        log("Health check failed: #{failed.join(', ')}", :warn)
      end
    end

    def redis_connected?
      @redis.ping == 'PONG'
    rescue StandardError
      false
    end

    def check_price_freshness
      # Check if prices were updated recently
      last_update = @redis.get('prices:last_update')
      return false unless last_update

      Time.now.to_i - last_update.to_i < 30
    rescue StandardError
      false
    end

    def save_stats
      @redis.hset('orchestrator:stats', {
        'last_shutdown' => Time.now.to_i,
        'uptime_seconds' => @start_time ? (Time.now - @start_time).to_i : 0
      })
    end

    def load_stats
      @redis.hgetall('orchestrator:stats')
    rescue StandardError
      {}
    end

    def log(message, level = :info)
      case level
      when :error
        @logger.error("[Orchestrator] #{message}")
      when :warn
        @logger.warn("[Orchestrator] #{message}")
      else
        @logger.info("[Orchestrator] #{message}")
      end
      puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
    end
  end
end
