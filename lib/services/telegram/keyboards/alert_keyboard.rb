# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Keyboard for alert messages with position tracking button
        class AlertKeyboard < BaseKeyboard
          attr_reader :signal_id

          # @param signal_id [String] full signal UUID
          # @param user_id [Integer] Telegram user ID (optional for base class)
          def initialize(signal_id:, user_id: nil)
            super(user_id: user_id)
            @signal_id = signal_id
          end

          # Build keyboard with position tracking button
          # @return [Array<Array<Hash>>]
          def build
            short_id = @signal_id.to_s[0..7]
            callback = CallbackData.encode(:act, :enter_pos, short_id)

            [
              row(button('📈 Вступил в позицию', callback))
            ]
          end
        end
      end
    end
  end
end
