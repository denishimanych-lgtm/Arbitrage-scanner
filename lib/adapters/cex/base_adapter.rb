# frozen_string_literal: true

module ArbitrageBot
  module Adapters
    module Cex
      class BaseAdapter
        class ApiError < StandardError; end

        def initialize
          @http_timeout = 10
        end

        # @return [String] exchange identifier
        def exchange_id
          raise NotImplementedError
        end

        # @return [Array<Hash>] list of futures symbols
        # Each hash: { symbol:, base_asset:, quote_asset:, status:, volume_24h: }
        def futures_symbols
          raise NotImplementedError
        end

        # @return [Array<Hash>] list of spot symbols
        # Each hash: { symbol:, base_asset:, quote_asset:, status: }
        def spot_symbols
          raise NotImplementedError
        end

        # @param asset [String] asset name (e.g., 'BTC', 'ETH')
        # @return [Hash] asset details with networks
        # { networks: [{ chain:, contract:, deposit_enabled:, withdraw_enabled: }] }
        def asset_details(asset)
          raise NotImplementedError
        end

        # @param symbol [String] trading pair symbol
        # @return [Hash] ticker data
        # { bid:, ask:, last:, volume_24h:, timestamp: }
        def ticker(symbol)
          raise NotImplementedError
        end

        # @param symbols [Array<String>] list of symbols
        # @return [Hash<String, Hash>] tickers by symbol
        def tickers(symbols = nil)
          raise NotImplementedError
        end

        # @param symbol [String] trading pair symbol
        # @param depth [Integer] number of levels
        # @return [Hash] orderbook data
        # { bids: [[price, qty], ...], asks: [[price, qty], ...], timestamp: }
        def orderbook(symbol, depth: 20)
          raise NotImplementedError
        end

        # @param symbol [String] futures symbol
        # @return [Hash] funding rate data
        # { rate:, next_funding_time: }
        def funding_rate(symbol)
          raise NotImplementedError
        end

        protected

        def get(url, headers: {})
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE if skip_ssl_verify?
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

        def normalize_symbol(symbol)
          symbol.to_s.upcase.gsub(/[-_\/]/, '')
        end

        def extract_base_asset(symbol)
          symbol.to_s.upcase.gsub(/USDT$|USDC$|USD$|BUSD$/, '')
        end

        def skip_ssl_verify?
          ENV['SKIP_SSL_VERIFY'] == '1' || ENV['APP_ENV'] == 'development'
        end
      end
    end
  end
end
