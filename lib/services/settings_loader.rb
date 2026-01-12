# frozen_string_literal: true

require 'yaml'

module ArbitrageBot
  module Services
    class SettingsLoader
      class SettingsError < StandardError; end

      REDIS_KEY = 'settings:config'

      # Required settings - bot won't work without these (per ТЗ)
      REQUIRED_SETTINGS = %i[
        min_spread_pct
        min_exit_liquidity_usd
        max_position_to_exit_ratio
        max_slippage_pct
        max_spread_age_hours
        max_bid_ask_spread_pct
        max_latency_ms
        min_depth_vs_history_ratio
        warning_depth_ratio
        min_history_samples
        alert_cooldown_seconds
        suggested_position_usd
        telegram_bot_token
        telegram_chat_id
      ].freeze

      # Type definitions for casting
      SETTING_TYPES = {
        min_spread_pct: :float,
        high_spread_threshold: :float,
        medium_spread_threshold: :float,
        max_spread_pct: :float,
        min_liquidity_usd: :integer,
        min_exit_liquidity_usd: :integer,
        min_volume_24h_dex: :integer,
        min_volume_24h_futures: :integer,
        min_position_size_usd: :integer,
        max_position_size_usd: :integer,
        suggested_position_usd: :integer,
        max_slippage_pct: :float,
        max_latency_ms: :integer,
        max_spread_age_sec: :integer,
        max_spread_age_hours: :integer,
        min_depth_vs_history_ratio: :float,
        warning_depth_ratio: :float,
        min_history_samples: :integer,
        max_position_to_exit_ratio: :float,
        max_bid_ask_spread_pct: :float,
        alert_cooldown_seconds: :integer,
        lagging_alert_cooldown_seconds: :integer,
        enable_auto_signals: :boolean,
        enable_manual_signals: :boolean,
        enable_lagging_signals: :boolean,
        enabled_cex: :array,
        enabled_dex: :array,
        enabled_perp_dex: :array,
        enabled_networks: :array,
        lagging_min_lag_ms: :integer,
        lagging_max_lag_ms: :integer,
        lagging_min_confidence: :float,
        price_update_interval_sec: :integer,
        ticker_discovery_interval_hours: :integer,
        log_level: :string,
        telegram_bot_token: :string,
        telegram_chat_id: :string,
        max_price_age_ms: :integer
      }.freeze

      attr_reader :redis, :settings

      def initialize(redis: nil)
        @redis = redis || ArbitrageBot.redis
        @settings = {}
        @logger = ArbitrageBot.logger
      end

      # Load settings from all sources (priority: Redis > ENV > YAML)
      # Raises SettingsError if required settings are missing
      # @return [Hash] merged settings
      def load
        @settings = {}

        # 1. Load from YAML config file
        load_from_yaml

        # 2. Load from environment variables
        load_from_env

        # 3. Load from Redis (highest priority for runtime changes)
        load_from_redis

        # Validate required settings
        validate_required!

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

      # Reset a setting (removes from Redis, requires reload from YAML/ENV)
      # @param key [Symbol, String]
      def reset(key)
        key = key.to_sym
        @redis.hdel(REDIS_KEY, key.to_s)
        @settings.delete(key)
        @logger.info("[Settings] Reset #{key}")
      end

      # Reset all settings (removes from Redis)
      def reset_all
        @redis.del(REDIS_KEY)
        @settings = {}
        @logger.info('[Settings] Reset all settings from Redis')
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
            warning_depth_ratio: get(:warning_depth_ratio),
            max_spread_age_sec: get(:max_spread_age_sec),
            max_spread_age_hours: get(:max_spread_age_hours),
            max_position_to_exit_ratio: get(:max_position_to_exit_ratio),
            max_bid_ask_spread_pct: get(:max_bid_ask_spread_pct),
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

      # Validate current settings (non-throwing)
      # @return [Array<String>] list of validation errors
      def validate
        errors = []

        # Spread thresholds
        if get(:min_spread_pct) && get(:max_spread_pct) && get(:min_spread_pct) >= get(:max_spread_pct)
          errors << 'min_spread_pct must be less than max_spread_pct'
        end

        # Liquidity
        if get(:min_exit_liquidity_usd) && get(:min_position_size_usd) &&
           get(:min_exit_liquidity_usd) < get(:min_position_size_usd)
          errors << 'min_exit_liquidity_usd should be >= min_position_size_usd'
        end

        # Slippage
        if get(:max_slippage_pct) && get(:max_slippage_pct) > 5.0
          errors << 'max_slippage_pct seems too high (>5%)'
        end

        # Cooldowns
        if get(:alert_cooldown_seconds) && get(:alert_cooldown_seconds) < 60
          errors << 'alert_cooldown_seconds should be at least 60 seconds'
        end

        errors
      end

      # Check if all required settings are present
      # @return [Array<Symbol>] list of missing settings
      def missing_settings
        REQUIRED_SETTINGS.select { |key| @settings[key].nil? }
      end

      private

      def validate_required!
        missing = missing_settings
        return if missing.empty?

        error_msg = "Missing required settings: #{missing.join(', ')}"
        @logger.error("[Settings] #{error_msg}")
        raise SettingsError, error_msg
      end

      def load_from_yaml
        yaml_path = File.join(ArbitrageBot.root, 'config', 'settings.yml')
        return unless File.exist?(yaml_path)

        yaml_settings = YAML.load_file(yaml_path, aliases: true)
        env_settings = yaml_settings[ArbitrageBot.env] || yaml_settings['default'] || {}

        env_settings.each do |key, value|
          key_sym = key.to_sym
          @settings[key_sym] = cast_value(key_sym, value)
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
          'MIN_EXIT_LIQUIDITY_USD' => :min_exit_liquidity_usd,
          'MIN_VOLUME_DEX' => :min_volume_24h_dex,
          'MIN_VOLUME_FUTURES' => :min_volume_24h_futures,
          'ALERT_COOLDOWN_SECONDS' => :alert_cooldown_seconds,
          'MAX_SLIPPAGE_PCT' => :max_slippage_pct,
          'MAX_POSITION_USD' => :max_position_size_usd,
          'SUGGESTED_POSITION_USD' => :suggested_position_usd,
          'LOG_LEVEL' => :log_level,
          'TELEGRAM_BOT_TOKEN' => :telegram_bot_token,
          'TELEGRAM_CHAT_ID' => :telegram_chat_id,
          'MAX_SPREAD_AGE_HOURS' => :max_spread_age_hours,
          'MAX_POSITION_TO_EXIT_RATIO' => :max_position_to_exit_ratio,
          'MAX_BID_ASK_SPREAD_PCT' => :max_bid_ask_spread_pct,
          'MAX_LATENCY_MS' => :max_latency_ms,
          'MIN_DEPTH_VS_HISTORY_RATIO' => :min_depth_vs_history_ratio,
          'WARNING_DEPTH_RATIO' => :warning_depth_ratio,
          'MIN_HISTORY_SAMPLES' => :min_history_samples
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
        type = SETTING_TYPES[key] || :string

        case type
        when :float
          value.to_f
        when :integer
          value.to_i
        when :boolean
          %w[true 1 yes].include?(value.to_s.downcase)
        when :array
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
