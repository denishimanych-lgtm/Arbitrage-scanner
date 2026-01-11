# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module State
        # Redis-backed user state management for Telegram bot navigation
        class UserState
          REDIS_PREFIX = 'tg:user:'
          STATE_TTL = 3600 # 1 hour

          VALID_STATES = %i[
            idle
            main_menu
            settings
            settings_spread
            settings_cooldown
            settings_signals
            blacklist
            blacklist_symbols
            blacklist_exchanges
            blacklist_pairs
            blacklist_add_symbol
            blacklist_add_exchange
            blacklist_add_pair
            status
            top_spreads
            confirm_action
            awaiting_input
          ].freeze

          attr_reader :user_id

          def initialize(user_id)
            @user_id = user_id.to_s
          end

          # Get current state
          # @return [Symbol] current state
          def current_state
            (redis.hget(key, 'state') || 'idle').to_sym
          end

          # Set new state with optional context
          # @param new_state [Symbol] new state
          # @param context [Hash] optional context data
          def set_state(new_state, context: {})
            state_sym = new_state.to_sym
            unless VALID_STATES.include?(state_sym)
              ArbitrageBot.logger.warn("[UserState] Unknown state: #{new_state}, allowing anyway")
            end

            redis.multi do |tx|
              tx.hset(key, 'state', new_state.to_s)
              tx.hset(key, 'context', context.to_json) if context.any?
              tx.hset(key, 'updated_at', Time.now.to_i)
              tx.expire(key, STATE_TTL)
            end
          end

          # Get current context
          # @return [Hash] context data
          def context
            json = redis.hget(key, 'context')
            json ? JSON.parse(json, symbolize_names: true) : {}
          rescue JSON::ParserError
            {}
          end

          # Update context
          # @param ctx [Hash] new context data
          def set_context(ctx)
            redis.hset(key, 'context', ctx.to_json)
            redis.expire(key, STATE_TTL)
          end

          # Merge into existing context
          # @param data [Hash] data to merge
          def update_context(data)
            current = context
            set_context(current.merge(data))
          end

          # Get stored menu message ID
          # @return [Integer, nil] message ID
          def message_id
            redis.hget(key, 'message_id')&.to_i
          end

          # Store menu message ID for editing
          # @param id [Integer] message ID
          def set_message_id(id)
            redis.hset(key, 'message_id', id.to_s)
            redis.expire(key, STATE_TTL)
          end

          # Check if user is awaiting text input
          # @return [Boolean]
          def awaiting_input?
            current_state == :awaiting_input
          end

          # Set awaiting input state
          # @param input_type [Symbol] type of input expected (:symbol, :exchange, :pair)
          def await_input(input_type)
            set_state(:awaiting_input, context: { input_type: input_type })
          end

          # Get the type of input being awaited
          # @return [Symbol, nil]
          def awaiting_input_type
            context[:input_type]&.to_sym
          end

          # Clear user state
          def clear
            redis.del(key)
          end

          # Get all state data
          # @return [Hash]
          def to_h
            {
              user_id: @user_id,
              state: current_state,
              context: context,
              message_id: message_id,
              updated_at: redis.hget(key, 'updated_at')&.to_i
            }
          end

          private

          def redis
            ArbitrageBot.redis
          end

          def key
            "#{REDIS_PREFIX}#{@user_id}"
          end
        end
      end
    end
  end
end
