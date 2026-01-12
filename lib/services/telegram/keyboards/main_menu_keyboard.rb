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
                button("💰 Funding", CallbackData.encode(:nav, :funding)),
                button("📊 Z-Score", CallbackData.encode(:nav, :zscores)),
                button("💵 Stables", CallbackData.encode(:nav, :stables))
              ),
              row(
                button("📈 Stats", CallbackData.encode(:nav, :stats)),
                button("⚙️ Settings", CallbackData.encode(:nav, :settings))
              ),
              row(
                button("🚫 Blacklist", CallbackData.encode(:nav, :blacklist)),
                pause_resume_button
              )
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
              💰 Funding - Current funding rates
              📊 Z-Score - Statistical arbitrage monitor
              💵 Stables - Stablecoin depeg monitor
              📈 Stats - Trading statistics
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
