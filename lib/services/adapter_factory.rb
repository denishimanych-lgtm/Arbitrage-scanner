# frozen_string_literal: true

module ArbitrageBot
  module Services
    module AdapterFactory
      # CEX Adapter Factory
      module Cex
        ADAPTERS = {
          'binance' => -> { Adapters::Cex::BinanceAdapter.new },
          'bybit' => -> { Adapters::Cex::BybitAdapter.new },
          'okx' => -> { Adapters::Cex::OkxAdapter.new },
          'gate' => -> { Adapters::Cex::GateAdapter.new },
          'mexc' => -> { Adapters::Cex::MexcAdapter.new },
          'kucoin' => -> { Adapters::Cex::KucoinAdapter.new },
          'bitget' => -> { Adapters::Cex::BitgetAdapter.new },
          'htx' => -> { Adapters::Cex::HtxAdapter.new }
        }.freeze

        def self.get(exchange)
          factory = ADAPTERS[exchange.to_s.downcase]
          raise ArgumentError, "Unknown CEX: #{exchange}" unless factory

          factory.call
        end

        def self.all
          ADAPTERS.keys.map { |name| [name, get(name)] }.to_h
        end

        def self.available
          ADAPTERS.keys
        end
      end

      # DEX Adapter Factory
      module Dex
        ADAPTERS = {
          'jupiter' => -> { Adapters::Dex::JupiterAdapter.new },
          'raydium' => -> { Adapters::Dex::RaydiumAdapter.new },
          'orca' => -> { Adapters::Dex::OrcaAdapter.new },
          'uniswap' => -> { Adapters::Dex::UniswapAdapter.new },
          'sushiswap' => -> { Adapters::Dex::SushiswapAdapter.new },
          'pancakeswap' => -> { Adapters::Dex::PancakeswapAdapter.new },
          'traderjoe' => -> { Adapters::Dex::TraderjoeAdapter.new },
          'camelot' => -> { Adapters::Dex::CamelotAdapter.new }
        }.freeze

        CHAINS = {
          'solana' => %w[jupiter raydium orca],
          'ethereum' => %w[uniswap sushiswap],
          'bsc' => %w[pancakeswap],
          'avalanche' => %w[traderjoe],
          'arbitrum' => %w[camelot]
        }.freeze

        def self.get(dex)
          factory = ADAPTERS[dex.to_s.downcase]
          raise ArgumentError, "Unknown DEX: #{dex}" unless factory

          factory.call
        end

        def self.for_chain(chain)
          dexes = CHAINS[chain.to_s.downcase] || []
          dexes.map { |name| [name, get(name)] }.to_h
        end

        def self.all
          ADAPTERS.keys.map { |name| [name, get(name)] }.to_h
        end

        def self.available
          ADAPTERS.keys
        end
      end

      # Perp DEX Adapter Factory
      module PerpDex
        ADAPTERS = {
          'hyperliquid' => -> { Adapters::PerpDex::HyperliquidAdapter.new },
          'dydx' => -> { Adapters::PerpDex::DydxAdapter.new },
          'gmx' => -> { Adapters::PerpDex::GmxAdapter.new },
          'vertex' => -> { Adapters::PerpDex::VertexAdapter.new },
          'aster' => -> { Adapters::PerpDex::AsterAdapter.new }
        }.freeze

        def self.get(dex)
          factory = ADAPTERS[dex.to_s.downcase]
          raise ArgumentError, "Unknown Perp DEX: #{dex}" unless factory

          factory.call
        end

        def self.all
          ADAPTERS.keys.map { |name| [name, get(name)] }.to_h
        end

        def self.available
          ADAPTERS.keys
        end
      end
    end
  end
end
