# frozen_string_literal: true

require 'net/http'
require 'json'

module ArbitrageBot
  module Services
    module Telegram
      class Bot
        POLL_TIMEOUT = 30
        COMMANDS = %w[start help status top threshold cooldown blacklist venues pause resume menu stats taken result signals funding zscores stables].freeze
        CALLBACK_RATE_LIMIT_KEY = 'tg:rate:cb:'

        attr_reader :token, :chat_id, :orchestrator

        # Rate limiting settings
        DEFAULT_COMMAND_COOLDOWN_SEC = 1.0  # Min seconds between commands per user
        MAX_COMMANDS_PER_MINUTE = 30        # Max commands per user per minute

        def initialize(orchestrator: nil)
          @token = ENV['TELEGRAM_BOT_TOKEN']
          @chat_id = ENV['TELEGRAM_CHAT_ID']
          @orchestrator = orchestrator
          @logger = ArbitrageBot.logger
          # Don't cache Redis - use thread-local via ArbitrageBot.redis
          @running = false
          @offset = 0
          @paused = false

          # Rate limiting state
          @user_last_command = {}  # chat_id => last_command_time
          @user_command_count = {} # chat_id => [timestamps in last minute]

          # Initialize helpers
          @settings_loader = SettingsLoader.new
          @settings = @settings_loader.load
          @blacklist = Alerts::Blacklist.new
          @cooldown = Alerts::CooldownManager.new
          @formatter = Alerts::AlertFormatter.new
        end

        def run
          return unless configured?

          @running = true
          log('Bot started, listening for commands...')

          poll_count = 0
          while @running
            begin
              poll_count += 1
              @logger.debug("[TelegramBot] Polling... (#{poll_count})") if poll_count % 10 == 1
              updates = get_updates
              if updates.any?
                @logger.info("[TelegramBot] Got #{updates.length} updates")
              end
              updates.each { |update| handle_update(update) }
            rescue StandardError => e
              @logger.error("[TelegramBot] Poll error: #{e.message}")
              sleep 5
            end
          end
        end

        def stop
          @running = false
        end

        def configured?
          @token && !@token.empty?
        end

        # === Public methods for handlers ===

        def answer_callback_query(callback_id, text: nil, show_alert: false)
          uri = URI("https://api.telegram.org/bot#{@token}/answerCallbackQuery")

          http = Support::SslConfig.create_http(uri, timeout: 10)

          params = { callback_query_id: callback_id }
          params[:text] = text if text
          params[:show_alert] = show_alert if show_alert

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Host'] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request['Content-Type'] = 'application/json'
          request.body = params.to_json

          response = http.request(request)
          result = JSON.parse(response.body)
          unless result['ok']
            @logger.error("[TelegramBot] Answer callback API error: #{result['description']}")
          end
          result
        rescue StandardError => e
          @logger.error("[TelegramBot] Answer callback failed: #{e.message}")
        end

        def edit_message(chat_id, message_id, text, reply_markup: nil)
          uri = URI("https://api.telegram.org/bot#{@token}/editMessageText")

          http = Support::SslConfig.create_http(uri, timeout: 10)

          params = {
            chat_id: chat_id,
            message_id: message_id,
            text: text
          }
          params[:reply_markup] = reply_markup if reply_markup

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Host'] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request['Content-Type'] = 'application/json'
          request.body = params.to_json

          response = http.request(request)
          result = JSON.parse(response.body)
          unless result['ok']
            @logger.error("[TelegramBot] Edit message API error: #{result['description']}")
          end
          result
        rescue StandardError => e
          @logger.error("[TelegramBot] Edit message failed: #{e.message}")
          nil
        end

        def delete_message(chat_id, message_id)
          uri = URI("https://api.telegram.org/bot#{@token}/deleteMessage")

          http = Support::SslConfig.create_http(uri, timeout: 10)

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Host'] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request['Content-Type'] = 'application/json'
          request.body = {
            chat_id: chat_id,
            message_id: message_id
          }.to_json

          http.request(request)
        rescue StandardError => e
          @logger.error("[TelegramBot] Delete message failed: #{e.message}")
        end

        private

        def get_updates
          uri = URI("https://api.telegram.org/bot#{@token}/getUpdates")
          uri.query = URI.encode_www_form(
            offset: @offset,
            timeout: POLL_TIMEOUT,
            allowed_updates: %w[message callback_query]
          )

          response = http_get(uri)
          result = JSON.parse(response.body)

          return [] unless result['ok']

          updates = result['result'] || []
          @offset = updates.last['update_id'] + 1 if updates.any?

          updates
        end

        def handle_update(update)
          @logger.debug("[TelegramBot] Processing update: #{update['update_id']}")

          # Handle callback queries (button presses)
          if update['callback_query']
            @logger.info("[TelegramBot] Callback query: #{update['callback_query']['data']}")
            handle_callback_query(update['callback_query'])
            return
          end

          @logger.debug("[TelegramBot] Not a callback, checking message...")

          message = update['message']
          return unless message

          chat_id = message['chat']['id']
          text = message['text']&.strip
          @logger.debug("[TelegramBot] Message from #{chat_id}: #{text}")

          # Check if user is awaiting text input (for blacklist add)
          begin
            state = State::UserState.new(chat_id)
            if state.awaiting_input? && text && !text.start_with?('/')
              handle_text_input(chat_id, text, state)
              return
            end
          rescue => e
            @logger.error("[TelegramBot] State check error: #{e.message}")
          end

          return unless text&.start_with?('/')

          # Check authorization
          unless authorized?(chat_id)
            send_message(chat_id, "Unauthorized. Your chat ID: #{chat_id}")
            return
          end

          # Check rate limit
          unless check_rate_limit(chat_id)
            send_message(chat_id, "\u23F1 Too many commands. Please wait a moment.")
            return
          end

          # Parse command
          parts = text.split(' ')
          command = parts[0].delete_prefix('/').split('@').first
          args = parts[1..]

          # Handle command
          handle_command(chat_id, command, args)
        end

        def handle_callback_query(callback_query)
          chat_id = callback_query['message']['chat']['id']
          message_id = callback_query['message']['message_id']
          callback_id = callback_query['id']
          data = callback_query['data']

          @logger.info("[TelegramBot] Processing callback from chat_id=#{chat_id}, data=#{data}")

          # Check authorization
          unless authorized?(chat_id)
            @logger.warn("[TelegramBot] Unauthorized callback from #{chat_id}")
            answer_callback_query(callback_id, text: 'Unauthorized')
            return
          end

          @logger.debug("[TelegramBot] Authorization passed for #{chat_id}")

          # Check callback rate limit
          begin
            rate_ok = check_callback_rate_limit(chat_id)
            @logger.debug("[TelegramBot] Rate limit check returned: #{rate_ok}")
            unless rate_ok
              @logger.debug("[TelegramBot] Rate limited for #{chat_id}")
              answer_callback_query(callback_id, text: 'Too fast! Please wait.')
              return
            end
          rescue StandardError => e
            @logger.error("[TelegramBot] Rate limit check error: #{e.message}")
            @logger.error(e.backtrace.first(3).join("\n"))
          end

          @logger.debug("[TelegramBot] Rate limit passed for #{chat_id}")

          # Route to callback handler
          @logger.info("[TelegramBot] Creating callback handler...")
          handler = Handlers::CallbackHandler.new(
            bot: self,
            chat_id: chat_id,
            message_id: message_id,
            callback_id: callback_id,
            data: data,
            orchestrator: @orchestrator
          )

          @logger.info("[TelegramBot] Calling handler.process...")
          handler.process
          @logger.info("[TelegramBot] Handler.process complete")
        rescue StandardError => e
          @logger.error("[TelegramBot] Callback error: #{e.class}: #{e.message}")
          @logger.error(e.backtrace.first(10).join("\n"))
          answer_callback_query(callback_id, text: 'Error processing request')
        end

        def handle_text_input(chat_id, text, state)
          input_type = state.awaiting_input_type
          context = state.context

          case input_type
          when :blacklist_symbols
            bl = Alerts::Blacklist.new
            bl.add_symbol(text.upcase.strip)
            send_message(chat_id, "\u2705 Added #{text.upcase.strip} to symbols blacklist")
          when :blacklist_exchanges
            bl = Alerts::Blacklist.new
            bl.add_exchange(text.downcase.strip)
            send_message(chat_id, "\u2705 Added #{text.downcase.strip} to exchanges blacklist")
          when :blacklist_pairs
            bl = Alerts::Blacklist.new
            bl.add_pair(text.strip)
            send_message(chat_id, "\u2705 Added #{text.strip} to pairs blacklist")
          end

          # Clear awaiting state and show main menu
          state.set_state(:main_menu)
          cmd_menu(chat_id)
        end

        def authorized?(chat_id)
          allowed = (@chat_id || '').split(',').map(&:strip)
          allowed.include?(chat_id.to_s)
        end

        # Check if user is within rate limits
        # @param chat_id [Integer, String] User's chat ID
        # @return [Boolean] true if allowed, false if rate limited
        def check_rate_limit(chat_id)
          now = Time.now

          # Check cooldown between commands
          last_command = @user_last_command[chat_id]
          if last_command && (now - last_command) < DEFAULT_COMMAND_COOLDOWN_SEC
            @logger.debug("[TelegramBot] Rate limit: command cooldown for #{chat_id}")
            return false
          end

          # Check commands per minute limit
          @user_command_count[chat_id] ||= []
          # Remove timestamps older than 60 seconds
          @user_command_count[chat_id].reject! { |t| now - t > 60 }

          if @user_command_count[chat_id].size >= MAX_COMMANDS_PER_MINUTE
            @logger.warn("[TelegramBot] Rate limit: max commands/min exceeded for #{chat_id}")
            return false
          end

          # Record this command
          @user_last_command[chat_id] = now
          @user_command_count[chat_id] << now

          true
        end

        def handle_command(chat_id, command, args)
          case command
          when 'start'
            cmd_start(chat_id)
          when 'help'
            cmd_help(chat_id)
          when 'menu'
            cmd_menu(chat_id)
          when 'status'
            cmd_status(chat_id)
          when 'top'
            cmd_top(chat_id, args)
          when 'threshold'
            cmd_threshold(chat_id, args)
          when 'cooldown'
            cmd_cooldown(chat_id, args)
          when 'blacklist'
            cmd_blacklist(chat_id, args)
          when 'venues'
            cmd_venues(chat_id)
          when 'pause'
            cmd_pause(chat_id)
          when 'resume'
            cmd_resume(chat_id)
          when 'stats'
            cmd_stats(chat_id, args)
          when 'taken'
            cmd_taken(chat_id, args)
          when 'result'
            cmd_result(chat_id, args)
          when 'signals'
            cmd_signals(chat_id, args)
          when 'funding'
            cmd_funding(chat_id, args)
          when 'zscores'
            cmd_zscores(chat_id)
          when 'stables'
            cmd_stables(chat_id)
          when 'convergence'
            cmd_convergence(chat_id, args)
          else
            send_message(chat_id, "Unknown command: /#{command}\nUse /help for available commands.")
          end
        end

        # === Commands ===

        def cmd_start(chat_id)
          # Show main menu with keyboard
          cmd_menu(chat_id)
        end

        def cmd_help(chat_id)
          send_message(chat_id, <<~MSG)
            Available Commands:

            /menu - Interactive menu with buttons
            /status - System status and statistics
            /top [N] - Top N spreads (default: 10)
            /threshold <N> - Set minimum spread % (e.g., /threshold 3.5)
            /cooldown <sec> - Set alert cooldown in seconds
            /blacklist - Show blacklist
            /blacklist add <SYMBOL> - Add to blacklist
            /blacklist remove <SYMBOL> - Remove from blacklist
            /venues - Show connected exchanges
            /pause - Pause alerts
            /resume - Resume alerts

            Signal Tracking:
            /taken <ID> - Mark signal as taken
            /result <ID> +X% [notes] - Record trade result
            /signals [N] - Show last N signals (default: 10)
            /stats [strategy] - Trading statistics

            Funding:
            /funding [SYMBOL] - Current funding rates

            Z-Score:
            /zscores - Current z-score pairs status

            Stablecoins:
            /stables - Current stablecoin prices

            Analytics:
            /convergence [days] - Spread convergence stats
          MSG
        end

        def cmd_menu(chat_id)
          keyboard = Keyboards::MainMenuKeyboard.new(user_id: chat_id)
          text = Keyboards::MainMenuKeyboard.build_text

          state = State::UserState.new(chat_id)
          state.set_state(:main_menu)

          # Clear navigation stack when opening fresh menu
          nav = State::NavigationStack.new(chat_id)
          nav.clear

          result = send_message_with_keyboard(chat_id, text, keyboard.to_reply_markup)

          # Store message ID for editing
          if result && result['ok']
            state.set_message_id(result.dig('result', 'message_id'))
          end
        end

        def cmd_status(chat_id)
          status = @orchestrator&.status || {}
          uptime = format_duration(status[:uptime] || 0)
          threads = status[:threads] || {}
          stats = load_alert_stats

          msg = <<~MSG
            System Status

            Uptime: #{uptime}
            Redis: #{status[:redis] ? 'Connected' : 'Disconnected'}
            Alerts: #{@paused ? 'PAUSED' : 'Active'}

            Workers:
            #{threads.map { |k, v| "  #{k}: #{v}" }.join("\n")}

            Settings:
              Min spread: #{@settings[:min_spread_pct]}%
              Cooldown: #{@settings[:alert_cooldown_seconds]}s

            Alerts (24h):
              Sent: #{stats[:alerts_sent] || 0}
              Blocked: #{stats[:cooldown_blocked] || 0}
              Queue: #{stats[:queue_size] || 0}

            Last update: #{Time.now.strftime('%H:%M:%S')}
          MSG

          send_message(chat_id, msg)
        end

        def cmd_top(chat_id, args)
          limit = (args[0] || 10).to_i.clamp(1, 50)

          # Get latest spreads from Redis
          spreads_json = ArbitrageBot.redis.get('spreads:latest')
          return send_message(chat_id, 'No spread data available.') unless spreads_json

          spreads = JSON.parse(spreads_json)
                        .sort_by { |s| -s['spread_pct'].to_f.abs }
                        .first(limit)

          return send_message(chat_id, 'No spreads found.') if spreads.empty?

          lines = spreads.map.with_index do |s, i|
            spread = s['spread_pct'].to_f
            direction = spread > 0 ? 'SHORT' : 'LONG'
            "#{i + 1}. #{s['symbol']} | #{spread.abs.round(2)}% #{direction}\n" \
              "   $#{format_price(s['buy_price'])} -> $#{format_price(s['sell_price'])}"
          end

          msg = "Top #{limit} Spreads (live)\n\n#{lines.join("\n\n")}\n\nUpdated: #{Time.now.strftime('%H:%M:%S')}"
          send_message(chat_id, msg)
        end

        def cmd_threshold(chat_id, args)
          if args.empty?
            send_message(chat_id, "Current threshold: #{@settings[:min_spread_pct]}%\n\nUsage: /threshold <percent>")
            return
          end

          new_threshold = args[0].to_f
          if new_threshold < 0.1
            send_message(chat_id, 'Threshold must be at least 0.1%')
            return
          end

          @settings_loader.set(:min_spread_pct, new_threshold)
          @settings = @settings_loader.load

          send_message(chat_id, "Minimum spread threshold updated to #{new_threshold}%")
        end

        def cmd_cooldown(chat_id, args)
          if args.empty?
            send_message(chat_id, "Current cooldown: #{@settings[:alert_cooldown_seconds]}s\n\nUsage: /cooldown <seconds>")
            return
          end

          new_cooldown = args[0].to_i
          if new_cooldown < 30 || new_cooldown > 3600
            send_message(chat_id, 'Cooldown must be between 30 and 3600 seconds')
            return
          end

          @settings_loader.set(:alert_cooldown_seconds, new_cooldown)
          @settings = @settings_loader.load

          send_message(chat_id, "Alert cooldown updated to #{new_cooldown} seconds")
        end

        def cmd_blacklist(chat_id, args)
          if args.empty?
            symbols = @blacklist.symbols
            if symbols.empty?
              send_message(chat_id, "Blacklist is empty.\n\nUsage:\n/blacklist add <SYMBOL>\n/blacklist remove <SYMBOL>")
            else
              send_message(chat_id, "Blacklisted symbols (#{symbols.size}):\n#{symbols.join(', ')}")
            end
            return
          end

          action = args[0]&.downcase
          symbol = args[1]&.upcase

          case action
          when 'add'
            return send_message(chat_id, 'Usage: /blacklist add <SYMBOL>') unless symbol

            @blacklist.add_symbol(symbol)
            send_message(chat_id, "Added #{symbol} to blacklist")

          when 'remove', 'rm', 'del'
            return send_message(chat_id, 'Usage: /blacklist remove <SYMBOL>') unless symbol

            @blacklist.remove_symbol(symbol)
            send_message(chat_id, "Removed #{symbol} from blacklist")

          else
            send_message(chat_id, "Unknown action: #{action}\n\nUsage:\n/blacklist add <SYMBOL>\n/blacklist remove <SYMBOL>")
          end
        end

        def cmd_venues(chat_id)
          storage = Storage::TickerStorage.new
          symbols = storage.all_symbols

          # Count by venue type
          venues = Hash.new(0)
          symbols.each do |sym|
            ticker = storage.get(sym)
            next unless ticker

            ticker.venues.each do |v|
              key = "#{v[:exchange] || v[:dex]} (#{v[:type]})"
              venues[key] += 1
            end
          end

          if venues.empty?
            send_message(chat_id, 'No venues connected. Run discovery first.')
            return
          end

          lines = venues.sort_by { |_, v| -v }.map { |k, v| "  #{k}: #{v} symbols" }

          msg = <<~MSG
            Connected Venues

            Total symbols: #{symbols.size}

            #{lines.join("\n")}

            Last discovery: #{format_discovery_time}
          MSG

          send_message(chat_id, msg)
        end

        def cmd_pause(chat_id)
          @paused = true
          ArbitrageBot.redis.set('alerts:paused', '1')
          send_message(chat_id, 'Alerts PAUSED. Use /resume to continue.')
        end

        def cmd_resume(chat_id)
          @paused = false
          ArbitrageBot.redis.del('alerts:paused')
          send_message(chat_id, 'Alerts RESUMED.')
        end

        def cmd_stats(chat_id, args = [])
          strategy = args[0]

          # Use TradeTracker for comprehensive stats
          begin
            msg = Analytics::TradeTracker.format_stats_message(days: 30)
            send_message(chat_id, msg)
          rescue StandardError => e
            @logger.error("[TelegramBot] Stats error: #{e.message}")
            # Fallback to old stats if PostgreSQL not available
            fallback_stats(chat_id)
          end
        end

        def cmd_taken(chat_id, args)
          if args.empty?
            send_message(chat_id, "Usage: /taken <signal_id>\n\nExample: /taken abc12345")
            return
          end

          signal_id = args[0]
          user_id = chat_id

          result = Analytics::TradeTracker.take(signal_id, user_id)
          send_message(chat_id, result[:message])
        rescue StandardError => e
          @logger.error("[TelegramBot] Taken error: #{e.message}")
          send_message(chat_id, "Error: #{e.message}")
        end

        def cmd_result(chat_id, args)
          if args.size < 2
            send_message(chat_id, "Usage: /result <signal_id> <+/-X%> [notes]\n\nExamples:\n/result abc12345 +2.5%\n/result abc12345 -1.2% slippage")
            return
          end

          signal_id = args[0]
          pnl_str = args[1]
          notes = args[2..].join(' ') if args.size > 2
          user_id = chat_id

          result = Analytics::TradeTracker.record_result(signal_id, pnl_str, user_id, notes: notes)
          send_message(chat_id, result[:message])
        rescue StandardError => e
          @logger.error("[TelegramBot] Result error: #{e.message}")
          send_message(chat_id, "Error: #{e.message}")
        end

        def cmd_signals(chat_id, args)
          limit = (args[0] || 10).to_i.clamp(1, 50)

          signals = Analytics::SignalRepository.recent(limit: limit)

          if signals.empty?
            send_message(chat_id, "No signals found.\n\nSignals are created when alerts are sent.")
            return
          end

          lines = signals.map do |s|
            short_id = Analytics::SignalRepository.short_id(s[:id], s[:strategy])
            status_emoji = case s[:status]
                           when 'sent' then "\u23F3"
                           when 'taken' then "\u2705"
                           when 'closed' then "\u2714\uFE0F"
                           else "\u2753"
                           end
            time = Time.parse(s[:ts].to_s).strftime('%m/%d %H:%M')
            "#{status_emoji} `#{short_id}` #{s[:symbol]} (#{s[:strategy]})\n   #{time} | #{s[:status]}"
          end

          msg = "Recent Signals (#{signals.size}):\n\n#{lines.join("\n\n")}"
          send_message(chat_id, msg)
        rescue StandardError => e
          @logger.error("[TelegramBot] Signals error: #{e.message}")
          send_message(chat_id, "Error loading signals: #{e.message}")
        end

        def fallback_stats(chat_id)
          stats = load_alert_stats
          cooldown_stats = @cooldown.stats

          msg = <<~MSG
            Detailed Statistics (Redis only)

            Alerts:
              Total sent: #{stats[:alerts_sent] || 0}
              Blacklist blocked: #{stats[:blacklist_blocked] || 0}
              Cooldown blocked: #{cooldown_stats[:alerts_blocked_total] || 0}
              Safety failed: #{stats[:safety_failed] || 0}
              Send failed: #{stats[:send_failed] || 0}

            Cooldowns:
              Active: #{cooldown_stats[:active_count] || 0}
              Default: #{cooldown_stats[:default_cooldown_seconds]}s

            Blacklist:
              Symbols: #{@blacklist.stats[:symbols_count]}
              Addresses: #{@blacklist.stats[:addresses_count]}
              Exchanges: #{@blacklist.stats[:exchanges_count]}

            Queue:
              Pending signals: #{stats[:queue_size] || 0}
          MSG

          send_message(chat_id, msg)
        end

        def cmd_funding(chat_id, args)
          symbol = args[0]&.upcase

          # Get funding rate job from orchestrator or create ad-hoc
          funding_job = @orchestrator&.instance_variable_get(:@funding_job) ||
                        Jobs::FundingRateJob.new

          msg = funding_job.format_for_telegram(symbol)
          send_message(chat_id, msg)
        rescue StandardError => e
          @logger.error("[TelegramBot] Funding error: #{e.message}")
          send_message(chat_id, "Error loading funding rates: #{e.message}")
        end

        def cmd_zscores(chat_id)
          # Get zscore monitor job from orchestrator or create ad-hoc
          zscore_job = @orchestrator&.instance_variable_get(:@zscore_job) ||
                       Jobs::ZScoreMonitorJob.new

          msg = zscore_job.format_for_telegram
          send_message(chat_id, msg)
        rescue StandardError => e
          @logger.error("[TelegramBot] ZScores error: #{e.message}")
          send_message(chat_id, "Error loading z-scores: #{e.message}")
        end

        def cmd_stables(chat_id)
          # Get stablecoin monitor job from orchestrator or create ad-hoc
          stablecoin_job = @orchestrator&.instance_variable_get(:@stablecoin_job) ||
                           Jobs::StablecoinMonitorJob.new

          msg = stablecoin_job.format_for_telegram
          send_message(chat_id, msg)
        rescue StandardError => e
          @logger.error("[TelegramBot] Stables error: #{e.message}")
          send_message(chat_id, "Error loading stablecoin prices: #{e.message}")
        end

        def cmd_convergence(chat_id, args)
          # Parse days argument (default: 30)
          days = args.first&.to_i
          days = 30 if days.nil? || days <= 0 || days > 365

          tracker = Analytics::SpreadConvergenceTracker.new
          msg = tracker.format_stats_message(days: days)
          send_message(chat_id, msg)
        rescue StandardError => e
          @logger.error("[TelegramBot] Convergence error: #{e.message}")
          send_message(chat_id, "Error loading convergence stats: #{e.message}")
        end

        # === Helpers ===

        def check_callback_rate_limit(chat_id)
          @logger.debug("[TelegramBot] Entering check_callback_rate_limit for #{chat_id}")
          key = "#{CALLBACK_RATE_LIMIT_KEY}#{chat_id}"
          @logger.debug("[TelegramBot] Rate limit key: #{key}")

          # Allow 1 callback per second per user
          exists = ArbitrageBot.redis.exists?(key)
          @logger.debug("[TelegramBot] Key exists: #{exists}")
          return false if exists

          ArbitrageBot.redis.setex(key, 1, '1')
          @logger.debug("[TelegramBot] Rate limit key set")
          true
        rescue StandardError => e
          @logger.error("[TelegramBot] Rate limit check error in method: #{e.class}: #{e.message}")
          true # Allow on error
        end

        def send_message_with_keyboard(chat_id, text, reply_markup)
          uri = URI("https://api.telegram.org/bot#{@token}/sendMessage")

          http = Support::SslConfig.create_http(uri, timeout: 10)

          body = {
            chat_id: chat_id,
            text: text,
            reply_markup: reply_markup,
            disable_web_page_preview: true
          }

          @logger.info("[TelegramBot] Sending keyboard message to #{chat_id}")
          @logger.debug("[TelegramBot] Body: #{body.to_json}")

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Host'] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request['Content-Type'] = 'application/json'
          request.body = body.to_json

          response = http.request(request)
          result = JSON.parse(response.body)

          @logger.info("[TelegramBot] Keyboard send result: ok=#{result['ok']}, error=#{result['description']}")
          result
        rescue StandardError => e
          @logger.error("[TelegramBot] Send with keyboard failed: #{e.message}")
          @logger.error(e.backtrace.first(5).join("\n"))
          nil
        end

        def send_message(chat_id, text)
          uri = URI("https://api.telegram.org/bot#{@token}/sendMessage")

          http = Support::SslConfig.create_http(uri, timeout: 10)

          request = Net::HTTP::Post.new(uri.request_uri)
          # Set Host header when connected via IP
          request["Host"] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request.set_form_data(
            chat_id: chat_id,
            text: text,
            disable_web_page_preview: true
          )

          http.request(request)
        rescue StandardError => e
          @logger.error("[TelegramBot] Send failed: #{e.message}")
        end

        def http_get(uri)
          http = Support::SslConfig.create_http(uri, timeout: POLL_TIMEOUT + 5)

          request = Net::HTTP::Get.new(uri.request_uri)
          # Set Host header when connected via IP
          request["Host"] = http.original_host if http.respond_to?(:original_host) && http.original_host
          http.request(request)
        end

        def load_alert_stats
          stats = ArbitrageBot.redis.hgetall('alerts:stats')
          stats[:queue_size] = ArbitrageBot.redis.llen('signals:pending')
          stats.transform_keys(&:to_sym)
        rescue StandardError
          {}
        end

        def format_discovery_time
          ts = ArbitrageBot.redis.get('tickers:last_update')
          return 'Never' unless ts

          time = Time.at(ts.to_i)
          ago = Time.now - time
          "#{time.strftime('%Y-%m-%d %H:%M')} (#{format_duration(ago.to_i)} ago)"
        rescue StandardError
          'Unknown'
        end

        def format_duration(seconds)
          days = seconds / 86400
          hours = (seconds % 86400) / 3600
          mins = (seconds % 3600) / 60

          parts = []
          parts << "#{days}d" if days > 0
          parts << "#{hours}h" if hours > 0
          parts << "#{mins}m" if mins > 0
          parts.empty? ? '0m' : parts.join(' ')
        end

        def format_price(price)
          price = price.to_f
          if price < 0.0001
            format('%.8f', price)
          elsif price < 1
            format('%.6f', price)
          else
            format('%.4f', price)
          end
        end

        def log(message)
          @logger.info("[TelegramBot] #{message}")
          puts "[#{Time.now.strftime('%H:%M:%S')}] [Bot] #{message}"
        end
      end
    end
  end
end
