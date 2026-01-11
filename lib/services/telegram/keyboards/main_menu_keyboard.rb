# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Main menu keyboard with primary navigation options
        class MainMenuKeyboard < BaseKeyboard
          def build
            [
              row(
                button("📊 Status", CallbackData.encode(:nav, :status)),
                button("📈 Top Spreads", CallbackData.encode(:nav, :top))
              ),
              row(
                button("⚙️ Settings", CallbackData.encode(:nav, :settings)),
                button("🚫 Blacklist", CallbackData.encode(:nav, :blacklist))
              ),
              row(pause_resume_button)
            ]
          end

          # Build text for main menu
          # @return [String]
          def self.build_text
            <<~MSG
              🤖 Arbitrage Scanner Bot

              Select an option below to navigate:

              📊 Status - System health and statistics
              📈 Top Spreads - Current best opportunities
              ⚙️ Settings - Configure thresholds
              🚫 Blacklist - Manage blocked symbols
            MSG
          end

          private

          def pause_resume_button
            if alerts_paused?
              button("▶️ Resume Alerts", CallbackData.encode(:act, :resume))
            else
              button("⏸️ Pause Alerts", CallbackData.encode(:act, :pause))
            end
          end
        end
      end
    end
  end
end
