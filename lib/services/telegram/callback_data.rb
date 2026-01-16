# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Telegram
      # Encodes and decodes callback data for inline keyboard buttons
      # Format: action:target:param1:param2...
      # Max Telegram callback_data length: 64 bytes
      class CallbackData
        SEPARATOR = ':'

        # Actions (short codes)
        ACTIONS = {
          nav: 'n',      # Navigation
          set: 's',      # Settings
          tgl: 't',      # Toggle
          bl: 'b',       # Blacklist
          pg: 'g',       # Pagination
          act: 'a'       # Action (confirm/execute)
        }.freeze

        # Targets (short codes)
        TARGETS = {
          main: 'mn',
          back: 'bk',
          close: 'cl',
          settings: 'st',
          spread: 'sp',
          cooldown: 'cd',
          signals: 'sg',
          blacklist: 'bl',
          symbols: 'sy',
          exchanges: 'ex',
          pairs: 'pr',
          status: 'ss',
          top: 'tp',
          pause: 'ps',
          resume: 'rs',
          refresh: 'rf',
          confirm: 'cf',
          cancel: 'cn',
          add: 'ad',
          remove: 'rm',
          auto: 'au',
          manual: 'ma',
          lagging: 'lg',
          noop: 'no',
          # New settings targets
          minliq: 'ml',
          exitliq: 'el',
          voldex: 'vd',
          volfut: 'vf',
          minpos: 'mp',
          maxpos: 'xp',
          sugpos: 'gp',
          slip: 'sl',
          latency: 'lt',
          ratio: 'rt',
          bidask: 'ba',
          # Position tracking
          enter_pos: 'ep',
          close_pos: 'cp',
          positions: 'po',
          posclose: 'pc'
        }.freeze

        # Reverse mappings for decoding
        ACTIONS_REV = ACTIONS.invert.freeze
        TARGETS_REV = TARGETS.invert.freeze

        class << self
          # Encode action, target, and optional params into callback data string
          # @param action [Symbol] action type (:nav, :set, :tgl, :bl, :pg, :act)
          # @param target [Symbol] target identifier
          # @param params [Array] optional parameters
          # @return [String] encoded callback data
          def encode(action, target, *params)
            parts = [
              ACTIONS[action] || action.to_s,
              TARGETS[target] || target.to_s
            ]
            parts += params.map(&:to_s) if params.any?

            result = parts.join(SEPARATOR)

            # Ensure we don't exceed Telegram's limit
            if result.bytesize > 64
              raise ArgumentError, "Callback data exceeds 64 bytes: #{result.bytesize}"
            end

            result
          end

          # Decode callback data string back to structured data
          # @param data [String] callback data from Telegram
          # @return [Hash] { action:, target:, params: [] }
          def decode(data)
            return { action: :noop, target: :noop, params: [] } if data.nil? || data.empty?

            parts = data.split(SEPARATOR)

            action_code = parts[0]
            target_code = parts[1]
            params = parts[2..] || []

            {
              action: ACTIONS_REV[action_code] || action_code.to_sym,
              target: TARGETS_REV[target_code] || target_code.to_sym,
              params: params
            }
          end

          # Check if callback data is a noop (no operation)
          # @param data [String] callback data
          # @return [Boolean]
          def noop?(data)
            data == encode(:act, :noop) || data == 'noop'
          end
        end
      end
    end
  end
end
