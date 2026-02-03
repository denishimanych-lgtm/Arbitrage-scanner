# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module Keyboards
        # Keyboard for compact alerts with Mini App button
        class CompactAlertKeyboard < BaseKeyboard
          WEBAPP_URL = ENV.fetch('WEBAPP_URL', 'http://localhost:5173')

          attr_reader :symbol, :signal_id

          def initialize(user_id: nil, symbol:, signal_id: nil)
            super(user_id: user_id || 0)
            @symbol = symbol
            @signal_id = signal_id
          end

          def build
            rows = []

            # WebApp button to see full details
            if webapp_available?
              rows << row(webapp_button("📊 Подробнее", mini_app_url))
            end

            # Position tracking button
            if @signal_id
              rows << row(
                button("📈 Вошёл в позицию", enter_position_callback),
                button("🔕 Скрыть", hide_callback)
              )
            else
              rows << row(
                button("👁 Отслеживать", track_callback),
                button("🔕 Скрыть", hide_callback)
              )
            end

            rows
          end

          # Build without requiring user_id (for direct hash creation)
          def self.build_for(symbol:, signal_id: nil)
            new(symbol: symbol, signal_id: signal_id).to_reply_markup
          end

          private

          def mini_app_url
            "#{WEBAPP_URL}?startapp=symbol_#{@symbol}"
          end

          def webapp_available?
            url = WEBAPP_URL
            url && !url.empty? && url != 'http://localhost:5173'
          end

          def enter_position_callback
            CallbackData.encode(:act, :enter_pos, @signal_id || @symbol)
          end

          def track_callback
            CallbackData.encode(:act, :track_symbol, @symbol)
          end

          def hide_callback
            CallbackData.encode(:act, :hide_alert, @symbol)
          end
        end
      end
    end
  end
end
