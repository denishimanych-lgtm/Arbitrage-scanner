# frozen_string_literal: true

module ArbitrageBot
  module Services
    module ZScore
      # Generates alerts for z-score deviations
      class ZScoreAlerter
        COOLDOWN_KEY = 'zscore:alert_cooldown:'
        DEFAULT_COOLDOWN_SECONDS = 3600  # 1 hour between alerts for same pair

        def initialize(settings = {})
          @logger = ArbitrageBot.logger
          @notifier = Telegram::TelegramNotifier.new
          @cooldown_seconds = settings[:zscore_alert_cooldown] || DEFAULT_COOLDOWN_SECONDS
        end

        # Check z-scores and generate alerts
        # @param zscores [Array<Hash>] z-score data from ZScoreTracker
        # @return [Array<Hash>] generated alerts
        def check_and_alert(zscores)
          alerts = []

          zscores.each do |zscore_data|
            next unless should_alert?(zscore_data)
            next if on_cooldown?(zscore_data[:pair])

            alert = create_alert(zscore_data)
            if alert && send_alert(alert)
              alerts << alert
              set_cooldown(zscore_data[:pair])
            end
          end

          alerts
        end

        # Format z-scores for /zscores command
        # @param zscores [Array<Hash>]
        # @return [String]
        def format_zscores_message(zscores)
          if zscores.empty?
            return "No z-score data available. Waiting for price data collection."
          end

          lines = [
            "📊 Z-SCORE MONITOR",
            "━" * 30,
            ""
          ]

          # Sort by absolute z-score descending
          sorted = zscores.sort_by { |z| -(z[:zscore]&.abs || 0) }

          sorted.each do |z|
            if z[:zscore]
              emoji = status_emoji(z[:status])
              zscore_str = format_zscore(z[:zscore])
              lines << "#{emoji} #{z[:pair]}: Z = #{zscore_str}"
              lines << "   Ratio: #{z[:ratio].round(4)} | μ: #{z[:mean]&.round(4)} | σ: #{z[:std]&.round(4)}"
            else
              lines << "⏳ #{z[:pair]}: Collecting data (#{z[:count]}/#{z[:required]})"
            end
            lines << ""
          end

          thresholds = PairsConfig.thresholds
          lines << "Thresholds: Entry |z|>#{thresholds[:entry]} | Stop |z|>#{thresholds[:stop]}"
          lines << "Updated: #{Time.now.strftime('%H:%M:%S')}"

          lines.join("\n")
        end

        private

        def should_alert?(zscore_data)
          return false unless zscore_data[:zscore]
          return false if zscore_data[:status] == :insufficient_data

          zscore_data[:status] == :entry_signal || zscore_data[:status] == :stop_loss
        end

        def on_cooldown?(pair_str)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{pair_str}"
          redis.exists?(key)
        rescue StandardError
          false
        end

        def set_cooldown(pair_str)
          redis = ArbitrageBot.redis
          key = "#{COOLDOWN_KEY}#{pair_str}"
          redis.setex(key, @cooldown_seconds, '1')
        rescue StandardError => e
          @logger.error("[ZScoreAlerter] set_cooldown error: #{e.message}")
        end

        def create_alert(zscore_data)
          pair = zscore_data[:pair]
          base, quote = pair.split('/')
          zscore = zscore_data[:zscore]
          is_stop = zscore_data[:status] == :stop_loss

          # Determine direction
          if zscore > 0
            # Ratio above mean - base overvalued relative to quote
            action = "SHORT #{base} / LONG #{quote}"
            direction = "↑ HIGH"
          else
            # Ratio below mean - base undervalued relative to quote
            action = "LONG #{base} / SHORT #{quote}"
            direction = "↓ LOW"
          end

          emoji = is_stop ? "🚨" : "📊"
          alert_type = is_stop ? "STOP LOSS" : "STAT ARB"

          message = <<~MSG
            #{emoji} #{alert_type} | #{pair} | Z = #{format_zscore(zscore)}
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            📈 RATIO: #{zscore_data[:ratio].round(6)} #{direction}
               Mean: #{zscore_data[:mean].round(6)}
               Std: #{zscore_data[:std].round(6)}

            💡 СТРАТЕГИЯ:
               #{action}
               (Mean reversion trade)

            ⚠️ КЛАСС: Speculative (regime change risk)
               #{is_stop ? '🛑 STOP REACHED - Consider closing' : '✅ Entry signal'}

            📍 ВЫХОД:
               • |Z| < #{PairsConfig.thresholds[:exit]} (mean reversion)
               • Stop: |Z| > #{PairsConfig.thresholds[:stop]}
          MSG

          {
            type: is_stop ? :zscore_stop : :zscore_entry,
            pair: pair,
            zscore: zscore,
            ratio: zscore_data[:ratio],
            mean: zscore_data[:mean],
            std: zscore_data[:std],
            direction: zscore > 0 ? :short_base : :long_base,
            message: message.strip
          }
        end

        def send_alert(alert)
          # Create signal in database
          db_signal = Analytics::SignalRepository.create(
            strategy: 'zscore',
            class: 'speculative',
            symbol: alert[:pair],
            details: alert.except(:message)
          )

          signal_id = db_signal ? Analytics::SignalRepository.short_id(db_signal[:id], 'zscore') : nil
          message = alert[:message]
          message = "#{message}\n\nID: `#{signal_id}`\n/taken #{signal_id}" if signal_id

          result = @notifier.send_alert(message)

          if result && db_signal && result.is_a?(Hash) && result['result']
            msg_id = result.dig('result', 'message_id')
            Analytics::SignalRepository.update_telegram_msg_id(db_signal[:id], msg_id) if msg_id
          end

          result
        rescue StandardError => e
          @logger.error("[ZScoreAlerter] send_alert error: #{e.message}")
          nil
        end

        def format_zscore(zscore)
          sign = zscore >= 0 ? '+' : ''
          "#{sign}#{zscore.round(2)}"
        end

        def status_emoji(status)
          case status
          when :stop_loss then "🚨"
          when :entry_signal then "📊"
          when :exit_zone then "✅"
          else "📈"
          end
        end
      end
    end
  end
end
