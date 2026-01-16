# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Aggregator
      # DexScreener API adapter for bulk DEX price fetching
      # Docs: https://docs.dexscreener.com/api/reference
      class DexscreenerAdapter
        API_BASE = 'https://api.dexscreener.com'

        # Chain ID mapping (DexScreener uses lowercase chain names)
        CHAIN_IDS = {
          'ethereum' => 'ethereum',
          'bsc' => 'bsc',
          'polygon' => 'polygon',
          'arbitrum' => 'arbitrum',
          'optimism' => 'optimism',
          'avalanche' => 'avalanche',
          'base' => 'base',
          'solana' => 'solana'
        }.freeze

        # Rate limits: 300 req/min for token endpoints
        MAX_BATCH_SIZE = 30
        REQUEST_DELAY = 0.2  # 5 req/sec = 200ms between requests

        def initialize
          @logger = ArbitrageBot.logger
          @last_request_at = Time.now - 1
        end

        # Fetch prices for multiple tokens on a chain
        # @param chain [String] blockchain name
        # @param addresses [Array<String>] token contract addresses
        # @return [Hash] { address => price_data }
        def fetch_tokens_bulk(chain, addresses)
          chain_id = CHAIN_IDS[chain.to_s.downcase]
          return {} unless chain_id

          results = {}

          # Batch addresses in groups of 30
          addresses.each_slice(MAX_BATCH_SIZE) do |batch|
            rate_limit!

            batch_results = fetch_batch(chain_id, batch)
            results.merge!(batch_results)
          end

          results
        rescue StandardError => e
          @logger.error("[DexScreener] fetch_tokens_bulk error: #{e.message}")
          results
        end

        # Fetch all pairs for a single token
        # @param chain [String] blockchain name
        # @param address [String] token contract address
        # @return [Hash, nil] token pairs data
        def fetch_token_pairs(chain, address)
          chain_id = CHAIN_IDS[chain.to_s.downcase]
          return nil unless chain_id

          rate_limit!

          url = "#{API_BASE}/token-pairs/v1/#{chain_id}/#{address}"
          response = get(url)

          return nil unless response && response['pairs']

          parse_pairs_response(response['pairs'], address)
        rescue StandardError => e
          @logger.debug("[DexScreener] fetch_token_pairs error for #{address}: #{e.message}")
          nil
        end

        # Search for pairs by query
        # @param query [String] search query (e.g., "SOL/USDC")
        # @return [Array<Hash>] matching pairs
        def search_pairs(query)
          rate_limit!

          url = "#{API_BASE}/latest/dex/search?q=#{URI.encode_www_form_component(query)}"
          response = get(url)

          return [] unless response && response['pairs']

          response['pairs'].map { |p| parse_pair(p) }
        rescue StandardError => e
          @logger.error("[DexScreener] search_pairs error: #{e.message}")
          []
        end

        private

        def fetch_batch(chain_id, addresses)
          addresses_param = addresses.join(',')
          url = "#{API_BASE}/tokens/v1/#{chain_id}/#{addresses_param}"

          response = get(url)
          return {} unless response

          # Response is array of pairs for all tokens
          pairs = response.is_a?(Array) ? response : (response['pairs'] || [])

          parse_bulk_response(pairs, addresses)
        rescue StandardError => e
          @logger.debug("[DexScreener] fetch_batch error: #{e.message}")
          {}
        end

        def parse_bulk_response(pairs, requested_addresses)
          results = {}
          requested_set = requested_addresses.map(&:downcase).to_set

          pairs.each do |pair|
            # Get base token address
            base_token = pair['baseToken']
            next unless base_token

            address = base_token['address']&.downcase
            next unless address && requested_set.include?(address)

            # Skip if we already have data for this token (take first/best pair)
            next if results[address]

            results[address] = parse_pair(pair)
          end

          results
        end

        def parse_pairs_response(pairs, address)
          return nil if pairs.empty?

          # Find the best pair (highest liquidity)
          best_pair = pairs.max_by { |p| p['liquidity']&.dig('usd').to_f }
          return nil unless best_pair

          parse_pair(best_pair)
        end

        def parse_pair(pair)
          base_token = pair['baseToken'] || {}
          quote_token = pair['quoteToken'] || {}
          liquidity = pair['liquidity'] || {}
          volume = pair['volume'] || {}
          price_change = pair['priceChange'] || {}
          txns = pair['txns'] || {}

          {
            pair_address: pair['pairAddress'],
            dex: pair['dexId'],
            chain: pair['chainId'],

            # Token info
            symbol: base_token['symbol'],
            name: base_token['name'],
            address: base_token['address'],

            # Quote token
            quote_symbol: quote_token['symbol'],
            quote_address: quote_token['address'],

            # Prices
            price_usd: pair['priceUsd']&.to_f,
            price_native: pair['priceNative']&.to_f,

            # Liquidity & Volume
            liquidity_usd: liquidity['usd']&.to_f,
            volume_24h: volume['h24']&.to_f,
            volume_6h: volume['h6']&.to_f,
            volume_1h: volume['h1']&.to_f,

            # Price changes
            price_change_24h: price_change['h24']&.to_f,
            price_change_6h: price_change['h6']&.to_f,
            price_change_1h: price_change['h1']&.to_f,

            # Transaction counts
            txns_24h_buys: txns.dig('h24', 'buys').to_i,
            txns_24h_sells: txns.dig('h24', 'sells').to_i,

            # Metadata
            url: pair['url'],
            received_at: (Time.now.to_f * 1000).to_i
          }
        end

        def rate_limit!
          elapsed = Time.now - @last_request_at
          if elapsed < REQUEST_DELAY
            sleep(REQUEST_DELAY - elapsed)
          end
          @last_request_at = Time.now
        end

        def get(url)
          uri = URI.parse(url)
          http = Support::SslConfig.create_http(uri, timeout: 10)

          request = Net::HTTP::Get.new(uri.request_uri)
          request['Accept'] = 'application/json'

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            @logger.debug("[DexScreener] HTTP #{response.code}: #{url}")
            return nil
          end

          JSON.parse(response.body)
        rescue JSON::ParserError => e
          @logger.debug("[DexScreener] JSON parse error: #{e.message}")
          nil
        rescue StandardError => e
          @logger.debug("[DexScreener] Request error: #{e.message}")
          nil
        end
      end
    end
  end
end
