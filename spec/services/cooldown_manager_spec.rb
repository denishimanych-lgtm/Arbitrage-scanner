# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArbitrageBot::Services::Alerts::CooldownManager do
  let(:manager) { described_class.new(default_cooldown: 5) }

  describe '#can_alert?' do
    it 'allows first alert' do
      expect(manager.can_alert?('BTC')).to be true
    end

    it 'blocks during cooldown' do
      manager.set_cooldown('BTC')

      expect(manager.can_alert?('BTC')).to be false
    end

    it 'allows after cooldown expires' do
      manager.set_cooldown('BTC', seconds: 1)
      sleep 1.1

      expect(manager.can_alert?('BTC')).to be true
    end

    it 'allows different symbols' do
      manager.set_cooldown('BTC')

      expect(manager.can_alert?('ETH')).to be true
    end
  end

  describe '#remaining_cooldown' do
    it 'returns 0 when not on cooldown' do
      expect(manager.remaining_cooldown('BTC')).to eq(0)
    end

    it 'returns remaining seconds during cooldown' do
      manager.set_cooldown('BTC', seconds: 10)

      remaining = manager.remaining_cooldown('BTC')
      expect(remaining).to be_between(8, 10)
    end
  end

  describe '#process_alert' do
    it 'returns true and sets cooldown for first alert' do
      result = manager.process_alert('BTC')

      expect(result).to be true
      expect(manager.can_alert?('BTC')).to be false
    end

    it 'returns false during cooldown' do
      manager.set_cooldown('BTC')

      result = manager.process_alert('BTC')
      expect(result).to be false
    end
  end

  describe '#clear_cooldown' do
    it 'removes cooldown' do
      manager.set_cooldown('BTC')
      manager.clear_cooldown('BTC')

      expect(manager.can_alert?('BTC')).to be true
    end
  end

  describe '#active_cooldowns' do
    it 'lists active cooldowns' do
      manager.set_cooldown('BTC', seconds: 60)
      manager.set_cooldown('ETH', seconds: 60)

      cooldowns = manager.active_cooldowns
      expect(cooldowns.map { |c| c[:symbol] }).to contain_exactly('BTC', 'ETH')
    end
  end
end
