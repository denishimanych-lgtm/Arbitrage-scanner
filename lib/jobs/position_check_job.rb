# frozen_string_literal: true

module ArbitrageBot
  module Jobs
    # Monitors tracked positions and sends close notifications
    # when spread narrows to target threshold
    class PositionCheckJob
      LOOP_INTERVAL = 30 # Check every 30 seconds
      SPREAD_CACHE_KEY = 'spreads:latest'

      def initialize
        @logger = ArbitrageBot.logger
        @redis = ArbitrageBot.redis
        @tracker = Services::Trackers::PositionTracker.new
        @notifier = Services::Telegram::TelegramNotifier.new
        @settings_loader = Services::SettingsLoader.new
      end

      # Run continuous monitoring loop
      def run_loop
        log('Starting position check job loop')

        loop do
          begin
            check_all_positions
          rescue StandardError => e
            @logger.error("[PositionCheckJob] Loop error: #{e.message}")
          end

          sleep LOOP_INTERVAL
        end
      end

      # Check all active positions
      def check_all_positions
        active = @tracker.active_positions
        return if active.empty?

        log("Checking #{active.size} active positions")

        # Load current spreads
        spreads = load_current_spreads

        active.each do |pos|
          check_position(pos, spreads)
        end
      end

      private

      def log(message)
        @logger.info("[PositionCheckJob] #{message}")
      end

      # Load current spreads from Redis cache
      # @return [Hash] indexed spreads and raw array
      def load_current_spreads
        data = @redis.get(SPREAD_CACHE_KEY)
        return {} unless data

        @raw_spreads = JSON.parse(data)

        # Index by pair_id + symbol for quick lookup
        indexed = {}
        @raw_spreads.each do |s|
          pair_id = s['pair_id'] || s[:pair_id]
          symbol = s['symbol'] || s[:symbol]
          key = "#{pair_id}:#{symbol}"
          indexed[key] = s
        end
        indexed
      rescue StandardError => e
        @logger.error("[PositionCheckJob] load_current_spreads error: #{e.message}")
        @raw_spreads = []
        {}
      end

      # Get all spreads for a symbol across all pairs
      # @param symbol [String] ticker symbol
      # @return [Array<Hash>] spreads sorted by spread_pct desc
      def spreads_for_symbol(symbol)
        return [] unless @raw_spreads

        @raw_spreads
          .select { |s| (s['symbol'] || s[:symbol]) == symbol }
          .sort_by { |s| -(s['spread_pct'] || s[:spread_pct]).to_f.abs }
      end

      # Check a single position
      def check_position(pos, spreads)
        key = "#{pos[:pair_id]}:#{pos[:symbol]}"
        spread_data = spreads[key]

        unless spread_data
          @logger.debug("[PositionCheckJob] No spread data for #{key}")
          return
        end

        current_spread = (spread_data['spread_pct'] || spread_data[:spread_pct]).to_f.abs
        target_spread = pos[:target_spread_pct].to_f

        # Update current spread in DB
        @tracker.update_spread(pos[:id], current_spread)

        # Check if target reached
        if current_spread <= target_spread
          send_close_notification(pos, current_spread)
          @tracker.mark_notified(pos[:id])
        end
      end

      # Send close notification to user
      def send_close_notification(pos, current_spread)
        entry_spread = pos[:entry_spread_pct].to_f
        reduction_pct = ((entry_spread - current_spread) / entry_spread * 100).round(0)
        time_in_position = format_duration(pos[:entered_at])

        # Get all spreads for this symbol
        all_spreads = spreads_for_symbol(pos[:symbol])

        message = build_close_message(pos, current_spread, entry_spread, reduction_pct, time_in_position, all_spreads)

        # Build keyboard with close button
        keyboard = build_close_keyboard(pos[:id])

        @notifier.send_to_user(pos[:user_id], message, reply_markup: keyboard)

        log("Sent close notification to user #{pos[:user_id]} for #{pos[:symbol]}")
      end

      # Build the close notification message
      def build_close_message(pos, current_spread, entry_spread, reduction_pct, duration, all_spreads)
        pair_display = format_pair_display(pos[:pair_id])

        lines = []
        lines << "🎯 ПОРА ЗАКРЫВАТЬ | #{pos[:symbol]}"
        lines << "━━━━━━━━━━━━━━━━━━━━━━━━━"
        lines << ""
        lines << "📍 Ваша пара: #{pair_display}"
        lines << ""
        lines << "📊 СПРЕД ПОЗИЦИИ:"
        lines << "   Вход: #{entry_spread.round(2)}%"
        lines << "   Сейчас: #{current_spread.round(2)}%"
        lines << "   Сужение: -#{reduction_pct}%"
        lines << ""
        lines << "⏰ В позиции: #{duration}"

        # Add all spreads for this symbol
        if all_spreads.any?
          lines << ""
          lines << "━━━━━━━━━━━━━━━━━━━━━━━━━"
          lines << "📈 ВСЕ ПАРЫ #{pos[:symbol]} (#{all_spreads.size}):"
          lines << ""

          all_spreads.first(10).each do |s|
            pair_id = s['pair_id'] || s[:pair_id]
            spread = (s['spread_pct'] || s[:spread_pct]).to_f.round(1)
            pair_name = format_pair_display(pair_id)

            # Mark the position's pair
            marker = pair_id == pos[:pair_id] ? ' ← ваша' : ''
            lines << "   • #{pair_name}: #{spread}%#{marker}"
          end

          if all_spreads.size > 10
            lines << "   ... и ещё #{all_spreads.size - 10} пар"
          end
        end

        lines << ""
        lines << "━━━━━━━━━━━━━━━━━━━━━━━━━"
        lines << "💡 Рекомендация: Закрыть обе ноги"
        lines << ""
        lines << "🤖 Position ID: #{pos[:id][0..7]}"

        lines.join("\n")
      end

      # Build inline keyboard for close notification
      def build_close_keyboard(position_id)
        short_id = position_id.to_s[0..7]
        callback_data = Services::Telegram::CallbackData.encode(:act, :close_pos, short_id)

        {
          inline_keyboard: [
            [{ text: '✅ Закрыл позицию', callback_data: callback_data }]
          ]
        }
      end

      # Format pair_id for display
      def format_pair_display(pair_id)
        return pair_id unless pair_id.include?(':')

        parts = pair_id.split(':')
        return pair_id if parts.size != 2

        low = format_venue_short(parts[0])
        high = format_venue_short(parts[1])

        "#{low}↔#{high}"
      end

      def format_venue_short(venue_key)
        exchange = venue_key.gsub(/_spot$|_futures$|_perp$|_dex$/, '').capitalize
        suffix = if venue_key.end_with?('_futures')
                   '-Fut'
                 elsif venue_key.end_with?('_spot')
                   '-Spot'
                 elsif venue_key.end_with?('_perp')
                   '-Perp'
                 else
                   '-DEX'
                 end

        "#{exchange}#{suffix}"
      end

      # Format duration since entered_at
      def format_duration(entered_at)
        return '?' unless entered_at

        entered = entered_at.is_a?(Time) ? entered_at : Time.parse(entered_at.to_s)
        seconds = (Time.now - entered).to_i

        if seconds < 60
          "#{seconds} сек"
        elsif seconds < 3600
          "#{(seconds / 60).round(0)} мин"
        elsif seconds < 86_400
          hours = (seconds / 3600).floor
          mins = ((seconds % 3600) / 60).round(0)
          mins > 0 ? "#{hours}ч #{mins}м" : "#{hours}ч"
        else
          days = (seconds / 86_400).round(1)
          "#{days}д"
        end
      rescue StandardError
        '?'
      end
    end
  end
end
