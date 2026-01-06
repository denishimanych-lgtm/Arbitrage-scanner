# frozen_string_literal: true

require 'bundler/setup'
Bundler.require

require 'json'
require 'net/http'
require 'uri'
require 'bigdecimal'
require 'time'
require 'logger'

module ArbitrageBot
  class << self
    def root
      @root ||= File.expand_path('..', __dir__)
    end

    def env
      ENV['APP_ENV'] || 'development'
    end

    def redis
      @redis ||= Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')
    end

    def logger
      @logger ||= Logger.new(
        File.join(root, 'log', "#{env}.log"),
        'daily'
      ).tap do |log|
        log.level = env == 'production' ? Logger::INFO : Logger::DEBUG
        log.formatter = proc do |severity, datetime, _, msg|
          "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
        end
      end
    end

    def load!
      load_env
      require_all
    end

    private

    def load_env
      env_file = File.join(root, '.env')
      return unless File.exist?(env_file)

      File.readlines(env_file).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        key, value = line.split('=', 2)
        ENV[key] = value.gsub(/\A["']|["']\z/, '') if key && value
      end
    end

    def require_all
      # Load in order: base classes first, then implementations
      load_order = %w[
        lib/adapters/cex/base_adapter
        lib/adapters/dex/base_adapter
        lib/adapters/perp_dex/base_adapter
        lib/models/ticker
        lib/services/ticker_validator
        lib/services/arbitrage_pair_generator
        lib/services/adapter_factory
        lib/storage/ticker_storage
        lib/jobs/ticker_discovery_job
        lib/services/price_fetcher/cex_price_fetcher
        lib/services/price_fetcher/dex_price_fetcher
        lib/services/price_fetcher/perp_dex_price_fetcher
        lib/services/orderbook/cex_orderbook_fetcher
        lib/services/orderbook/dex_depth_fetcher
        lib/services/orderbook/perp_dex_orderbook_fetcher
        lib/services/calculators/executable_price_calculator
        lib/services/calculators/spread_calculator
        lib/services/calculators/depth_calculator
        lib/services/trackers/timing_data
        lib/services/trackers/spread_age_tracker
        lib/services/trackers/depth_history_collector
        lib/jobs/price_monitor_job
        lib/jobs/orderbook_analysis_job
        lib/services/settings_loader
        lib/services/safety/liquidity_checker
        lib/services/safety/lagging_exchange_detector
        lib/services/safety/signal_builder
        lib/services/alerts/alert_formatter
        lib/services/alerts/cooldown_manager
        lib/services/alerts/blacklist
        lib/services/telegram/telegram_notifier
        lib/services/telegram/bot
        lib/jobs/alert_job
        lib/orchestrator
      ]

      load_order.each do |file|
        path = File.join(root, "#{file}.rb")
        require path if File.exist?(path)
      end

      # Load all adapter implementations (skip base_adapter as already loaded)
      Dir[File.join(root, 'lib/adapters/**/*.rb')].sort.each do |f|
        next if f.include?('base_adapter')
        require f
      end
    end
  end
end
