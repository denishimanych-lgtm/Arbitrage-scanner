# frozen_string_literal: true

require 'net/http'
require 'json'

module ArbitrageBot
  module Services
    module Telegram
      class Bot
        POLL_TIMEOUT = 30
        COMMANDS = %w[start help status top threshold cooldown blacklist venues pause resume].freeze

        attr_reader :token, :chat_id, :orchestrator

        def initialize(orchestrator: nil)
          @token = ENV['TELEGRAM_BOT_TOKEN']
          @chat_id = ENV['TELEGRAM_CHAT_ID']
          @orchestrator = orchestrator
          @logger = ArbitrageBot.logger
          @redis = ArbitrageBot.redis
          @running = false
          @offset = 0
          @paused = false

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

          while @running
            begin
              updates = get_updates
              updates.each { |update| handle_update(update) }
            rescue StandardError => e
              @logger.error("[TelegramBot] Error: #{e.message}")
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

        private

        def get_updates
          uri = URI("https://api.telegram.org/bot#{@token}/getUpdates")
          uri.query = URI.encode_www_form(
            offset: @offset,
            timeout: POLL_TIMEOUT,
            allowed_updates: ['message']
          )

          response = Net::HTTP.get_response(uri)
          result = JSON.parse(response.body)

          return [] unless result['ok']

          updates = result['result'] || []
          @offset = updates.last['update_id'] + 1 if updates.any?

          updates
        end

        def handle_update(update)
          message = update['message']
          return unless message

          chat_id = message['chat']['id']
          text = message['text']&.strip
          return unless text&.start_with?('/')

          # Check authorization
          unless authorized?(chat_id)
            send_message(chat_id, "Unauthorized. Your chat ID: #{chat_id}")
            return
          end

          # Parse command
          parts = text.split(' ')
          command = parts[0].delete_prefix('/').split('@').first
          args = parts[1..]

          # Handle command
          handle_command(chat_id, command, args)
        end

        def authorized?(chat_id)
          allowed = (@chat_id || '').split(',').map(&:strip)
          allowed.include?(chat_id.to_s)
        end

        def handle_command(chat_id, command, args)
          case command
          when 'start'
            cmd_start(chat_id)
          when 'help'
            cmd_help(chat_id)
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
            cmd_stats(chat_id)
          else
            send_message(chat_id, "Unknown command: /#{command}\nUse /help for available commands.")
          end
        end

        # === Commands ===

        def cmd_start(chat_id)
          send_message(chat_id, <<~MSG)
            Welcome to Arbitrage Scanner Bot!

            I monitor price spreads between DEX and Futures exchanges and send alerts when profitable opportunities appear.

            Use /help to see available commands.
            Use /status to check system status.
          MSG
        end

        def cmd_help(chat_id)
          send_message(chat_id, <<~MSG)
            Available Commands:

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
            /stats - Detailed statistics
          MSG
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
          spreads_json = @redis.get('spreads:latest')
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
          if new_threshold < 0.1 || new_threshold > 50
            send_message(chat_id, 'Threshold must be between 0.1 and 50')
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

            Last discovery: #{@redis.get('discovery:last_run') || 'Never'}
          MSG

          send_message(chat_id, msg)
        end

        def cmd_pause(chat_id)
          @paused = true
          @redis.set('alerts:paused', '1')
          send_message(chat_id, 'Alerts PAUSED. Use /resume to continue.')
        end

        def cmd_resume(chat_id)
          @paused = false
          @redis.del('alerts:paused')
          send_message(chat_id, 'Alerts RESUMED.')
        end

        def cmd_stats(chat_id)
          stats = load_alert_stats
          cooldown_stats = @cooldown.stats

          msg = <<~MSG
            Detailed Statistics

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

        # === Helpers ===

        def send_message(chat_id, text)
          uri = URI("https://api.telegram.org/bot#{@token}/sendMessage")

          Net::HTTP.post_form(uri, {
            chat_id: chat_id,
            text: text,
            disable_web_page_preview: true
          })
        rescue StandardError => e
          @logger.error("[TelegramBot] Send failed: #{e.message}")
        end

        def load_alert_stats
          stats = @redis.hgetall('alerts:stats')
          stats[:queue_size] = @redis.llen('signals:pending')
          stats.transform_keys(&:to_sym)
        rescue StandardError
          {}
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
