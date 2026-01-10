# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Safety
      class SignalBuilder
        # Final validated signal
        ValidatedSignal = Struct.new(
          :id, :pair_id, :symbol, :signal_type, :strategy_type,
          :low_venue, :high_venue, :prices, :spread, :liquidity,
          :timing, :position_size_usd, :suggested_position_usd,
          :safety_checks, :lagging_info, :fees_estimate,
          :actions, :links, :created_at, :status,
          keyword_init: true
        )

        # Strategy types based on venue combinations
        STRATEGY_TYPES = {
          %i[dex_spot cex_futures] => :DF,      # DEX-Futures
          %i[dex_spot perp_dex] => :DP,          # DEX-PerpDEX
          %i[cex_spot cex_futures] => :SF,       # Spot-Futures
          %i[cex_futures cex_futures] => :FF,    # Futures-Futures
          %i[perp_dex cex_futures] => :PF,       # PerpDEX-Futures
          %i[perp_dex perp_dex] => :PP           # PerpDEX-PerpDEX
        }.freeze

        # Fee estimates by venue type (in %)
        DEFAULT_FEES = {
          dex_spot: 0.3,      # ~0.3% DEX swap fees
          cex_spot: 0.1,      # 0.1% taker fee
          cex_futures: 0.06,  # 0.06% futures taker
          perp_dex: 0.1       # ~0.1% perp dex fee
        }.freeze

        attr_reader :liquidity_checker, :lagging_detector, :settings

        def initialize(settings = {})
          @settings = settings
          @liquidity_checker = LiquidityChecker.new(settings[:liquidity] || settings)
          @lagging_detector = LaggingExchangeDetector.new(settings[:lagging] || settings)
          @logger = ArbitrageBot.logger
        end

        # Build a validated signal from raw signal data
        # @param raw_signal [Hash] signal from orderbook analysis
        # @return [ValidatedSignal]
        def build(raw_signal)
          # Run safety checks
          validation = @liquidity_checker.validate(raw_signal)

          # Detect lagging
          lagging = @lagging_detector.detect_for_signal(raw_signal)

          # Determine signal type and strategy
          signal_type = determine_signal_type(raw_signal, validation, lagging)
          strategy_type = determine_strategy_type(raw_signal)

          # Calculate fees and net profit
          fees = estimate_fees(raw_signal)

          # Get suggested position
          suggested_position = @liquidity_checker.suggest_position_size(raw_signal)

          # Build action instructions
          actions = build_actions(raw_signal, signal_type)

          # Build links
          links = build_links(raw_signal)

          # Build strategy ID
          strategy_id = build_strategy_id(raw_signal, strategy_type)

          ValidatedSignal.new(
            id: strategy_id,
            pair_id: raw_signal[:pair_id] || raw_signal['pair_id'],
            symbol: raw_signal[:symbol] || raw_signal['symbol'],
            signal_type: signal_type,
            strategy_type: strategy_type,
            low_venue: raw_signal[:low_venue] || raw_signal['low_venue'],
            high_venue: raw_signal[:high_venue] || raw_signal['high_venue'],
            prices: build_prices(raw_signal),
            spread: build_spread(raw_signal, fees),
            liquidity: build_liquidity(raw_signal),
            timing: raw_signal[:timing] || raw_signal['timing'],
            position_size_usd: raw_signal[:position_size_usd] || raw_signal['position_size_usd'],
            suggested_position_usd: suggested_position,
            safety_checks: build_safety_summary(validation),
            lagging_info: build_lagging_info(lagging),
            fees_estimate: fees,
            actions: actions,
            links: links,
            created_at: Time.now.to_i,
            status: validation.passed? ? :valid : :failed
          )
        end

        private

        def determine_signal_type(raw_signal, validation, lagging)
          # Signal types: :auto, :manual, :lagging, :invalid
          return :invalid unless validation.passed?
          return :lagging if lagging.lagging

          high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}
          venue_type = (high_venue[:type] || high_venue['type'])&.to_sym

          # Auto = can be automated (high venue is shortable)
          # Manual = requires manual execution (high venue is spot/DEX)
          if LiquidityChecker::SHORTABLE_VENUE_TYPES.include?(venue_type)
            :auto
          else
            :manual
          end
        end

        def determine_strategy_type(raw_signal)
          low_venue = raw_signal[:low_venue] || raw_signal['low_venue'] || {}
          high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}

          low_type = (low_venue[:type] || low_venue['type'])&.to_sym
          high_type = (high_venue[:type] || high_venue['type'])&.to_sym

          STRATEGY_TYPES[[low_type, high_type]] || :unknown
        end

        def estimate_fees(raw_signal)
          low_venue = raw_signal[:low_venue] || raw_signal['low_venue'] || {}
          high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}

          low_type = (low_venue[:type] || low_venue['type'])&.to_sym
          high_type = (high_venue[:type] || high_venue['type'])&.to_sym

          low_fee = DEFAULT_FEES[low_type] || 0.1
          high_fee = DEFAULT_FEES[high_type] || 0.1

          # Entry: buy on low + sell on high
          # Exit: sell on low + buy on high
          entry_fees = low_fee + high_fee
          exit_fees = low_fee + high_fee
          total_fees = entry_fees + exit_fees

          {
            low_venue_fee_pct: low_fee,
            high_venue_fee_pct: high_fee,
            entry_fees_pct: entry_fees,
            exit_fees_pct: exit_fees,
            total_fees_pct: total_fees
          }
        end

        def build_prices(raw_signal)
          prices = raw_signal[:prices] || raw_signal['prices'] || {}
          {
            buy_price: prices[:buy_price] || prices['buy_price'],
            sell_price: prices[:sell_price] || prices['sell_price'],
            buy_slippage_pct: prices[:buy_slippage_pct] || prices['buy_slippage_pct'],
            sell_slippage_pct: prices[:sell_slippage_pct] || prices['sell_slippage_pct'],
            delta: (prices[:sell_price] || prices['sell_price']).to_f -
                   (prices[:buy_price] || prices['buy_price']).to_f
          }
        end

        def build_spread(raw_signal, fees)
          spread = raw_signal[:spread] || raw_signal['spread'] || {}
          nominal = spread[:nominal_pct] || spread['nominal_pct'] || 0
          real = spread[:real_pct] || spread['real_pct'] || 0
          loss = spread[:loss_pct] || spread['loss_pct'] || 0

          net = real - fees[:total_fees_pct]

          {
            nominal_pct: nominal.to_f.round(2),
            real_pct: real.to_f.round(2),
            slippage_loss_pct: loss.to_f.round(2),
            fees_pct: fees[:total_fees_pct].round(2),
            net_pct: net.round(2)
          }
        end

        def build_liquidity(raw_signal)
          liquidity = raw_signal[:liquidity] || raw_signal['liquidity'] || {}
          {
            exit_usd: liquidity[:exit_usd] || liquidity['exit_usd'],
            low_bids_usd: liquidity[:low_bids_usd] || liquidity['low_bids_usd'],
            high_asks_usd: liquidity[:high_asks_usd] || liquidity['high_asks_usd']
          }
        end

        def build_safety_summary(validation)
          {
            passed: validation.passed?,
            checks_count: validation.checks.size,
            passed_count: validation.checks.count(&:passed),
            failed_count: validation.failed_checks.size,
            warnings_count: validation.warnings.size,
            failed_checks: validation.failed_checks.map { |c| c.check_name.to_s },
            messages: validation.failed_checks.map(&:message)
          }
        end

        def build_lagging_info(lagging)
          return nil unless lagging.lagging

          {
            detected: true,
            lagging_venue: lagging.lagging_exchange,
            median_price: lagging.median_price,
            lagging_price: lagging.lagging_price,
            deviation_pct: lagging.deviation_pct,
            other_exchanges_count: lagging.other_exchanges_count
          }
        end

        def build_actions(raw_signal, signal_type)
          low_venue = raw_signal[:low_venue] || raw_signal['low_venue'] || {}
          high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}
          symbol = raw_signal[:symbol] || raw_signal['symbol']

          low_name = venue_display_name(low_venue)
          high_name = venue_display_name(high_venue)
          high_type = (high_venue[:type] || high_venue['type'])&.to_sym

          actions = []

          # Entry actions
          actions << "BUY #{symbol} on #{low_name}"

          if LiquidityChecker::SHORTABLE_VENUE_TYPES.include?(high_type)
            actions << "SHORT #{symbol} on #{high_name}"
          else
            actions << "SELL #{symbol} on #{high_name} (manual)"
          end

          # General instructions
          actions << 'Enter in parts, match sizes'
          actions << 'Wait for convergence'

          {
            entry: actions[0..1],
            instructions: actions[2..],
            signal_type: signal_type
          }
        end

        def build_links(raw_signal)
          low_venue = raw_signal[:low_venue] || raw_signal['low_venue'] || {}
          high_venue = raw_signal[:high_venue] || raw_signal['high_venue'] || {}
          symbol = raw_signal[:symbol] || raw_signal['symbol']

          links = {}

          # Low venue link
          links[:buy] = build_venue_link(low_venue, symbol, :buy)

          # High venue link
          links[:sell] = build_venue_link(high_venue, symbol, :sell)

          # Chart link (DexScreener for DEX, TradingView for CEX)
          links[:chart] = build_chart_link(low_venue, high_venue, symbol)

          links
        end

        def build_venue_link(venue, symbol, action)
          type = (venue[:type] || venue['type'])&.to_sym
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']
          token_address = venue[:token_address] || venue['token_address']

          case type
          when :dex_spot
            case dex&.downcase
            when 'jupiter'
              "https://jup.ag/swap/USDC-#{token_address || symbol}"
            when 'raydium'
              "https://raydium.io/swap/?inputCurrency=USDC&outputCurrency=#{token_address || symbol}"
            else
              nil
            end
          when :cex_spot
            build_cex_spot_link(exchange, symbol)
          when :cex_futures
            build_cex_futures_link(exchange, symbol)
          when :perp_dex
            case dex&.downcase
            when 'hyperliquid'
              "https://app.hyperliquid.xyz/trade/#{symbol}"
            when 'dydx'
              "https://trade.dydx.exchange/trade/#{symbol}-USD"
            when 'gmx'
              "https://app.gmx.io/#/trade"
            else
              nil
            end
          end
        end

        def build_cex_spot_link(exchange, symbol)
          case exchange&.downcase
          when 'binance'
            "https://www.binance.com/trade/#{symbol}_USDT"
          when 'bybit'
            "https://www.bybit.com/trade/spot/#{symbol}/USDT"
          when 'okx'
            "https://www.okx.com/trade-spot/#{symbol.downcase}-usdt"
          when 'gate'
            "https://www.gate.io/trade/#{symbol}_USDT"
          when 'mexc'
            "https://www.mexc.com/exchange/#{symbol}_USDT"
          when 'kucoin'
            "https://www.kucoin.com/trade/#{symbol}-USDT"
          when 'htx'
            "https://www.htx.com/trade/#{symbol.downcase}_usdt"
          when 'bitget'
            "https://www.bitget.com/spot/#{symbol}USDT"
          else
            nil
          end
        end

        def build_cex_futures_link(exchange, symbol)
          case exchange&.downcase
          when 'binance'
            "https://www.binance.com/futures/#{symbol}USDT"
          when 'bybit'
            "https://www.bybit.com/trade/usdt/#{symbol}USDT"
          when 'okx'
            "https://www.okx.com/trade-futures/#{symbol.downcase}-usdt-swap"
          when 'gate'
            "https://www.gate.io/futures_trade/USDT/#{symbol}_USDT"
          when 'mexc'
            "https://futures.mexc.com/exchange/#{symbol}_USDT"
          when 'kucoin'
            "https://www.kucoin.com/futures/trade/#{symbol}USDTM"
          when 'htx'
            "https://www.htx.com/futures/linear_swap/exchange#contract_code=#{symbol}-USDT"
          when 'bitget'
            "https://www.bitget.com/futures/usdt/#{symbol}USDT"
          else
            nil
          end
        end

        def build_chart_link(low_venue, high_venue, symbol)
          low_type = (low_venue[:type] || low_venue['type'])&.to_sym
          token_address = low_venue[:token_address] || low_venue['token_address']

          if low_type == :dex_spot && token_address
            # DexScreener for DEX tokens
            dex = low_venue[:dex] || low_venue['dex']
            network = case dex&.downcase
                      when 'jupiter', 'raydium', 'orca' then 'solana'
                      when 'uniswap', 'sushiswap' then 'ethereum'
                      when 'pancakeswap' then 'bsc'
                      else 'solana'
                      end
            "https://dexscreener.com/#{network}/#{token_address}"
          else
            # TradingView for CEX
            exchange = high_venue[:exchange] || high_venue['exchange'] || 'BINANCE'
            "https://www.tradingview.com/chart/?symbol=#{exchange.upcase}:#{symbol}USDT.P"
          end
        end

        def build_strategy_id(raw_signal, strategy_type)
          symbol = raw_signal[:symbol] || raw_signal['symbol']
          spread = raw_signal[:spread] || raw_signal['spread'] || {}
          real_spread = spread[:real_pct] || spread['real_pct'] || 0

          timestamp = Time.now.to_i % 10_000 # Last 4 digits

          "#{strategy_type}-#{symbol}-S#{real_spread.to_f.round(1)}-#{timestamp}"
        end

        def venue_display_name(venue)
          type = (venue[:type] || venue['type'])&.to_sym
          exchange = venue[:exchange] || venue['exchange']
          dex = venue[:dex] || venue['dex']

          case type
          when :cex_futures
            "#{exchange&.upcase} Futures"
          when :cex_spot
            "#{exchange&.upcase} Spot"
          when :perp_dex
            "#{dex&.capitalize} Perp"
          when :dex_spot
            "#{dex&.capitalize} DEX"
          else
            'Unknown'
          end
        end
      end
    end
  end
end
