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
        def orderbook(symbol, depth: 20, market_type: nil)
          raise NotImplementedError
        end

        # @param symbol [String] futures symbol
        # @return [Hash] funding rate data
        # { rate:, next_funding_time: }
        def funding_rate(symbol)
          raise NotImplementedError
        end

        protected

        MAX_RETRIES = 3
        RETRY_DELAY = 0.5 # seconds

        def get(url, headers: {})
          retries = 0
          last_error = nil

          while retries < MAX_RETRIES
            begin
              uri = URI.parse(url)
              http = Support::SslConfig.create_http(uri, timeout: @http_timeout)

              request = Net::HTTP::Get.new(uri.request_uri)
              headers.each { |k, v| request[k] = v }

              response = http.request(request)

              unless response.is_a?(Net::HTTPSuccess)
                raise ApiError, "HTTP #{response.code}: #{response.body[0..200]}"
              end

              return JSON.parse(response.body)
            rescue OpenSSL::SSL::SSLError => e
              last_error = e
              retries += 1
              if retries < MAX_RETRIES
                sleep(RETRY_DELAY * retries) # Exponential backoff
              end
            rescue Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE, EOFError => e
              last_error = e
              retries += 1
              if retries < MAX_RETRIES
                sleep(RETRY_DELAY * retries)
              end
            rescue JSON::ParserError => e
              raise ApiError, "JSON parse error: #{e.message}"
            rescue Net::OpenTimeout, Net::ReadTimeout => e
              last_error = e
              retries += 1
              if retries < MAX_RETRIES
                sleep(RETRY_DELAY * retries)
              end
            end
          end

          # All retries exhausted
          raise ApiError, "Failed after #{MAX_RETRIES} retries: #{last_error&.message}"
        end

        def normalize_symbol(symbol)
          symbol.to_s.upcase.gsub(/[-_\/]/, '')
        end

        def extract_base_asset(symbol)
          symbol.to_s.upcase.gsub(/USDT$|USDC$|USD$|BUSD$/, '')
        end
      end
    end
  end
end
