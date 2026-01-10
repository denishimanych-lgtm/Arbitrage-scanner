# frozen_string_literal: true

require 'net/http'
require 'json'

module ArbitrageBot
  module Services
    class ContractFetcher
      COINGECKO_PRO_BASE = 'https://pro-api.coingecko.com/api/v3'
      COINGECKO_DEMO_BASE = 'https://api.coingecko.com/api/v3'
      CMC_BASE = 'https://pro-api.coinmarketcap.com/v1'

      # Rate limits
      COINGECKO_CALLS_PER_MIN = 30  # Pro plan
      CMC_CALLS_PER_MIN = 30

      # Chain mappings
      CHAIN_MAP = {
        'ethereum' => 'ethereum',
        'solana' => 'solana',
        'binance-smart-chain' => 'bsc',
        'bsc' => 'bsc',
        'arbitrum-one' => 'arbitrum',
        'arbitrum' => 'arbitrum',
        'avalanche' => 'avalanche',
        'polygon-pos' => 'polygon',
        'base' => 'base',
        'optimistic-ethereum' => 'optimism'
      }.freeze

      def initialize
        @coingecko_key = ENV['COINGECKO_API_KEY']
        @cmc_key = ENV['COINMARKETCAP_API_KEY']
        @redis = ArbitrageBot.redis
        @logger = ArbitrageBot.logger
        @http_timeout = 15

        # Determine CoinGecko URL based on key type
        # Demo keys start with "CG-" and use api.coingecko.com
        @coingecko_base = if @coingecko_key&.start_with?('CG-')
                            COINGECKO_DEMO_BASE
                          else
                            COINGECKO_PRO_BASE
                          end

        # Rate limiting state
        @coingecko_calls = []
        @cmc_calls = []

        # Symbol to CoinGecko ID mapping cache
        @symbol_id_map = nil
      end

      # Fetch contract addresses for a symbol
      # @param symbol [String] e.g., 'BTC', 'ETH', 'SOL'
      # @return [Hash] { chain => address, ... }
      def fetch(symbol)
        # Check Redis cache first
        cached = get_cached(symbol)
        return cached if cached

        contracts = {}

        # Try CoinGecko first
        if @coingecko_key && !@coingecko_key.empty?
          contracts = fetch_from_coingecko(symbol)
        end

        # Try CMC if CoinGecko didn't find anything
        if contracts.empty? && @cmc_key && !@cmc_key.empty?
          contracts = fetch_from_cmc(symbol)
        end

        # Cache result (even empty, to avoid repeated lookups)
        cache_result(symbol, contracts) unless contracts.nil?

        contracts || {}
      end

      # Batch fetch for multiple symbols
      # @param symbols [Array<String>]
      # @return [Hash<String, Hash>] { symbol => { chain => address } }
      def fetch_batch(symbols)
        results = {}
        total = symbols.size
        fetched = 0

        symbols.each_with_index do |symbol, idx|
          result = fetch(symbol)
          results[symbol] = result if result.any?
          fetched += 1

          # Log progress every 50 symbols
          if (idx + 1) % 50 == 0
            log("Contract fetch progress: #{idx + 1}/#{total} (found: #{results.size})")
          end
        end

        log("Contract fetch complete: #{results.size}/#{total} symbols with contracts")
        results
      end

      # Check if we have API keys configured
      def configured?
        (@coingecko_key && !@coingecko_key.empty?) ||
          (@cmc_key && !@cmc_key.empty?)
      end

      private

      def fetch_from_coingecko(symbol)
        wait_for_rate_limit(:coingecko)

        # Get coin ID from symbol
        coin_id = get_coingecko_id(symbol)
        return {} unless coin_id

        wait_for_rate_limit(:coingecko)
        record_call(:coingecko)

        # Fetch coin data with contract addresses
        url = "#{@coingecko_base}/coins/#{coin_id}?localization=false&tickers=false&market_data=false&community_data=false&developer_data=false"
        data = get_json(url, headers: coingecko_headers)

        return {} unless data && data['platforms']

        contracts = {}
        data['platforms'].each do |platform, address|
          next if address.nil? || address.empty?

          chain = CHAIN_MAP[platform.downcase]
          next unless chain

          contracts[chain] = address
        end

        contracts
      rescue StandardError => e
        handle_api_error('CoinGecko', e)
        {}
      end

      def fetch_from_cmc(symbol)
        wait_for_rate_limit(:cmc)
        record_call(:cmc)

        url = "#{CMC_BASE}/cryptocurrency/info?symbol=#{symbol}"
        data = get_json(url, headers: { 'X-CMC_PRO_API_KEY' => @cmc_key })

        return {} unless data && data['data'] && data['data'][symbol]

        coin_data = data['data'][symbol]
        coin_data = coin_data.first if coin_data.is_a?(Array)

        contracts = {}

        # Get contract addresses from platform field
        if coin_data['platform']
          platform = coin_data['platform']
          chain = normalize_cmc_chain(platform['name'] || platform['slug'])
          contracts[chain] = platform['token_address'] if chain && platform['token_address']
        end

        # Also check contract_address array if present
        if coin_data['contract_address'].is_a?(Array)
          coin_data['contract_address'].each do |contract|
            chain = normalize_cmc_chain(contract['platform']&.dig('name') || contract['platform']&.dig('slug'))
            next unless chain && contract['contract_address']

            contracts[chain] = contract['contract_address']
          end
        end

        contracts
      rescue StandardError => e
        handle_api_error('CMC', e)
        {}
      end

      def get_coingecko_id(symbol)
        # Build or use cached symbol -> ID map
        @symbol_id_map ||= build_coingecko_symbol_map

        @symbol_id_map[symbol.upcase]
      end

      def build_coingecko_symbol_map
        # Check Redis cache
        cached_map = @redis.get('contracts:coingecko_id_map')
        if cached_map
          begin
            return JSON.parse(cached_map)
          rescue JSON::ParserError
            # Continue to fetch fresh
          end
        end

        log('Building CoinGecko symbol -> ID map...')
        wait_for_rate_limit(:coingecko)
        record_call(:coingecko)

        url = "#{@coingecko_base}/coins/list?include_platform=true"
        data = get_json(url, headers: coingecko_headers)

        return {} unless data.is_a?(Array)

        # Build map - prefer coins with more platforms (more established)
        symbol_map = {}
        data.each do |coin|
          symbol = coin['symbol']&.upcase
          next unless symbol

          # Skip if we already have this symbol with more platforms
          existing_id = symbol_map[symbol]
          if existing_id
            # Keep the one with shorter ID (usually the main coin)
            next if coin['id'].length > existing_id.length
          end

          symbol_map[symbol] = coin['id']
        end

        # Cache for 24 hours
        @redis.setex('contracts:coingecko_id_map', 86400, symbol_map.to_json)
        log("Built CoinGecko map: #{symbol_map.size} symbols")

        symbol_map
      rescue StandardError => e
        log("Failed to build CoinGecko map: #{e.message}", :error)
        {}
      end

      def coingecko_headers
        # Demo API uses different header than Pro API
        header_key = @coingecko_key&.start_with?('CG-') ? 'x-cg-demo-api-key' : 'x-cg-pro-api-key'
        { header_key => @coingecko_key }
      end

      def normalize_cmc_chain(name)
        return nil unless name

        case name.downcase
        when /ethereum|erc-?20/i then 'ethereum'
        when /solana|spl/i then 'solana'
        when /bsc|binance|bep-?20/i then 'bsc'
        when /arbitrum/i then 'arbitrum'
        when /avalanche|avax/i then 'avalanche'
        when /polygon|matic/i then 'polygon'
        when /base/i then 'base'
        when /optimism/i then 'optimism'
        else nil
        end
      end

      def wait_for_rate_limit(source)
        calls = source == :coingecko ? @coingecko_calls : @cmc_calls
        limit = source == :coingecko ? COINGECKO_CALLS_PER_MIN : CMC_CALLS_PER_MIN

        # Remove calls older than 60 seconds
        cutoff = Time.now - 60
        calls.reject! { |t| t < cutoff }

        # If at limit, wait
        if calls.size >= limit
          oldest = calls.min
          wait_time = 60 - (Time.now - oldest)

          if wait_time > 0
            log("Rate limit reached for #{source}, waiting #{wait_time.ceil}s...")
            sleep(wait_time + 1)
            calls.clear
          end
        end
      end

      def record_call(source)
        calls = source == :coingecko ? @coingecko_calls : @cmc_calls
        calls << Time.now
      end

      def handle_api_error(source, error)
        msg = error.message

        if msg.include?('429') || msg.include?('rate limit')
          log("#{source} rate limit hit, waiting 60s...", :warn)
          sleep(60)
        elsif msg.include?('401') || msg.include?('403')
          log("#{source} API key invalid or expired", :error)
        else
          @logger.debug("[ContractFetcher] #{source} error: #{msg}")
        end
      end

      def get_cached(symbol)
        data = @redis.hget('contracts:cache', symbol.upcase)
        return nil unless data

        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      def cache_result(symbol, contracts)
        # Cache for 7 days
        @redis.hset('contracts:cache', symbol.upcase, contracts.to_json)
        @redis.expire('contracts:cache', 604800)
      end

      # HTTP GET with retry logic and exponential backoff
      # @param url [String] URL to fetch
      # @param headers [Hash] HTTP headers
      # @param max_retries [Integer] Maximum number of retry attempts
      # @param base_delay [Float] Base delay in seconds for exponential backoff
      # @return [Hash, Array] Parsed JSON response
      def get_json(url, headers: {}, max_retries: 3, base_delay: 1.0)
        retries = 0

        begin
          uri = URI.parse(url)
          http = Support::SslConfig.create_http(uri, timeout: @http_timeout)

          request = Net::HTTP::Get.new(uri.request_uri)
          headers.each { |k, v| request[k] = v }

          response = http.request(request)

          # Handle retryable HTTP errors
          if retryable_error?(response)
            raise RetryableError, "HTTP #{response.code}"
          end

          unless response.is_a?(Net::HTTPSuccess)
            raise "HTTP #{response.code}: #{response.body[0..200]}"
          end

          JSON.parse(response.body)

        rescue RetryableError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED => e
          retries += 1

          if retries <= max_retries
            delay = base_delay * (2**(retries - 1)) + rand(0.0..0.5) # Exponential backoff with jitter
            log("Retry #{retries}/#{max_retries} after #{delay.round(1)}s: #{e.message}", :warn)
            sleep(delay)
            retry
          else
            log("Max retries (#{max_retries}) exceeded for #{url}", :error)
            raise
          end
        end
      end

      # Check if HTTP response is retryable
      def retryable_error?(response)
        code = response.code.to_i
        # Retry on: 429 (rate limit), 500, 502, 503, 504 (server errors)
        [429, 500, 502, 503, 504].include?(code)
      end

      # Custom error class for retryable errors
      class RetryableError < StandardError; end

      def log(message, level = :info)
        case level
        when :error
          @logger.error("[ContractFetcher] #{message}")
        when :warn
          @logger.warn("[ContractFetcher] #{message}")
        else
          @logger.info("[ContractFetcher] #{message}")
        end
        puts "[#{Time.now.strftime('%H:%M:%S')}] [Contracts] #{message}"
      end
    end
  end
end
