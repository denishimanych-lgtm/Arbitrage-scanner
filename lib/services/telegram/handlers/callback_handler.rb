# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Handlers
        # Main callback router for inline keyboard button presses
        class CallbackHandler
          attr_reader :bot, :chat_id, :message_id, :callback_id, :data, :parsed

          def initialize(bot:, chat_id:, message_id:, callback_id:, data:, orchestrator: nil)
            @bot = bot
            @chat_id = chat_id
            @message_id = message_id
            @callback_id = callback_id
            @data = data
            @parsed = CallbackData.decode(data)
            @orchestrator = orchestrator
            @state = State::UserState.new(chat_id)
            @nav = State::NavigationStack.new(chat_id)
            @logger = ArbitrageBot.logger
            @skip_push = false
          end

          def process
            @logger.info("[Callback] Processing: #{@chat_id}: #{@data} -> #{@parsed}")

            case @parsed[:action]
            when :nav
              handle_navigation
            when :set
              handle_setting
            when :tgl
              handle_toggle
            when :bl
              handle_blacklist
            when :pg
              handle_pagination
            when :act
              handle_action
            else
              answer('Unknown action')
            end
          rescue StandardError => e
            @logger.error("[Callback] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
            answer("Error: #{e.message}")
          end

          private

          # Navigation handlers
          def handle_navigation
            case @parsed[:target]
            when :main
              show_main_menu
            when :back
              go_back
            when :close
              close_menu
            when :settings
              show_settings(@parsed[:params].first)
            when :blacklist
              show_blacklist(@parsed[:params].first)
            when :status
              show_status
            when :top
              show_top_spreads
            when :funding
              show_funding
            when :zscores
              show_zscores
            when :stables
              show_stables
            when :stats
              show_stats
            else
              answer("Unknown navigation: #{@parsed[:target]}")
            end
          end

          def show_main_menu
            @nav.clear
            @state.set_state(:main_menu)

            keyboard = Keyboards::MainMenuKeyboard.new(user_id: @chat_id)
            text = Keyboards::MainMenuKeyboard.build_text

            edit_message(text, keyboard.to_reply_markup)
            answer
          end

          def go_back
            prev = @nav.pop
            if prev
              rebuild_menu_for_state(prev[:state], prev[:context])
            else
              show_main_menu
            end
            answer
          end

          def close_menu
            @state.clear
            @nav.clear
            delete_message
            answer('Menu closed')
          end

          def show_settings(submenu = nil)
            # Determine target state based on submenu
            target_state = case submenu
                           when 'sp' then :settings_spread
                           when 'cd' then :settings_cooldown
                           when 'sg' then :settings_signals
                           when 'lq' then :settings_liquidity
                           when 'vl' then :settings_volume
                           when 'ps' then :settings_position
                           when 'sf' then :settings_safety
                           else :settings
                           end

            # Only push if navigating to a different state (not refreshing same menu)
            push_current_state unless @state.current_state == target_state

            keyboard = Keyboards::SettingsKeyboard.new(user_id: @chat_id)
            settings = SettingsLoader.new.load

            case submenu
            when 'sp'
              @state.set_state(:settings_spread)
              kb = keyboard.build_spread_menu
              text = Keyboards::SettingsKeyboard.build_spread_text(settings[:min_spread_pct])
            when 'cd'
              @state.set_state(:settings_cooldown)
              kb = keyboard.build_cooldown_menu
              text = Keyboards::SettingsKeyboard.build_cooldown_text(settings[:alert_cooldown_seconds])
            when 'sg'
              @state.set_state(:settings_signals)
              kb = keyboard.build_signals_menu
              text = Keyboards::SettingsKeyboard.build_signals_text
            when 'lq'
              @state.set_state(:settings_liquidity)
              kb = keyboard.build_liquidity_menu
              text = Keyboards::SettingsKeyboard.build_liquidity_text(
                settings[:min_liquidity_usd],
                settings[:min_dex_liquidity_usd] || 1000,
                settings[:min_exit_liquidity_usd]
              )
            when 'vl'
              @state.set_state(:settings_volume)
              kb = keyboard.build_volume_menu
              text = Keyboards::SettingsKeyboard.build_volume_text(
                settings[:min_volume_24h_dex],
                settings[:min_volume_24h_futures]
              )
            when 'ps'
              @state.set_state(:settings_position)
              kb = keyboard.build_position_menu
              text = Keyboards::SettingsKeyboard.build_position_text(
                settings[:min_position_size_usd],
                settings[:max_position_size_usd],
                settings[:suggested_position_usd]
              )
            when 'sf'
              @state.set_state(:settings_safety)
              kb = keyboard.build_safety_menu
              text = Keyboards::SettingsKeyboard.build_safety_text(
                settings[:max_slippage_pct],
                settings[:max_latency_ms],
                settings[:max_position_to_exit_ratio],
                settings[:max_bid_ask_spread_pct]
              )
            else
              @state.set_state(:settings)
              kb = keyboard.build
              text = Keyboards::SettingsKeyboard.build_text
            end

            edit_message(text, { inline_keyboard: kb })
            answer
          end

          def show_blacklist(submenu = nil)
            # Determine target state based on submenu
            target_state = case submenu
                           when 'sy' then :blacklist_symbols
                           when 'ex' then :blacklist_exchanges
                           when 'pr' then :blacklist_pairs
                           else :blacklist
                           end

            # Only push if navigating to a different state (not refreshing same menu)
            push_current_state unless @state.current_state == target_state

            keyboard = Keyboards::BlacklistKeyboard.new(user_id: @chat_id)
            bl = Alerts::Blacklist.new

            case submenu
            when 'sy'
              @state.set_state(:blacklist_symbols)
              kb = keyboard.build_symbols_menu
              text = Keyboards::BlacklistKeyboard.build_symbols_text(bl.symbols.size)
            when 'ex'
              @state.set_state(:blacklist_exchanges)
              kb = keyboard.build_exchanges_menu
              text = Keyboards::BlacklistKeyboard.build_exchanges_text(bl.exchanges.size)
            when 'pr'
              @state.set_state(:blacklist_pairs)
              kb = keyboard.build_pairs_menu
              text = Keyboards::BlacklistKeyboard.build_pairs_text(bl.pairs.size)
            else
              @state.set_state(:blacklist)
              kb = keyboard.build
              text = Keyboards::BlacklistKeyboard.build_text
            end

            edit_message(text, { inline_keyboard: kb })
            answer
          end

          def show_status
            @logger.info("[Callback] show_status: entering")
            push_current_state
            @logger.info("[Callback] show_status: state pushed")
            @state.set_state(:status)
            @logger.info("[Callback] show_status: state set to :status")

            keyboard = Keyboards::StatusKeyboard.new(user_id: @chat_id)
            @logger.info("[Callback] show_status: keyboard created")
            text = Keyboards::StatusKeyboard.build_text(@orchestrator)
            @logger.info("[Callback] show_status: text built, length=#{text.length}")

            edit_message(text, keyboard.to_reply_markup)
            @logger.info("[Callback] show_status: message edited")
            answer
            @logger.info("[Callback] show_status: done")
          end

          def show_top_spreads(page = 1)
            push_current_state unless @state.current_state == :top_spreads
            @state.set_state(:top_spreads, context: { page: page })

            data = Keyboards::SpreadsKeyboard.load_spreads(page)
            keyboard = Keyboards::SpreadsKeyboard.new(
              user_id: @chat_id,
              page: data[:page],
              total_pages: data[:total_pages]
            )
            text = Keyboards::SpreadsKeyboard.build_text(data[:spreads], data[:page], data[:total])

            edit_message(text, keyboard.to_reply_markup)
            answer
          end

          def show_funding
            push_current_state
            @state.set_state(:funding)

            alerter = Funding::FundingAlerter.new
            text = alerter.format_funding_message

            keyboard = { inline_keyboard: [
              [{ text: '🔄 Refresh', callback_data: CallbackData.encode(:act, :refresh, 'fn') }],
              [{ text: '⬅️ Back', callback_data: CallbackData.encode(:nav, :back) }]
            ] }

            edit_message(text, keyboard)
            answer
          end

          def show_zscores
            push_current_state
            @state.set_state(:zscores)

            tracker = ZScore::ZScoreTracker.new
            zscores = tracker.calculate_all
            alerter = ZScore::ZScoreAlerter.new
            text = alerter.format_zscores_message(zscores)

            keyboard = { inline_keyboard: [
              [{ text: '🔄 Refresh', callback_data: CallbackData.encode(:act, :refresh, 'zs') }],
              [{ text: '⬅️ Back', callback_data: CallbackData.encode(:nav, :back) }]
            ] }

            edit_message(text, keyboard)
            answer
          end

          def show_stables
            push_current_state
            @state.set_state(:stables)

            monitor = Stablecoin::DepegMonitor.new
            prices = monitor.current_prices
            alerter = Stablecoin::DepegAlerter.new
            text = alerter.format_prices_message(prices)

            keyboard = { inline_keyboard: [
              [{ text: '🔄 Refresh', callback_data: CallbackData.encode(:act, :refresh, 'st') }],
              [{ text: '⬅️ Back', callback_data: CallbackData.encode(:nav, :back) }]
            ] }

            edit_message(text, keyboard)
            answer
          end

          def show_stats
            push_current_state
            @state.set_state(:stats)

            text = Analytics::TradeTracker.format_stats_message(days: 30)

            keyboard = { inline_keyboard: [
              [{ text: '7 дней', callback_data: CallbackData.encode(:act, :stats_period, '7') },
               { text: '30 дней', callback_data: CallbackData.encode(:act, :stats_period, '30') },
               { text: '90 дней', callback_data: CallbackData.encode(:act, :stats_period, '90') }],
              [{ text: '🔄 Refresh', callback_data: CallbackData.encode(:act, :refresh, 'st') }],
              [{ text: '⬅️ Back', callback_data: CallbackData.encode(:nav, :back) }]
            ] }

            edit_message(text, keyboard)
            answer
          end

          # Settings handlers
          def handle_setting
            case @parsed[:target]
            when :spread
              handle_spread_setting
            when :cooldown
              handle_cooldown_setting
            when :minliq
              handle_setting_value(:min_liquidity_usd, @parsed[:params][0].to_i, 'Min CEX Liquidity', 'lq')
            when :dexliq
              handle_setting_value(:min_dex_liquidity_usd, @parsed[:params][0].to_i, 'Min DEX Pool', 'lq')
            when :exitliq
              handle_setting_value(:min_exit_liquidity_usd, @parsed[:params][0].to_i, 'Exit Liquidity', 'lq')
            when :voldex
              handle_setting_value(:min_volume_24h_dex, @parsed[:params][0].to_i, 'DEX Volume', 'vl')
            when :volfut
              handle_setting_value(:min_volume_24h_futures, @parsed[:params][0].to_i, 'Futures Volume', 'vl')
            when :minpos
              handle_setting_value(:min_position_size_usd, @parsed[:params][0].to_i, 'Min Position', 'ps')
            when :maxpos
              handle_setting_value(:max_position_size_usd, @parsed[:params][0].to_i, 'Max Position', 'ps')
            when :sugpos
              handle_setting_value(:suggested_position_usd, @parsed[:params][0].to_i, 'Suggested Position', 'ps')
            when :slip
              handle_setting_value(:max_slippage_pct, @parsed[:params][0].to_f, 'Max Slippage', 'sf', '%')
            when :latency
              handle_setting_value(:max_latency_ms, @parsed[:params][0].to_i, 'Max Latency', 'sf', 'ms')
            when :ratio
              handle_setting_value(:max_position_to_exit_ratio, @parsed[:params][0].to_f, 'Position/Exit Ratio', 'sf')
            when :bidask
              handle_setting_value(:max_bid_ask_spread_pct, @parsed[:params][0].to_f, 'Max Bid-Ask', 'sf', '%')
            else
              answer("Unknown setting: #{@parsed[:target]}")
            end
          end

          def handle_setting_value(key, value, label, submenu, suffix = '')
            settings_loader = SettingsLoader.new
            settings_loader.load
            settings_loader.set(key, value)

            display_value = if suffix == '%'
                              "#{value}#{suffix}"
                            elsif value >= 1_000_000
                              "$#{(value / 1_000_000.0).round(1)}M"
                            elsif value >= 1_000
                              "$#{(value / 1_000.0).round(0)}K"
                            elsif suffix.empty? && value.is_a?(Float)
                              "#{(value * 100).to_i}%"
                            else
                              "#{value}#{suffix}"
                            end

            answer("#{label} set to #{display_value}")
            show_settings(submenu)
          end

          def handle_spread_setting
            params = @parsed[:params]
            settings_loader = SettingsLoader.new
            current = settings_loader.load[:min_spread_pct].to_f

            new_value = case params[0]
                        when '+' then current + params[1].to_f
                        when '-' then current - params[1].to_f
                        when '=' then params[1].to_f
                        when 'reset' then 2.0
                        else current
                        end

            # Only enforce minimum (0.1%), no maximum limit
            new_value = [new_value, 0.1].max

            settings_loader.set(:min_spread_pct, new_value)
            answer("Spread set to #{new_value}%")

            # Refresh the settings menu
            show_settings('sp')
          end

          def handle_cooldown_setting
            params = @parsed[:params]
            new_value = params[0].to_i

            # Clamp to valid range
            new_value = [[new_value, 30].max, 3600].min

            settings_loader = SettingsLoader.new
            settings_loader.set(:alert_cooldown_seconds, new_value)
            answer("Cooldown set to #{new_value}s")

            # Refresh the settings menu
            show_settings('cd')
          end

          # Toggle handlers
          def handle_toggle
            settings_loader = SettingsLoader.new
            settings = settings_loader.load

            key = case @parsed[:target]
                  when :auto then :enable_auto_signals
                  when :manual then :enable_manual_signals
                  when :lagging then :enable_lagging_signals
                  when :funding then :enable_funding_alerts
                  when :zscore then :enable_zscore_alerts
                  when :stablecoin then :enable_stablecoin_alerts
                  else
                    answer('Unknown toggle')
                    return
                  end

            # Handle new settings that might not exist yet (default to true)
            current_value = settings[key]
            current_value = true if current_value.nil?
            new_value = !current_value

            settings_loader.set(key, new_value)

            type_name = case @parsed[:target]
                        when :auto then 'Hedged'
                        when :manual then 'Manual'
                        when :lagging then 'Lagging'
                        when :funding then 'Funding Rate'
                        when :zscore then 'Z-Score'
                        when :stablecoin then 'Stablecoin'
                        else @parsed[:target].to_s.capitalize
                        end

            answer("#{type_name} alerts #{new_value ? 'enabled' : 'disabled'}")

            # Refresh signals menu
            show_settings('sg')
          end

          # Blacklist handlers
          def handle_blacklist
            case @parsed[:target]
            when :add
              handle_blacklist_add
            when :remove
              handle_blacklist_remove
            else
              answer("Unknown blacklist action: #{@parsed[:target]}")
            end
          end

          def handle_blacklist_add
            type_code = @parsed[:params][0]
            type_name = decode_type_code(type_code)

            @state.await_input("blacklist_#{type_name}".to_sym)
            @state.update_context(blacklist_type: type_name)

            answer("Send the #{type_name.chomp('s')} name to add:")

            # Update message to show instructions
            text = "\U0001F4DD Add to #{type_name.capitalize} Blacklist\n\n" \
                   "Send the #{type_name.chomp('s')} name in the next message.\n\n" \
                   "Or tap Back to cancel."
            keyboard = { inline_keyboard: [[{ text: "\u2B05\uFE0F Back", callback_data: CallbackData.encode(:nav, :back) }]] }
            edit_message(text, keyboard)
          end

          def handle_blacklist_remove
            type_code = @parsed[:params][0]
            item = @parsed[:params][1]
            type_name = decode_type_code(type_code)

            bl = Alerts::Blacklist.new
            case type_name
            when 'symbols' then bl.remove_symbol(item)
            when 'exchanges' then bl.remove_exchange(item)
            when 'pairs' then bl.remove_pair(item)
            end

            answer("Removed #{item} from #{type_name}")

            # Refresh the list
            show_blacklist(type_code)
          end

          # Pagination handlers
          def handle_pagination
            case @parsed[:target]
            when :top
              page = @parsed[:params][0].to_i
              show_top_spreads(page)
            when :blacklist
              type_code = @parsed[:params][0]
              page = @parsed[:params][1].to_i
              show_blacklist_page(type_code, page)
            else
              answer('Unknown pagination target')
            end
          end

          def show_blacklist_page(type_code, page)
            keyboard = Keyboards::BlacklistKeyboard.new(user_id: @chat_id)
            bl = Alerts::Blacklist.new

            case type_code
            when 'sy'
              @state.set_state(:blacklist_symbols, context: { page: page })
              kb = keyboard.build_symbols_menu(page)
              text = Keyboards::BlacklistKeyboard.build_symbols_text(bl.symbols.size)
            when 'ex'
              @state.set_state(:blacklist_exchanges, context: { page: page })
              kb = keyboard.build_exchanges_menu(page)
              text = Keyboards::BlacklistKeyboard.build_exchanges_text(bl.exchanges.size)
            when 'pr'
              @state.set_state(:blacklist_pairs, context: { page: page })
              kb = keyboard.build_pairs_menu(page)
              text = Keyboards::BlacklistKeyboard.build_pairs_text(bl.pairs.size)
            end

            edit_message(text, { inline_keyboard: kb })
            answer
          end

          # Action handlers
          def handle_action
            case @parsed[:target]
            when :pause
              ArbitrageBot.redis.set('alerts:paused', '1')
              answer('Alerts paused')
              show_main_menu
            when :resume
              ArbitrageBot.redis.del('alerts:paused')
              answer('Alerts resumed')
              show_main_menu
            when :refresh
              handle_refresh
            when :stats_period
              handle_stats_period
            when :noop
              answer
            when :confirm
              handle_confirm
            when :cancel
              go_back
            when :enter_pos
              handle_enter_position
            when :close_pos
              handle_close_position
            else
              answer("Unknown action: #{@parsed[:target]}")
            end
          end

          # Handle "Вступил в позицию" button press
          def handle_enter_position
            short_signal_id = @parsed[:params][0]
            return answer('Signal ID missing') unless short_signal_id

            # Find the signal
            signal = find_signal_by_short_id(short_signal_id)
            unless signal
              return answer('Сигнал не найден')
            end

            # Start position tracking
            tracker = Trackers::PositionTracker.new
            result = tracker.start_tracking(
              signal_id: signal[:id],
              user_id: @chat_id,
              symbol: signal[:symbol],
              pair_id: signal.dig(:details, 'pair_id') || extract_pair_id(signal),
              entry_spread_pct: signal.dig(:details, 'spread_pct') || signal.dig(:details, 'net_spread_pct') || 0,
              telegram_msg_id: @message_id
            )

            if result
              answer('Позиция отслеживается!')
              # Remove keyboard from the alert message
              remove_keyboard_from_message
            else
              answer('Ошибка при создании отслеживания')
            end
          end

          # Handle "Закрыл позицию" button press
          def handle_close_position
            short_position_id = @parsed[:params][0]
            return answer('Position ID missing') unless short_position_id

            tracker = Trackers::PositionTracker.new

            # Find position by short ID
            sql = <<~SQL
              SELECT * FROM position_tracking
              WHERE id::text LIKE $1 || '%'
                AND user_id = $2
              LIMIT 1
            SQL

            position = Analytics::DatabaseConnection.query_one(sql, [short_position_id, @chat_id])

            unless position
              return answer('Позиция не найдена')
            end

            tracker.mark_closed(position[:id])
            answer('Позиция закрыта!')

            # Update message to show position is closed
            text = "Позиция #{position[:symbol]} закрыта\n\n" \
                   "Вход: #{position[:entry_spread_pct].to_f.round(2)}%\n" \
                   "Выход: #{position[:current_spread_pct].to_f.round(2)}%"

            edit_message(text, { inline_keyboard: [] })
          end

          # Find signal by short ID (first 8 chars)
          def find_signal_by_short_id(short_id)
            sql = <<~SQL
              SELECT * FROM signals
              WHERE id::text LIKE $1 || '%'
              ORDER BY created_at DESC
              LIMIT 1
            SQL

            Analytics::DatabaseConnection.query_one(sql, [short_id])
          rescue StandardError => e
            @logger.error("[Callback] find_signal_by_short_id error: #{e.message}")
            nil
          end

          # Extract pair_id from signal details
          def extract_pair_id(signal)
            details = signal[:details] || {}
            buy_venue = details['buy_venue'] || 'unknown'
            sell_venue = details['sell_venue'] || 'unknown'
            "#{buy_venue.downcase.gsub(' ', '_')}:#{sell_venue.downcase.gsub(' ', '_')}"
          end

          # Remove inline keyboard from current message
          def remove_keyboard_from_message
            @bot.edit_message_reply_markup(@chat_id, @message_id, reply_markup: { inline_keyboard: [] })
          rescue StandardError => e
            @logger.debug("[Callback] remove_keyboard error: #{e.message}")
          end

          def handle_stats_period
            days = @parsed[:params][0].to_i
            days = 30 if days <= 0

            text = Analytics::TradeTracker.format_stats_message(days: days)

            keyboard = { inline_keyboard: [
              [{ text: '7 дней', callback_data: CallbackData.encode(:act, :stats_period, '7') },
               { text: '30 дней', callback_data: CallbackData.encode(:act, :stats_period, '30') },
               { text: '90 дней', callback_data: CallbackData.encode(:act, :stats_period, '90') }],
              [{ text: '🔄 Refresh', callback_data: CallbackData.encode(:act, :refresh, 'stats') }],
              [{ text: '⬅️ Back', callback_data: CallbackData.encode(:nav, :back) }]
            ] }

            edit_message(text, keyboard)
            answer("#{days} days")
          end

          def handle_refresh
            target = @parsed[:params][0]
            case target
            when 'ss' then show_status
            when 'tp' then show_top_spreads(@state.context[:page] || 1)
            when 'fn' then show_funding
            when 'zs' then show_zscores
            when 'st' then show_stables
            when 'stats' then show_stats
            else answer('Refreshed')
            end
          end

          def handle_confirm
            # Placeholder for destructive action confirmations
            answer('Action confirmed')
          end

          # Helper methods
          def push_current_state
            return if @skip_push

            current = @state.current_state
            return if current == :idle || current == :main_menu

            @nav.push(current, context: @state.context)
          end

          def rebuild_menu_for_state(state, context = {})
            # Don't push state when rebuilding for back navigation
            @skip_push = true

            case state
            when :main_menu
              show_main_menu
            when :settings
              show_settings
            when :settings_spread
              show_settings('sp')
            when :settings_cooldown
              show_settings('cd')
            when :settings_signals
              show_settings('sg')
            when :settings_liquidity
              show_settings('lq')
            when :settings_volume
              show_settings('vl')
            when :settings_position
              show_settings('ps')
            when :settings_safety
              show_settings('sf')
            when :blacklist
              show_blacklist
            when :blacklist_symbols
              show_blacklist('sy')
            when :blacklist_exchanges
              show_blacklist('ex')
            when :blacklist_pairs
              show_blacklist('pr')
            when :status
              show_status
            when :top_spreads
              show_top_spreads(context[:page] || 1)
            when :funding
              show_funding
            when :zscores
              show_zscores
            when :stables
              show_stables
            when :stats
              show_stats
            else
              show_main_menu
            end
          ensure
            @skip_push = false
          end

          def decode_type_code(code)
            case code
            when 'sy' then 'symbols'
            when 'ex' then 'exchanges'
            when 'pr' then 'pairs'
            else code
            end
          end

          def answer(text = nil)
            @bot.answer_callback_query(@callback_id, text: text)
          end

          def edit_message(text, reply_markup)
            @logger.info("[Callback] Editing message #{@message_id} for #{@chat_id}")
            result = @bot.edit_message(@chat_id, @message_id, text, reply_markup: reply_markup)
            @logger.info("[Callback] Edit result: #{result.class}")
            result
          end

          def delete_message
            @bot.delete_message(@chat_id, @message_id)
          end
        end
      end
    end
  end
end
