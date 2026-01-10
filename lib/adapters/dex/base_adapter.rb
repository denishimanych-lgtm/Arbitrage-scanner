# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Dex
      class BaseAdapter
        class ApiError < StandardError; end

        def initialize
          @http_timeout = 15
        end

        # @return [String] DEX identifier
        def dex_id
          raise NotImplementedError
        end

        # @return [String] blockchain network (solana, ethereum, bsc, arbitrum, avalanche)
        def chain
          raise NotImplementedError
        end

        # @param contract_address [String] token contract address
        # @return [Hash, nil] token info if found
        # { found: true, pool_address:, liquidity_usd:, volume_24h: }
        def find_token(contract_address)
          raise NotImplementedError
        end

        # @param input_mint [String] input token address
        # @param output_mint [String] output token address
        # @param amount [Integer] input amount in smallest units
        # @return [Hash] quote data
        # { in_amount:, out_amount:, price:, price_impact_pct:, route: }
        def quote(input_mint:, output_mint:, amount:)
          raise NotImplementedError
        end

        # @return [String] native token address (WSOL, WETH, etc.)
        def native_token_address
          raise NotImplementedError
        end

        # @return [String] USDC token address on this chain
        def usdc_address
          raise NotImplementedError
        end

        protected

        def get(url, headers: {})
          uri = URI.parse(url)
          http = Support::SslConfig.create_http(uri, timeout: @http_timeout)

          request = Net::HTTP::Get.new(uri.request_uri)
          headers.each { |k, v| request[k] = v }

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise ApiError, "HTTP #{response.code}: #{response.body[0..200]}"
          end

          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ApiError, "JSON parse error: #{e.message}"
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise ApiError, "Timeout: #{e.message}"
        end

        def post(url, body:, headers: {})
          uri = URI.parse(url)
          http = Support::SslConfig.create_http(uri, timeout: @http_timeout)

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          headers.each { |k, v| request[k] = v }
          request.body = body.to_json

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise ApiError, "HTTP #{response.code}: #{response.body[0..200]}"
          end

          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ApiError, "JSON parse error: #{e.message}"
        end
      end
    end
  end
end
