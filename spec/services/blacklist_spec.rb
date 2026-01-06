# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArbitrageBot::Services::Alerts::Blacklist do
  let(:blacklist) { described_class.new }

  describe 'symbol blacklist' do
    it 'adds and checks symbols' do
      expect(blacklist.symbol_blacklisted?('BTC')).to be false

      blacklist.add_symbol('BTC')
      expect(blacklist.symbol_blacklisted?('BTC')).to be true
      expect(blacklist.symbol_blacklisted?('btc')).to be true # case insensitive
    end

    it 'removes symbols' do
      blacklist.add_symbol('ETH')
      blacklist.remove_symbol('ETH')

      expect(blacklist.symbol_blacklisted?('ETH')).to be false
    end

    it 'lists all symbols' do
      blacklist.add_symbol('BTC')
      blacklist.add_symbol('ETH')

      expect(blacklist.symbols).to contain_exactly('BTC', 'ETH')
    end
  end

  describe 'address blacklist' do
    it 'adds and checks addresses' do
      address = '0x1234567890abcdef'

      blacklist.add_address(address)
      expect(blacklist.address_blacklisted?(address)).to be true
      expect(blacklist.address_blacklisted?(address.upcase)).to be true
    end
  end

  describe 'exchange blacklist' do
    it 'adds and checks exchanges' do
      blacklist.add_exchange('mexc')

      expect(blacklist.exchange_blacklisted?('mexc')).to be true
      expect(blacklist.exchange_blacklisted?('MEXC')).to be true
      expect(blacklist.exchange_blacklisted?('binance')).to be false
    end
  end

  describe '#blocked?' do
    let(:signal) { build_test_signal }

    it 'returns false for clean signal' do
      expect(blacklist.blocked?(signal)).to be false
    end

    it 'returns true if symbol is blacklisted' do
      blacklist.add_symbol('BTC')
      expect(blacklist.blocked?(signal)).to be true
    end

    it 'returns true if exchange is blacklisted' do
      blacklist.add_exchange('binance')
      expect(blacklist.blocked?(signal)).to be true
    end

    it 'returns true if address is blacklisted' do
      blacklist.add_address('test_address')
      expect(blacklist.blocked?(signal)).to be true
    end
  end

  describe '#stats' do
    it 'returns counts' do
      blacklist.add_symbol('BTC')
      blacklist.add_symbol('ETH')
      blacklist.add_exchange('mexc')

      stats = blacklist.stats
      expect(stats[:symbols_count]).to eq(2)
      expect(stats[:exchanges_count]).to eq(1)
    end
  end
end
