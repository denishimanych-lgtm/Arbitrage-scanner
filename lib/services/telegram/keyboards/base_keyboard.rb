# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Base class for all inline keyboards
        class BaseKeyboard
          attr_reader :user_id

          def initialize(user_id:)
            @user_id = user_id
          end

          # Build keyboard rows - override in subclasses
          # @return [Array<Array<Hash>>] array of button rows
          def build
            raise NotImplementedError, 'Subclass must implement #build'
          end

          # Convert to Telegram reply_markup format
          # @return [Hash] { inline_keyboard: [...] }
          def to_reply_markup
            { inline_keyboard: build }
          end

          protected

          # Create a button with callback data
          # @param text [String] button text
          # @param callback_data [String] callback data
          # @return [Hash] button object
          def button(text, callback_data)
            { text: text, callback_data: callback_data }
          end

          # Create a URL button
          # @param text [String] button text
          # @param url [String] URL to open
          # @return [Hash] button object
          def url_button(text, url)
            { text: text, url: url }
          end

          # Create a row of buttons
          # @param buttons [Array<Hash>] buttons for this row
          # @return [Array<Hash>] button row
          def row(*buttons)
            buttons.flatten
          end

          # Standard back button row
          # @return [Array<Hash>] row with back button
          def back_row
            row(button("⬅️ Back", CallbackData.encode(:nav, :back)))
          end

          # Back and close buttons row
          # @return [Array<Hash>]
          def back_close_row
            row(
              button("⬅️ Back", CallbackData.encode(:nav, :back)),
              button("❌ Close", CallbackData.encode(:nav, :close))
            )
          end

          # Refresh button
          # @param target [Symbol] target to refresh
          # @return [Hash] refresh button
          def refresh_button(target)
            button("🔄 Refresh", CallbackData.encode(:act, :refresh, target.to_s))
          end

          # Helper to get settings
          # @return [Hash] current settings
          def settings
            @settings ||= SettingsLoader.new.load
          end

          # Helper to get blacklist
          # @return [Alerts::Blacklist]
          def blacklist
            @blacklist ||= Alerts::Blacklist.new
          end

          # Helper to get Redis
          def redis
            ArbitrageBot.redis
          end

          # Check if alerts are paused
          # @return [Boolean]
          def alerts_paused?
            redis.exists?('alerts:paused')
          end
        end
      end
    end
  end
end
