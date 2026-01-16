# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Settings menu and submenus for all configurable parameters
        class SettingsKeyboard < BaseKeyboard
          # Main settings menu
          def build
            current_spread = settings[:min_spread_pct]
            current_cooldown = settings[:alert_cooldown_seconds]

            [
              row(
                button(
                  "📊 Spread: #{current_spread}%",
                  CallbackData.encode(:nav, :settings, 'sp')
                )
              ),
              row(
                button(
                  "⏱️ Cooldown: #{current_cooldown}s",
                  CallbackData.encode(:nav, :settings, 'cd')
                )
              ),
              row(
                button(
                  "🔔 Signal Types",
                  CallbackData.encode(:nav, :settings, 'sg')
                )
              ),
              row(
                button(
                  "💧 Liquidity",
                  CallbackData.encode(:nav, :settings, 'lq')
                ),
                button(
                  "📈 Volume",
                  CallbackData.encode(:nav, :settings, 'vl')
                )
              ),
              row(
                button(
                  "💰 Position Sizing",
                  CallbackData.encode(:nav, :settings, 'ps')
                ),
                button(
                  "🛡️ Safety",
                  CallbackData.encode(:nav, :settings, 'sf')
                )
              ),
              back_row
            ]
          end

          # Spread threshold adjustment menu
          def build_spread_menu
            current = settings[:min_spread_pct].to_f

            [
              row(button("Current: #{current}%", CallbackData.encode(:act, :noop))),
              row(
                button('-1%', CallbackData.encode(:set, :spread, '-', '1')),
                button('-0.5%', CallbackData.encode(:set, :spread, '-', '0.5')),
                button('-0.1%', CallbackData.encode(:set, :spread, '-', '0.1'))
              ),
              row(
                button('+0.1%', CallbackData.encode(:set, :spread, '+', '0.1')),
                button('+0.5%', CallbackData.encode(:set, :spread, '+', '0.5')),
                button('+1%', CallbackData.encode(:set, :spread, '+', '1'))
              ),
              row(
                button('0.5%', CallbackData.encode(:set, :spread, '=', '0.5')),
                button('1%', CallbackData.encode(:set, :spread, '=', '1')),
                button('2%', CallbackData.encode(:set, :spread, '=', '2')),
                button('3%', CallbackData.encode(:set, :spread, '=', '3'))
              ),
              row(
                button("🔄 Reset (2%)", CallbackData.encode(:set, :spread, 'reset'))
              ),
              back_row
            ]
          end

          # Cooldown adjustment menu
          def build_cooldown_menu
            current = settings[:alert_cooldown_seconds].to_i
            presets = [30, 60, 120, 300, 600, 1800]

            rows = [row(button("Current: #{current}s", CallbackData.encode(:act, :noop)))]

            # Create preset buttons in rows of 3
            presets.each_slice(3) do |batch|
              rows << row(*batch.map do |sec|
                marker = sec == current ? '✓ ' : ''
                button("#{marker}#{sec}s", CallbackData.encode(:set, :cooldown, sec.to_s))
              end)
            end

            rows << back_row
            rows
          end

          # Signal type toggles menu
          def build_signals_menu
            auto_enabled = settings[:enable_auto_signals]
            manual_enabled = settings[:enable_manual_signals]
            lagging_enabled = settings[:enable_lagging_signals]
            funding_enabled = settings[:enable_funding_alerts] != false
            zscore_enabled = settings[:enable_zscore_alerts] != false
            stablecoin_enabled = settings[:enable_stablecoin_alerts] != false

            [
              row(button("━━ SPATIAL ARBITRAGE ━━", CallbackData.encode(:act, :noop))),
              row(
                button(
                  "#{auto_enabled ? '✅' : '❌'} Hedged (Auto)",
                  CallbackData.encode(:tgl, :auto)
                ),
                button(
                  "#{manual_enabled ? '✅' : '❌'} Manual",
                  CallbackData.encode(:tgl, :manual)
                )
              ),
              row(
                button(
                  "#{lagging_enabled ? '✅' : '❌'} Lagging Exchange",
                  CallbackData.encode(:tgl, :lagging)
                )
              ),
              row(button("━━ NEW STRATEGIES ━━", CallbackData.encode(:act, :noop))),
              row(
                button(
                  "#{funding_enabled ? '✅' : '❌'} 💰 Funding Rate",
                  CallbackData.encode(:tgl, :funding)
                )
              ),
              row(
                button(
                  "#{zscore_enabled ? '✅' : '❌'} 📊 Z-Score (Stat Arb)",
                  CallbackData.encode(:tgl, :zscore)
                )
              ),
              row(
                button(
                  "#{stablecoin_enabled ? '✅' : '❌'} 💵 Stablecoin Depeg",
                  CallbackData.encode(:tgl, :stablecoin)
                )
              ),
              back_row
            ]
          end

          # Text for settings menu
          def self.build_text
            <<~MSG
              ⚙️ Settings

              Configure alert parameters:

              📊 Spread - Minimum spread % for alerts
              ⏱️ Cooldown - Time between alerts
              🔔 Signal Types - Enable/disable signals
              💧 Liquidity - Min liquidity requirements
              📈 Volume - Min volume thresholds
              💰 Position - Position size limits
              🛡️ Safety - Slippage, latency, ratios
            MSG
          end

          # Text for spread submenu
          def self.build_spread_text(current)
            <<~MSG
              📊 Spread Threshold

              Current: #{current}%

              Adjust the minimum spread percentage required to trigger alerts.
              Higher = fewer alerts, lower = more alerts.

              Minimum: 0.1% (no maximum limit)
            MSG
          end

          # Text for cooldown submenu
          def self.build_cooldown_text(current)
            <<~MSG
              ⏱️ Alert Cooldown

              Current: #{current}s

              Time to wait before sending another alert for the same symbol.
              Prevents alert spam.

              Range: 30s - 3600s
            MSG
          end

          # Text for signals submenu
          def self.build_signals_text
            <<~MSG
              🔔 Signal Types

              SPATIAL ARBITRAGE (CEX spread):
              🔥 Hedged - Buy spot + Short futures (safe)
              ⚠️ Manual - Requires manual transfer (risky)
              ⏱️ Lagging - Slow exchange detection

              NEW STRATEGIES:
              💰 Funding - High funding rate opportunities
              📊 Z-Score - Statistical arbitrage (mean reversion)
              💵 Stablecoin - Depeg event alerts
            MSG
          end

          # Liquidity settings menu
          def build_liquidity_menu
            min_liq = format_usd(settings[:min_liquidity_usd])
            min_dex_liq = format_usd(settings[:min_dex_liquidity_usd] || 1000)
            min_exit = format_usd(settings[:min_exit_liquidity_usd])

            [
              row(button("Min CEX Liquidity: #{min_liq}", CallbackData.encode(:act, :noop))),
              row(
                button('$100K', CallbackData.encode(:set, :minliq, '100000')),
                button('$250K', CallbackData.encode(:set, :minliq, '250000')),
                button('$500K', CallbackData.encode(:set, :minliq, '500000'))
              ),
              row(
                button('$1M', CallbackData.encode(:set, :minliq, '1000000')),
                button('$2M', CallbackData.encode(:set, :minliq, '2000000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Min DEX Pool: #{min_dex_liq}", CallbackData.encode(:act, :noop))),
              row(
                button('$1K', CallbackData.encode(:set, :dexliq, '1000')),
                button('$5K', CallbackData.encode(:set, :dexliq, '5000')),
                button('$10K', CallbackData.encode(:set, :dexliq, '10000'))
              ),
              row(
                button('$25K', CallbackData.encode(:set, :dexliq, '25000')),
                button('$50K', CallbackData.encode(:set, :dexliq, '50000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Exit Liquidity: #{min_exit}", CallbackData.encode(:act, :noop))),
              row(
                button('$1K', CallbackData.encode(:set, :exitliq, '1000')),
                button('$5K', CallbackData.encode(:set, :exitliq, '5000')),
                button('$10K', CallbackData.encode(:set, :exitliq, '10000'))
              ),
              row(
                button('$25K', CallbackData.encode(:set, :exitliq, '25000')),
                button('$50K', CallbackData.encode(:set, :exitliq, '50000'))
              ),
              back_row
            ]
          end

          # Text for liquidity submenu
          def self.build_liquidity_text(min_liq, min_dex_liq, min_exit)
            <<~MSG
              💧 Liquidity Settings

              Min CEX Liquidity: $#{format('%<n>.0f', n: min_liq.to_f)}
              Min DEX Pool: $#{format('%<n>.0f', n: min_dex_liq.to_f)}
              Min Exit Liquidity: $#{format('%<n>.0f', n: min_exit.to_f)}

              Min CEX - Minimum CEX pool TVL required
              Min DEX - Minimum DEX pool liquidity (filters dust pools)
              Exit Liquidity - Min orderbook depth for exits
            MSG
          end

          # Volume settings menu
          def build_volume_menu
            vol_dex = format_usd(settings[:min_volume_24h_dex])
            vol_futures = format_usd(settings[:min_volume_24h_futures])

            [
              row(button("DEX Volume 24h: #{vol_dex}", CallbackData.encode(:act, :noop))),
              row(
                button('$50K', CallbackData.encode(:set, :voldex, '50000')),
                button('$100K', CallbackData.encode(:set, :voldex, '100000')),
                button('$200K', CallbackData.encode(:set, :voldex, '200000'))
              ),
              row(
                button('$500K', CallbackData.encode(:set, :voldex, '500000')),
                button('$1M', CallbackData.encode(:set, :voldex, '1000000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Futures Volume 24h: #{vol_futures}", CallbackData.encode(:act, :noop))),
              row(
                button('$50K', CallbackData.encode(:set, :volfut, '50000')),
                button('$100K', CallbackData.encode(:set, :volfut, '100000')),
                button('$200K', CallbackData.encode(:set, :volfut, '200000'))
              ),
              row(
                button('$500K', CallbackData.encode(:set, :volfut, '500000')),
                button('$1M', CallbackData.encode(:set, :volfut, '1000000'))
              ),
              back_row
            ]
          end

          # Text for volume submenu
          def self.build_volume_text(vol_dex, vol_futures)
            <<~MSG
              📈 Volume Settings

              DEX Volume 24h: $#{format('%<n>.0f', n: vol_dex.to_f)}
              Futures Volume 24h: $#{format('%<n>.0f', n: vol_futures.to_f)}

              Minimum 24h trading volume required for:
              • DEX tokens (spot)
              • Futures markets (shorts)
            MSG
          end

          # Position sizing menu
          def build_position_menu
            min_pos = format_usd(settings[:min_position_size_usd])
            max_pos = format_usd(settings[:max_position_size_usd])
            suggested = format_usd(settings[:suggested_position_usd])

            [
              row(button("Min Position: #{min_pos}", CallbackData.encode(:act, :noop))),
              row(
                button('$500', CallbackData.encode(:set, :minpos, '500')),
                button('$1K', CallbackData.encode(:set, :minpos, '1000')),
                button('$2K', CallbackData.encode(:set, :minpos, '2000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Max Position: #{max_pos}", CallbackData.encode(:act, :noop))),
              row(
                button('$10K', CallbackData.encode(:set, :maxpos, '10000')),
                button('$25K', CallbackData.encode(:set, :maxpos, '25000')),
                button('$50K', CallbackData.encode(:set, :maxpos, '50000'))
              ),
              row(
                button('$100K', CallbackData.encode(:set, :maxpos, '100000')),
                button('$200K', CallbackData.encode(:set, :maxpos, '200000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Suggested: #{suggested}", CallbackData.encode(:act, :noop))),
              row(
                button('$5K', CallbackData.encode(:set, :sugpos, '5000')),
                button('$10K', CallbackData.encode(:set, :sugpos, '10000')),
                button('$25K', CallbackData.encode(:set, :sugpos, '25000'))
              ),
              back_row
            ]
          end

          # Text for position sizing submenu
          def self.build_position_text(min_pos, max_pos, suggested)
            <<~MSG
              💰 Position Sizing

              Min Position: $#{format('%<n>.0f', n: min_pos.to_f)}
              Max Position: $#{format('%<n>.0f', n: max_pos.to_f)}
              Suggested: $#{format('%<n>.0f', n: suggested.to_f)}

              Position is automatically sized based on:
              • Exit liquidity available
              • Max position/exit ratio (50%)
              • These min/max constraints
            MSG
          end

          # Safety settings menu
          def build_safety_menu
            max_slip = settings[:max_slippage_pct].to_f
            max_latency = settings[:max_latency_ms].to_i
            pos_exit_ratio = settings[:max_position_to_exit_ratio].to_f
            bid_ask = settings[:max_bid_ask_spread_pct].to_f

            [
              row(button("Max Slippage: #{max_slip}%", CallbackData.encode(:act, :noop))),
              row(
                button('0.5%', CallbackData.encode(:set, :slip, '0.5')),
                button('1%', CallbackData.encode(:set, :slip, '1')),
                button('2%', CallbackData.encode(:set, :slip, '2')),
                button('3%', CallbackData.encode(:set, :slip, '3'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Max Latency: #{max_latency}ms", CallbackData.encode(:act, :noop))),
              row(
                button('1s', CallbackData.encode(:set, :latency, '1000')),
                button('3s', CallbackData.encode(:set, :latency, '3000')),
                button('5s', CallbackData.encode(:set, :latency, '5000')),
                button('10s', CallbackData.encode(:set, :latency, '10000'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Pos/Exit Ratio: #{(pos_exit_ratio * 100).to_i}%", CallbackData.encode(:act, :noop))),
              row(
                button('25%', CallbackData.encode(:set, :ratio, '0.25')),
                button('50%', CallbackData.encode(:set, :ratio, '0.5')),
                button('75%', CallbackData.encode(:set, :ratio, '0.75'))
              ),
              row(button("━━━━━━━━━━━━━━━━━━━━", CallbackData.encode(:act, :noop))),
              row(button("Max Bid-Ask: #{bid_ask}%", CallbackData.encode(:act, :noop))),
              row(
                button('0.5%', CallbackData.encode(:set, :bidask, '0.5')),
                button('1%', CallbackData.encode(:set, :bidask, '1')),
                button('2%', CallbackData.encode(:set, :bidask, '2'))
              ),
              back_row
            ]
          end

          # Text for safety submenu
          def self.build_safety_text(slip, latency, ratio, bidask)
            <<~MSG
              🛡️ Safety Settings

              Max Slippage: #{slip}%
              Max Latency: #{latency}ms
              Position/Exit Ratio: #{(ratio.to_f * 100).to_i}%
              Max Bid-Ask Spread: #{bidask}%

              These protect against:
              • Price slippage on entries/exits
              • Stale price data
              • Positions too large for liquidity
              • Wide bid-ask spreads
            MSG
          end

          private

          def format_usd(amount)
            amount = amount.to_i
            if amount >= 1_000_000
              "$#{(amount / 1_000_000.0).round(1)}M"
            elsif amount >= 1_000
              "$#{(amount / 1_000.0).round(0)}K"
            else
              "$#{amount}"
            end
          end
        end
      end
    end
  end
end
