# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # System status keyboard
        class StatusKeyboard < BaseKeyboard
          def build
            [
              row(
                button("🔄 Refresh", CallbackData.encode(:act, :refresh, 'ss')),
                button("⬅️ Back", CallbackData.encode(:nav, :back))
              )
            ]
          end

          # Build status text
          # @param orchestrator [Orchestrator, nil] orchestrator instance
          # @return [String]
          def self.build_text(orchestrator = nil)
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: entering")
            status = orchestrator&.status || {}
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: got status")
            uptime = format_duration(status[:uptime] || 0)
            threads = status[:threads] || {}
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: formatted uptime")

            # Load additional stats from Redis
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: getting redis")
            redis = ArbitrageBot.redis
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: loading alert_stats")
            alert_stats = load_alert_stats(redis)
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: loading cooldown_stats")
            cooldown_stats = load_cooldown_stats(redis)
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: loading settings")
            settings = SettingsLoader.new.load
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: settings loaded")

            # Check Redis connection directly
            redis_ok = begin
              redis.ping == 'PONG'
            rescue StandardError
              false
            end
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: redis_ok=#{redis_ok}")

            paused = redis.exists?('alerts:paused') rescue false
            ArbitrageBot.logger.debug("[StatusKeyboard] build_text: paused=#{paused}")

            thread_status = threads.map do |name, state|
              emoji = state == 'alive' ? '✅' : '❌'
              "  #{emoji} #{name}: #{state}"
            end.join("\n")

            <<~MSG
              📊 System Status

              ⏱ Uptime: #{uptime}
              🟢 Redis: #{redis_ok ? 'Connected' : 'Disconnected'}
              🔔 Alerts: #{paused ? 'PAUSED' : 'Active'}

              Workers:
              #{thread_status.empty? ? '  No workers' : thread_status}

              Settings:
                Min spread: #{settings[:min_spread_pct]}%
                Cooldown: #{settings[:alert_cooldown_seconds]}s

              Alerts (24h):
                Sent: #{alert_stats[:alerts_sent] || 0}
                Blocked: #{alert_stats[:cooldown_blocked] || 0}
                Queue: #{alert_stats[:queue_size] || 0}

              Active Cooldowns: #{cooldown_stats[:active_count] || 0}

              Updated: #{Time.now.strftime('%H:%M:%S')}
            MSG
          end

          def self.format_duration(seconds)
            return '0m' if seconds.nil? || seconds <= 0

            days = seconds / 86_400
            hours = (seconds % 86_400) / 3600
            mins = (seconds % 3600) / 60

            parts = []
            parts << "#{days}d" if days.positive?
            parts << "#{hours}h" if hours.positive?
            parts << "#{mins}m" if mins.positive?
            parts.empty? ? '< 1m' : parts.join(' ')
          end

          def self.load_alert_stats(redis)
            stats = redis.hgetall('alerts:stats')
            stats[:queue_size] = redis.llen('signals:pending')
            stats.transform_keys(&:to_sym)
          rescue StandardError
            {}
          end

          def self.load_cooldown_stats(redis)
            # Count active cooldowns by pattern
            keys = redis.keys('alert:cooldown:*')
            # Filter out stats key
            active_keys = keys.reject { |k| k.include?(':stats') }

            { active_count: active_keys.size }
          rescue StandardError
            { active_count: 0 }
          end
        end
      end
    end
  end
end
