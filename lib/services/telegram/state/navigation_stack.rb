# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      module State
        # Redis-backed navigation stack for breadcrumb trail (back button)
        class NavigationStack
          REDIS_PREFIX = 'tg:nav:'
          MAX_DEPTH = 5
          STACK_TTL = 3600 # 1 hour

          attr_reader :user_id

          def initialize(user_id)
            @user_id = user_id.to_s
          end

          # Push current state onto stack before navigating away
          # @param state [Symbol, String] state being left
          # @param context [Hash] optional context to restore
          def push(state, context: {})
            entry = {
              state: state.to_s,
              context: context,
              ts: Time.now.to_i
            }.to_json

            redis.lpush(key, entry)
            redis.ltrim(key, 0, MAX_DEPTH - 1)
            redis.expire(key, STACK_TTL)
          end

          # Pop last state from stack (go back)
          # @return [Hash, nil] { state:, context:, ts: } or nil if empty
          def pop
            json = redis.lpop(key)
            return nil unless json

            data = JSON.parse(json, symbolize_names: true)
            data[:state] = data[:state].to_sym
            data
          rescue JSON::ParserError
            nil
          end

          # Peek at top of stack without removing
          # @return [Hash, nil] top entry or nil
          def peek
            json = redis.lindex(key, 0)
            return nil unless json

            data = JSON.parse(json, symbolize_names: true)
            data[:state] = data[:state].to_sym
            data
          rescue JSON::ParserError
            nil
          end

          # Get full breadcrumb trail (oldest first)
          # @return [Array<Hash>] array of { state:, context:, ts: }
          def breadcrumbs
            redis.lrange(key, 0, -1).map do |json|
              data = JSON.parse(json, symbolize_names: true)
              data[:state] = data[:state].to_sym
              data
            end.reverse
          rescue JSON::ParserError
            []
          end

          # Check if can go back
          # @return [Boolean]
          def can_go_back?
            redis.llen(key).positive?
          end

          # Get current depth
          # @return [Integer]
          def depth
            redis.llen(key)
          end

          # Clear navigation stack
          def clear
            redis.del(key)
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
