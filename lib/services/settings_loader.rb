# frozen_string_literal: true

require 'yaml'

module ArbitrageBot
  module Services
    class SettingsLoader
      REDIS_KEY = 'settings:config'

      # Default settings with all available options
      DEFAULTS = {
        # === Alert Thresholds ===
        min_spread_pct: 2.0,
        high_spread_threshold: 10.0,
        medium_spread_threshold: 5.0,
        max_spread_pct: 50.0,

        # === Liquidity Requirements ===
        min_liquidity_usd: 500_000,
        min_exit_liquidity_usd: 5_000,
        min_volume_24h_dex: 200_000,
        min_volume_24h_futures: 200_000,

        # === Position Sizing ===
        min_position_size_usd: 1_000,
        max_position_size_usd: 50_000,
        suggested_position_usd: 10_000,

        # === Safety Limits ===
        max_slippage_pct: 2.0,
        max_latency_ms: 5_000,
        max_spread_age_sec: 60,
        min_depth_vs_history_ratio: 0.3,

        # === Alert Cooldowns ===
        alert_cooldown_seconds: 300,  # 5 minutes
        lagging_alert_cooldown_seconds: 600,  # 10 minutes for lagging alerts

        # === Signal Types ===
        enable_auto_signals: true,
        enable_manual_signals: true,
        enable_lagging_signals: false,  # Disabled by default

        # === Enabled Exchanges ===
        enabled_cex: %w[binance bybit okx gate mexc kucoin htx bitget],
        enabled_dex: %w[jupiter raydium orca],
        enabled_perp_dex: %w[hyperliquid dydx gmx vertex],

        # === Enabled Networks ===
        enabled_networks: %w[solana ethereum bsc arbitrum],

        # === Lagging Detection ===
        lagging_min_lag_ms: 500,
        lagging_max_lag_ms: 10_000,
        lagging_min_confidence: 0.7,

        # === System ===
        price_update_interval_sec: 1,
        ticker_discovery_interval_hours: 24,
        log_level: 'info'
      }.freeze

      attr_reader :redis, :settings

      def initialize(redis: nil)
        @redis = redis || ArbitrageBot.redis
        @settings = {}
        @logger = ArbitrageBot.logger
      end

      # Load settings from all sources (priority: Redis > ENV > YAML > Defaults)
      # @return [Hash] merged settings
      def load
        @settings = DEFAULTS.dup

        # 1. Load from YAML config file (if exists)
        load_from_yaml

        # 2. Load from environment variables
        load_from_env

        # 3. Load from Redis (highest priority for runtime changes)
        load_from_redis

        @logger.info("[Settings] Loaded #{@settings.size} settings")
        @settings
      end

      # Get a specific setting
      # @param key [Symbol, String]
      # @param default [Object] default value if not found
      # @return [Object]
      def get(key, default = nil)
        @settings[key.to_sym] || default
      end

      # Set a setting (persists to Redis)
      # @param key [Symbol, String]
      # @param value [Object]
      def set(key, value)
        key = key.to_sym
        @settings[key] = cast_value(key, value)
        save_to_redis(key, @settings[key])
        @logger.info("[Settings] Updated #{key} = #{@settings[key]}")
      end

      # Reset a setting to default
      # @param key [Symbol, String]
      def reset(key)
        key = key.to_sym
        @settings[key] = DEFAULTS[key]
        @redis.hdel(REDIS_KEY, key.to_s)
        @logger.info("[Settings] Reset #{key} to default: #{@settings[key]}")
      end

      # Reset all settings to defaults
      def reset_all
        @redis.del(REDIS_KEY)
        @settings = DEFAULTS.dup
        @logger.info('[Settings] Reset all settings to defaults')
      end

      # Get all settings as hash
      # @return [Hash]
      def all
        @settings.dup
      end

      # Get settings for a specific component
      # @param component [Symbol] :liquidity, :alerts, :lagging, etc.
      # @return [Hash]
      def for_component(component)
        case component
        when :liquidity
          {
            min_exit_liquidity_usd: get(:min_exit_liquidity_usd),
            min_position_size_usd: get(:min_position_size_usd),
            max_slippage_pct: get(:max_slippage_pct),
            max_latency_ms: get(:max_latency_ms),
            min_depth_vs_history_ratio: get(:min_depth_vs_history_ratio),
            max_spread_age_sec: get(:max_spread_age_sec),
            require_shortable_high_venue: true
          }
        when :alerts
          {
            high_spread_threshold: get(:high_spread_threshold),
            medium_spread_threshold: get(:medium_spread_threshold),
            enable_auto_signals: get(:enable_auto_signals),
            enable_manual_signals: get(:enable_manual_signals),
            enable_lagging_signals: get(:enable_lagging_signals)
          }
        when :cooldown
          {
            default_cooldown: get(:alert_cooldown_seconds),
            lagging_cooldown: get(:lagging_alert_cooldown_seconds)
          }
        when :lagging
          {
            min_lag_threshold_ms: get(:lagging_min_lag_ms),
            max_lag_threshold_ms: get(:lagging_max_lag_ms),
            min_correlation: get(:lagging_min_confidence)
          }
        when :spread
          {
            min_spread_pct: get(:min_spread_pct),
            max_slippage_pct: get(:max_slippage_pct),
            suggested_position_usd: get(:suggested_position_usd)
          }
        else
          {}
        end
      end

      # Validate current settings
      # @return [Array<String>] list of validation errors
      def validate
        errors = []

        # Spread thresholds
        if get(:min_spread_pct) >= get(:max_spread_pct)
          errors << 'min_spread_pct must be less than max_spread_pct'
        end

        # Liquidity
        if get(:min_exit_liquidity_usd) < get(:min_position_size_usd)
          errors << 'min_exit_liquidity_usd should be >= min_position_size_usd'
        end

        # Slippage
        if get(:max_slippage_pct) > 5.0
          errors << 'max_slippage_pct seems too high (>5%)'
        end

        # Cooldowns
        if get(:alert_cooldown_seconds) < 60
          errors << 'alert_cooldown_seconds should be at least 60 seconds'
        end

        errors
      end

      private

      def load_from_yaml
        yaml_path = File.join(ArbitrageBot.root, 'config', 'settings.yml')
        return unless File.exist?(yaml_path)

        yaml_settings = YAML.load_file(yaml_path)
        env_settings = yaml_settings[ArbitrageBot.env] || yaml_settings['default'] || {}

        env_settings.each do |key, value|
          @settings[key.to_sym] = value
        end

        @logger.debug("[Settings] Loaded from #{yaml_path}")
      rescue StandardError => e
        @logger.warn("[Settings] Failed to load YAML: #{e.message}")
      end

      def load_from_env
        # Map ENV variables to settings
        env_mappings = {
          'MIN_SPREAD_PCT' => :min_spread_pct,
          'MIN_LIQUIDITY_USD' => :min_liquidity_usd,
          'MIN_VOLUME_DEX' => :min_volume_24h_dex,
          'MIN_VOLUME_FUTURES' => :min_volume_24h_futures,
          'ALERT_COOLDOWN_SECONDS' => :alert_cooldown_seconds,
          'MAX_SLIPPAGE_PCT' => :max_slippage_pct,
          'MAX_POSITION_USD' => :max_position_size_usd,
          'SUGGESTED_POSITION_USD' => :suggested_position_usd,
          'LOG_LEVEL' => :log_level
        }

        env_mappings.each do |env_key, setting_key|
          value = ENV[env_key]
          next unless value && !value.empty?

          @settings[setting_key] = cast_value(setting_key, value)
        end
      end

      def load_from_redis
        stored = @redis.hgetall(REDIS_KEY)
        return if stored.empty?

        stored.each do |key, value|
          key_sym = key.to_sym
          next unless DEFAULTS.key?(key_sym)

          @settings[key_sym] = cast_value(key_sym, value)
        end
      end

      def save_to_redis(key, value)
        serialized = case value
                     when Array then value.to_json
                     else value.to_s
                     end
        @redis.hset(REDIS_KEY, key.to_s, serialized)
      end

      def cast_value(key, value)
        default = DEFAULTS[key]

        case default
        when Float
          value.to_f
        when Integer
          value.to_i
        when TrueClass, FalseClass
          %w[true 1 yes].include?(value.to_s.downcase)
        when Array
          value.is_a?(Array) ? value : JSON.parse(value)
        else
          value.to_s
        end
      rescue StandardError
        value
      end
    end
  end
end
