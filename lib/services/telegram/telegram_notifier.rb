# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module ArbitrageBot
  module Services
    module Telegram
      class TelegramNotifier
        API_BASE = 'https://api.telegram.org'
        MAX_MESSAGE_LENGTH = 4096
        RETRY_DELAYS = [1, 2, 5].freeze

        attr_reader :bot_token, :chat_id, :logger

        def initialize(bot_token: nil, chat_id: nil)
          @bot_token = bot_token || ENV['TELEGRAM_BOT_TOKEN']
          @chat_id = chat_id || ENV['TELEGRAM_CHAT_ID']
          @logger = ArbitrageBot.logger
          @rate_limiter = RateLimiter.new
        end

        # Send a message to Telegram
        # @param text [String] message text
        # @param parse_mode [String] 'HTML' or 'MarkdownV2' or nil
        # @param disable_preview [Boolean] disable link preview
        # @return [Hash, nil] response data or nil on failure
        def send_message(text, parse_mode: nil, disable_preview: true)
          return nil unless configured?

          # Truncate if too long
          text = truncate_message(text) if text.length > MAX_MESSAGE_LENGTH

          # Rate limit check
          unless @rate_limiter.allow?
            @logger.warn('[Telegram] Rate limited, skipping message')
            return nil
          end

          params = {
            chat_id: @chat_id,
            text: text,
            disable_web_page_preview: disable_preview
          }
          params[:parse_mode] = parse_mode if parse_mode

          make_request('sendMessage', params)
        end

        # Send an alert (formatted signal)
        # @param formatted_message [String] pre-formatted alert message
        # @param reply_markup [Hash, nil] optional inline keyboard
        # @return [Hash, nil] response data or nil on failure
        def send_alert(formatted_message, reply_markup: nil)
          if reply_markup
            send_message_with_keyboard(@chat_id, formatted_message, reply_markup)
          else
            send_message(formatted_message)
          end
        end

        # Send a message to a specific user (for close notifications)
        # @param user_id [Integer] Telegram user ID
        # @param text [String] message text
        # @param reply_markup [Hash, nil] optional inline keyboard
        # @return [Hash, nil] response data or nil on failure
        def send_to_user(user_id, text, reply_markup: nil)
          return nil unless @bot_token && !@bot_token.empty?

          if reply_markup
            send_message_with_keyboard(user_id, text, reply_markup)
          else
            params = {
              chat_id: user_id,
              text: truncate_message(text),
              disable_web_page_preview: true
            }
            make_request('sendMessage', params)
          end
        end

        # Send a photo with caption
        # @param photo_url [String] URL of the photo
        # @param caption [String] caption text
        # @return [Hash, nil] response data or nil on failure
        def send_photo(photo_url, caption: nil)
          return nil unless configured?

          params = {
            chat_id: @chat_id,
            photo: photo_url
          }
          params[:caption] = caption if caption

          make_request('sendPhoto', params)
        end

        # Edit an existing message
        # @param message_id [Integer] message ID to edit
        # @param text [String] new text
        # @return [Hash, nil] response data or nil on failure
        def edit_message(message_id, text, parse_mode: nil)
          return nil unless configured?

          params = {
            chat_id: @chat_id,
            message_id: message_id,
            text: truncate_message(text)
          }
          params[:parse_mode] = parse_mode if parse_mode

          make_request('editMessageText', params)
        end

        # Delete a message
        # @param message_id [Integer] message ID to delete
        # @return [Boolean] success
        def delete_message(message_id)
          return false unless configured?

          result = make_request('deleteMessage', {
                                  chat_id: @chat_id,
                                  message_id: message_id
                                })
          result&.dig('result') == true
        end

        # Get bot info to verify token
        # @return [Hash, nil] bot info or nil
        def get_me
          make_request('getMe', {})
        end

        # Check if bot is properly configured
        # @return [Boolean]
        def configured?
          @bot_token && !@bot_token.empty? && @chat_id && !@chat_id.to_s.empty?
        end

        # Verify bot token and chat access
        # @return [Boolean] true if bot can send to chat
        def verify_connection
          return false unless configured?

          # First verify token
          me = get_me
          return false unless me&.dig('result', 'id')

          # Try to get chat info
          chat = make_request('getChat', { chat_id: @chat_id })
          chat&.dig('result', 'id').to_s == @chat_id.to_s
        end

        # Send a message with inline keyboard
        # @param chat_id [String, Integer] chat ID
        # @param text [String] message text
        # @param reply_markup [Hash] keyboard markup
        # @param parse_mode [String, nil] 'HTML' or 'MarkdownV2'
        # @return [Hash, nil] response data or nil
        def send_message_with_keyboard(chat_id, text, reply_markup, parse_mode: nil)
          return nil unless configured?

          params = {
            chat_id: chat_id,
            text: truncate_message(text),
            reply_markup: reply_markup.to_json,
            disable_web_page_preview: true
          }
          params[:parse_mode] = parse_mode if parse_mode

          make_request('sendMessage', params)
        end

        # Edit message text with optional keyboard update
        # @param chat_id [String, Integer] chat ID
        # @param message_id [Integer] message ID to edit
        # @param text [String] new text
        # @param reply_markup [Hash, nil] new keyboard markup
        # @param parse_mode [String, nil] 'HTML' or 'MarkdownV2'
        # @return [Hash, nil] response data or nil
        def edit_message_with_keyboard(chat_id, message_id, text, reply_markup: nil, parse_mode: nil)
          return nil unless configured?

          params = {
            chat_id: chat_id,
            message_id: message_id,
            text: truncate_message(text)
          }
          params[:reply_markup] = reply_markup.to_json if reply_markup
          params[:parse_mode] = parse_mode if parse_mode

          make_request('editMessageText', params)
        end

        # Answer a callback query (acknowledge button press)
        # @param callback_query_id [String] callback query ID
        # @param text [String, nil] optional toast text
        # @param show_alert [Boolean] show as alert popup
        # @return [Hash, nil] response data or nil
        def answer_callback_query(callback_query_id, text: nil, show_alert: false)
          params = { callback_query_id: callback_query_id }
          params[:text] = text if text
          params[:show_alert] = show_alert if show_alert

          make_request('answerCallbackQuery', params)
        end

        # Edit only the reply markup (keyboard) of a message
        # @param chat_id [String, Integer] chat ID
        # @param message_id [Integer] message ID
        # @param reply_markup [Hash] new keyboard markup
        # @return [Hash, nil] response data or nil
        def edit_message_reply_markup(chat_id, message_id, reply_markup)
          make_request('editMessageReplyMarkup', {
            chat_id: chat_id,
            message_id: message_id,
            reply_markup: reply_markup.to_json
          })
        end

        private

        def make_request(method, params, retry_count: 0)
          uri = URI("#{API_BASE}/bot#{@bot_token}/#{method}")

          http = Support::SslConfig.create_http(uri, timeout: 30)

          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          # Set Host header when connected via IP
          request['Host'] = http.original_host if http.respond_to?(:original_host) && http.original_host
          request.body = params.to_json

          response = http.request(request)
          result = JSON.parse(response.body)

          if result['ok']
            @logger.debug("[Telegram] #{method} success")
            result
          else
            handle_error(method, result, params, retry_count)
          end
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          @logger.error("[Telegram] Timeout: #{e.message}")
          retry_request(method, params, retry_count)
        rescue StandardError => e
          @logger.error("[Telegram] Error: #{e.message}")
          nil
        end

        def handle_error(method, result, params, retry_count)
          error_code = result['error_code']
          description = result['description']

          @logger.error("[Telegram] #{method} failed: #{error_code} - #{description}")

          # Handle rate limiting
          if error_code == 429
            retry_after = result.dig('parameters', 'retry_after') || 30
            @logger.warn("[Telegram] Rate limited, retry after #{retry_after}s")
            @rate_limiter.throttle(retry_after)
            return nil
          end

          # Handle temporary errors with retry
          if [500, 502, 503, 504].include?(error_code)
            return retry_request(method, params, retry_count)
          end

          nil
        end

        def retry_request(method, params, retry_count)
          return nil if retry_count >= RETRY_DELAYS.length

          delay = RETRY_DELAYS[retry_count]
          @logger.info("[Telegram] Retrying #{method} in #{delay}s (attempt #{retry_count + 1})")
          sleep(delay)

          make_request(method, params, retry_count: retry_count + 1)
        end

        def truncate_message(text)
          return text if text.length <= MAX_MESSAGE_LENGTH

          truncated = text[0, MAX_MESSAGE_LENGTH - 50]
          truncated + "\n\n... [truncated]"
        end

        # Simple rate limiter for Telegram API
        class RateLimiter
          MAX_MESSAGES_PER_SECOND = 1
          MAX_MESSAGES_PER_MINUTE = 20

          def initialize
            @second_bucket = []
            @minute_bucket = []
            @throttle_until = nil
          end

          def allow?
            now = Time.now

            # Check if throttled
            return false if @throttle_until && now < @throttle_until

            # Clean old entries
            @second_bucket.reject! { |t| now - t > 1 }
            @minute_bucket.reject! { |t| now - t > 60 }

            # Check limits
            return false if @second_bucket.size >= MAX_MESSAGES_PER_SECOND
            return false if @minute_bucket.size >= MAX_MESSAGES_PER_MINUTE

            # Record this request
            @second_bucket << now
            @minute_bucket << now

            true
          end

          def throttle(seconds)
            @throttle_until = Time.now + seconds
          end
        end
      end
    end
  end
end
