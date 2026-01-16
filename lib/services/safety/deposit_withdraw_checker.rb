# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      # Checks deposit/withdraw status on exchanges before manual arbitrage
      # Warns if transfers are disabled which would block the trade
      class DepositWithdrawChecker
        REDIS_CACHE_KEY = 'deposit_withdraw:status:'
        CACHE_TTL = 300  # 5 minutes

        # Public exchange APIs that don't require auth
        # These provide coin deposit/withdraw status
        EXCHANGE_APIS = {
          binance: 'https://api.binance.com/api/v3/exchangeInfo',
          bybit: 'https://api.bybit.com/v5/asset/coin/query-info',
          okx: 'https://www.okx.com/api/v5/asset/currencies',
          gate: 'https://api.gateio.ws/api/v4/spot/currencies',
          mexc: 'https://api.mexc.com/api/v3/capital/config/getall',
          kucoin: 'https://api.kucoin.com/api/v1/currencies',
          htx: 'https://api.huobi.pro/v2/reference/currencies',
          bitget: 'https://api.bitget.com/api/v2/spot/public/coins'
        }.freeze

        def initialize
          @logger = ArbitrageBot.logger
          @adapters = {}
        end

        # Check if deposit and withdraw are enabled for a symbol on an exchange
        # @param symbol [String] base asset (e.g., 'BTC', 'SOL')
        # @param exchange [String] exchange name (e.g., 'binance')
        # @param network [String] optional specific network
        # @return [Hash] status info
        def check_status(symbol, exchange, network: nil)
          cached = get_cached(symbol, exchange)
          return cached if cached

          status = fetch_status(symbol, exchange.to_s.downcase)
          cache_status(symbol, exchange, status) if status

          # Filter by network if specified
          if network && status && status[:networks]
            network_status = status[:networks].find { |n| n[:chain]&.downcase == network.downcase }
            status[:selected_network] = network_status if network_status
          end

          status
        rescue StandardError => e
          @logger.debug("[DepositWithdrawChecker] check_status error: #{e.message}")
          { error: e.message, deposit_enabled: nil, withdraw_enabled: nil }
        end

        # Check if manual arbitrage is safe (both ends have transfers enabled)
        # @param symbol [String] base asset
        # @param buy_exchange [String] exchange to buy on
        # @param sell_exchange [String] exchange to sell on
        # @param network [String] transfer network
        # @return [Hash] validation result
        def validate_transfer_route(symbol, buy_exchange, sell_exchange, network: nil)
          buy_status = check_status(symbol, buy_exchange, network: network)
          sell_status = check_status(symbol, sell_exchange, network: network)

          issues = []

          # Check withdraw from buy exchange
          buy_withdraw = network_withdraw_enabled?(buy_status, network)
          issues << "Withdraw disabled on #{buy_exchange}" if buy_withdraw == false

          # Check deposit to sell exchange
          sell_deposit = network_deposit_enabled?(sell_status, network)
          issues << "Deposit disabled on #{sell_exchange}" if sell_deposit == false

          valid = issues.empty?

          {
            valid: valid,
            symbol: symbol,
            buy_exchange: buy_exchange,
            sell_exchange: sell_exchange,
            network: network,
            buy_withdraw_enabled: buy_withdraw,
            sell_deposit_enabled: sell_deposit,
            issues: issues,
            message: valid ? 'Transfers enabled' : issues.join(', ')
          }
        end

        # Get best network for transfer between exchanges
        # @param symbol [String] base asset
        # @param buy_exchange [String] source exchange
        # @param sell_exchange [String] destination exchange
        # @return [String, nil] best network or nil
        def best_transfer_network(symbol, buy_exchange, sell_exchange)
          buy_status = check_status(symbol, buy_exchange)
          sell_status = check_status(symbol, sell_exchange)

          return nil unless buy_status[:networks] && sell_status[:networks]

          # Find common networks where both have transfers enabled
          buy_networks = buy_status[:networks]
                         .select { |n| n[:withdraw_enabled] }
                         .map { |n| n[:chain]&.downcase }
                         .compact

          sell_networks = sell_status[:networks]
                          .select { |n| n[:deposit_enabled] }
                          .map { |n| n[:chain]&.downcase }
                          .compact

          common = buy_networks & sell_networks
          return nil if common.empty?

          # Prioritize by speed (using VolatilityBuffer transfer times)
          buffer = VolatilityBuffer.new
          common.min_by { |n| buffer.send(:transfer_time_for, n.upcase) }
        end

        # Format status for alert message
        # @param symbol [String] base asset
        # @param buy_exchange [String] buy exchange
        # @param sell_exchange [String] sell exchange
        # @param network [String] transfer network
        # @return [String] formatted message
        def format_for_alert(symbol, buy_exchange, sell_exchange, network: nil)
          validation = validate_transfer_route(symbol, buy_exchange, sell_exchange, network: network)

          emoji = validation[:valid] ? '✅' : '⚠️'
          status_text = validation[:valid] ? 'OK' : 'BLOCKED'

          lines = ["#{emoji} TRANSFER STATUS: #{status_text}"]

          if validation[:network]
            lines << "   Network: #{validation[:network].upcase}"
          end

          lines << "   #{buy_exchange.upcase} withdraw: #{format_status(validation[:buy_withdraw_enabled])}"
          lines << "   #{sell_exchange.upcase} deposit: #{format_status(validation[:sell_deposit_enabled])}"

          unless validation[:valid]
            lines << ""
            lines << "   ⚠️ #{validation[:message]}"
          end

          lines.join("\n")
        end

        private

        def fetch_status(symbol, exchange)
          case exchange
          when 'binance'
            fetch_binance_status(symbol)
          when 'bybit'
            fetch_bybit_status(symbol)
          when 'okx'
            fetch_okx_status(symbol)
          when 'gate'
            fetch_gate_status(symbol)
          when 'mexc'
            fetch_mexc_status(symbol)
          when 'kucoin'
            fetch_kucoin_status(symbol)
          when 'htx'
            fetch_htx_status(symbol)
          when 'bitget'
            fetch_bitget_status(symbol)
          else
            { error: "Unknown exchange: #{exchange}" }
          end
        end

        def fetch_binance_status(symbol)
          # Note: This endpoint requires API key for full data
          # Public endpoint only gives trading status, not deposit/withdraw
          uri = URI("https://api.binance.com/api/v3/exchangeInfo?symbol=#{symbol}USDT")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'Binance API error' } unless response.code == '200'

          # For full deposit/withdraw status, we'd need authenticated API
          # Return limited info from public API
          {
            symbol: symbol,
            deposit_enabled: nil, # Unknown from public API
            withdraw_enabled: nil,
            note: 'Full status requires API authentication'
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_bybit_status(symbol)
          uri = URI("https://api.bybit.com/v5/asset/coin/query-info?coin=#{symbol}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'Bybit API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          rows = data.dig('result', 'rows') || []
          coin = rows.first

          return { error: 'Coin not found' } unless coin

          networks = (coin['chains'] || []).map do |chain|
            {
              chain: chain['chain'],
              deposit_enabled: chain['chainDeposit'] == '1',
              withdraw_enabled: chain['chainWithdraw'] == '1'
            }
          end

          {
            symbol: symbol,
            networks: networks,
            deposit_enabled: networks.any? { |n| n[:deposit_enabled] },
            withdraw_enabled: networks.any? { |n| n[:withdraw_enabled] }
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_okx_status(symbol)
          uri = URI("https://www.okx.com/api/v5/asset/currencies?ccy=#{symbol}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'OKX API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          currencies = data['data'] || []

          networks = currencies.map do |c|
            {
              chain: c['chain'],
              deposit_enabled: c['canDep'],
              withdraw_enabled: c['canWd']
            }
          end

          {
            symbol: symbol,
            networks: networks,
            deposit_enabled: networks.any? { |n| n[:deposit_enabled] },
            withdraw_enabled: networks.any? { |n| n[:withdraw_enabled] }
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_gate_status(symbol)
          uri = URI("https://api.gateio.ws/api/v4/spot/currencies/#{symbol}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'Gate API error' } unless response.code == '200'

          data = JSON.parse(response.body)

          {
            symbol: symbol,
            deposit_enabled: !data['deposit_disabled'],
            withdraw_enabled: !data['withdraw_disabled'],
            networks: [] # Gate doesn't expose per-network status in public API
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_mexc_status(symbol)
          uri = URI('https://api.mexc.com/api/v3/capital/config/getall')
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'MEXC API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          coin = data.find { |c| c['coin']&.upcase == symbol.upcase }

          return { error: 'Coin not found' } unless coin

          networks = (coin['networkList'] || []).map do |n|
            {
              chain: n['network'],
              deposit_enabled: n['depositEnable'],
              withdraw_enabled: n['withdrawEnable']
            }
          end

          {
            symbol: symbol,
            networks: networks,
            deposit_enabled: networks.any? { |n| n[:deposit_enabled] },
            withdraw_enabled: networks.any? { |n| n[:withdraw_enabled] }
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_kucoin_status(symbol)
          uri = URI("https://api.kucoin.com/api/v1/currencies/#{symbol}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'KuCoin API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          coin = data['data']

          return { error: 'Coin not found' } unless coin

          {
            symbol: symbol,
            deposit_enabled: coin['isDepositEnabled'],
            withdraw_enabled: coin['isWithdrawEnabled'],
            networks: [] # Would need to parse chains from response
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_htx_status(symbol)
          uri = URI("https://api.huobi.pro/v2/reference/currencies?currency=#{symbol.downcase}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'HTX API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          currencies = data['data'] || []
          coin = currencies.first

          return { error: 'Coin not found' } unless coin

          networks = (coin['chains'] || []).map do |chain|
            {
              chain: chain['chain'],
              deposit_enabled: chain['depositStatus'] == 'allowed',
              withdraw_enabled: chain['withdrawStatus'] == 'allowed'
            }
          end

          {
            symbol: symbol,
            networks: networks,
            deposit_enabled: networks.any? { |n| n[:deposit_enabled] },
            withdraw_enabled: networks.any? { |n| n[:withdraw_enabled] }
          }
        rescue StandardError => e
          { error: e.message }
        end

        def fetch_bitget_status(symbol)
          uri = URI("https://api.bitget.com/api/v2/spot/public/coins?coin=#{symbol}")
          http = Support::SslConfig.create_http(uri, timeout: 5)
          response = http.get(uri.request_uri)

          return { error: 'Bitget API error' } unless response.code == '200'

          data = JSON.parse(response.body)
          coins = data['data'] || []
          coin = coins.first

          return { error: 'Coin not found' } unless coin

          networks = (coin['chains'] || []).map do |chain|
            {
              chain: chain['chain'],
              deposit_enabled: chain['rechargeable'] == 'true',
              withdraw_enabled: chain['withdrawable'] == 'true'
            }
          end

          {
            symbol: symbol,
            networks: networks,
            deposit_enabled: networks.any? { |n| n[:deposit_enabled] },
            withdraw_enabled: networks.any? { |n| n[:withdraw_enabled] }
          }
        rescue StandardError => e
          { error: e.message }
        end

        def network_withdraw_enabled?(status, network)
          return status[:withdraw_enabled] unless network && status[:networks]

          net = status[:networks].find { |n| n[:chain]&.downcase == network.downcase }
          net ? net[:withdraw_enabled] : status[:withdraw_enabled]
        end

        def network_deposit_enabled?(status, network)
          return status[:deposit_enabled] unless network && status[:networks]

          net = status[:networks].find { |n| n[:chain]&.downcase == network.downcase }
          net ? net[:deposit_enabled] : status[:deposit_enabled]
        end

        def format_status(enabled)
          case enabled
          when true then '✅ Enabled'
          when false then '❌ Disabled'
          else '❓ Unknown'
          end
        end

        def get_cached(symbol, exchange)
          key = "#{REDIS_CACHE_KEY}#{exchange}:#{symbol}"
          data = ArbitrageBot.redis.get(key)
          return nil unless data

          JSON.parse(data, symbolize_names: true)
        rescue StandardError
          nil
        end

        def cache_status(symbol, exchange, status)
          key = "#{REDIS_CACHE_KEY}#{exchange}:#{symbol}"
          ArbitrageBot.redis.setex(key, CACHE_TTL, status.to_json)
        rescue StandardError => e
          @logger.debug("[DepositWithdrawChecker] cache error: #{e.message}")
        end
      end
    end
  end
end
