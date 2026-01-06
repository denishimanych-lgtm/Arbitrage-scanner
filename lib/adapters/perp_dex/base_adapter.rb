# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module PerpDex
      class BaseAdapter
        class ApiError < StandardError; end

        def initialize
          @http_timeout = 10
        end

        # @return [String] Perp DEX identifier
        def dex_id
          raise NotImplementedError
        end

        # @return [Array<Hash>] list of available markets
        # Each hash: { symbol:, status:, base_asset:, quote_asset: }
        def markets
          raise NotImplementedError
        end

        # @param symbol [String] market symbol
        # @return [Hash] ticker data
        # { bid:, ask:, mark_price:, index_price:, funding_rate:, next_funding_time:, volume_24h: }
        def ticker(symbol)
          raise NotImplementedError
        end

        # @param symbols [Array<String>, nil] optional list of symbols
        # @return [Hash<String, Hash>] tickers by symbol
        def tickers(symbols = nil)
          raise NotImplementedError
        end

        # @param symbol [String] market symbol
        # @param depth [Integer] number of levels
        # @return [Hash] orderbook data
        # { bids: [[price, qty], ...], asks: [[price, qty], ...], timestamp: }
        def orderbook(symbol, depth: 20)
          raise NotImplementedError
        end

        # @param symbol [String] market symbol
        # @return [Hash] funding rate data
        # { rate:, predicted_rate:, next_funding_time:, interval_hours: }
        def funding_rate(symbol)
          raise NotImplementedError
        end

        protected

        def get(url, headers: {})
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.read_timeout = @http_timeout
          http.open_timeout = @http_timeout

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
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.read_timeout = @http_timeout
          http.open_timeout = @http_timeout

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

        def normalize_symbol(symbol)
          symbol.to_s.upcase.gsub(/[-_\/]/, '')
        end
      end
    end
  end
end
