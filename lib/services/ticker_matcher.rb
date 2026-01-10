# frozen_string_literal: true

module ArbitrageBot
  module Services
    # TickerMatcher - Matches and correlates tickers across different venues
    # Implements matching logic from ТЗ ЧАСТЬ 1
    class TickerMatcher
      # Match result structure
      MatchResult = Struct.new(
        :symbol,
        :matched_venues,
        :cex_futures_count,
        :cex_spot_count,
        :dex_count,
        :perp_dex_count,
        :has_contract,
        :match_quality,
        keyword_init: true
      )

      # Match quality levels
      QUALITY_EXCELLENT = :excellent  # 4+ venues, has contract
      QUALITY_GOOD = :good            # 3+ venues
      QUALITY_FAIR = :fair            # 2 venues
      QUALITY_POOR = :poor            # 1 venue (no arbitrage possible)

      def initialize
        @logger = ArbitrageBot.logger
      end

      # Match CEX spot symbols to existing futures tickers
      # @param tickers [Hash] existing tickers (keyed by symbol)
      # @param spot_symbols [Array] spot symbols from exchange
      # @param exchange [String] exchange name
      # @return [Hash] updated tickers with matched spot venues
      def match_cex_spot(tickers, spot_symbols, exchange)
        matched_count = 0

        spot_symbols.each do |sym|
          base_asset = normalize_symbol(sym[:base_asset])

          # Only add if we have futures for this symbol
          next unless tickers[base_asset]

          tickers[base_asset].add_cex_spot(
            exchange: exchange,
            symbol: sym[:symbol]
          )
          matched_count += 1
        end

        log("Matched #{matched_count} spot symbols for #{exchange}")
        { matched: matched_count, exchange: exchange }
      end

      # Match Perp DEX markets to existing tickers
      # @param tickers [Hash] existing tickers
      # @param markets [Array] markets from perp dex
      # @param dex_name [String] dex name
      # @return [Hash] match stats
      def match_perp_dex(tickers, markets, dex_name)
        matched_count = 0

        markets.each do |market|
          base_asset = extract_base_asset(market)
          next unless base_asset

          normalized = normalize_symbol(base_asset)
          next unless tickers[normalized]

          tickers[normalized].add_perp_dex(
            dex: dex_name,
            symbol: market[:symbol],
            status: market[:status]
          )
          matched_count += 1
        end

        log("Matched #{matched_count} perp markets for #{dex_name}")
        { matched: matched_count, dex: dex_name }
      end

      # Match DEX tokens by contract address
      # @param ticker [Models::Ticker] ticker with contracts
      # @param dex_result [Hash] result from DEX adapter find_token
      # @param dex_name [String] dex name
      # @param chain [String] blockchain network
      # @return [Boolean] whether match was added
      def match_dex_by_contract(ticker, dex_result, dex_name, chain)
        return false unless dex_result && dex_result[:found]

        ticker.add_dex_spot(
          dex: dex_name,
          chain: chain,
          pool_address: dex_result[:pool_address],
          has_liquidity: dex_result[:has_liquidity] || dex_result[:liquidity_usd].to_f > 1000,
          liquidity_usd: dex_result[:liquidity_usd]
        )

        true
      end

      # Calculate match quality for a ticker
      # @param ticker [Models::Ticker] ticker to evaluate
      # @return [MatchResult] match analysis
      def analyze_match(ticker)
        venues = ticker.venues

        cex_futures = (venues[:cex_futures] || []).size
        cex_spot = (venues[:cex_spot] || []).size
        dex_spot = (venues[:dex_spot] || []).size
        perp_dex = (venues[:perp_dex] || []).size

        total_venues = cex_futures + cex_spot + dex_spot + perp_dex
        has_contract = ticker.contracts.any?

        quality = determine_quality(total_venues, has_contract)

        MatchResult.new(
          symbol: ticker.symbol,
          matched_venues: total_venues,
          cex_futures_count: cex_futures,
          cex_spot_count: cex_spot,
          dex_count: dex_spot,
          perp_dex_count: perp_dex,
          has_contract: has_contract,
          match_quality: quality
        )
      end

      # Find best matching pairs between venue types
      # @param ticker [Models::Ticker] ticker to analyze
      # @return [Array<Hash>] potential arbitrage pairs sorted by priority
      def find_arbitrage_matches(ticker)
        pairs = []
        venues = ticker.venues

        # Priority 1: DEX <-> CEX Futures (DF strategy)
        (venues[:dex_spot] || []).each do |dex|
          (venues[:cex_futures] || []).each do |futures|
            pairs << build_pair_match(ticker.symbol, dex, futures, :DF, priority: 1)
          end
        end

        # Priority 2: DEX <-> Perp DEX (DP strategy)
        (venues[:dex_spot] || []).each do |dex|
          (venues[:perp_dex] || []).each do |perp|
            pairs << build_pair_match(ticker.symbol, dex, perp, :DP, priority: 2)
          end
        end

        # Priority 3: Spot <-> Futures same exchange (SF strategy)
        (venues[:cex_spot] || []).each do |spot|
          (venues[:cex_futures] || []).each do |futures|
            next unless spot[:exchange] == futures[:exchange]
            pairs << build_pair_match(ticker.symbol, spot, futures, :SF, priority: 3)
          end
        end

        # Priority 4: Futures <-> Futures cross-exchange (FF strategy)
        futures_list = venues[:cex_futures] || []
        futures_list.combination(2).each do |f1, f2|
          pairs << build_pair_match(ticker.symbol, f1, f2, :FF, priority: 4)
        end

        # Priority 5: Perp DEX <-> CEX Futures (PF strategy)
        (venues[:perp_dex] || []).each do |perp|
          (venues[:cex_futures] || []).each do |futures|
            pairs << build_pair_match(ticker.symbol, perp, futures, :PF, priority: 5)
          end
        end

        # Priority 6: Perp DEX <-> Perp DEX (PP strategy)
        perp_list = venues[:perp_dex] || []
        perp_list.combination(2).each do |p1, p2|
          pairs << build_pair_match(ticker.symbol, p1, p2, :PP, priority: 6)
        end

        pairs.sort_by { |p| p[:priority] }
      end

      # Batch match all tickers and return statistics
      # @param tickers [Hash] all tickers
      # @return [Hash] matching statistics
      def batch_analyze(tickers)
        stats = {
          total: tickers.size,
          excellent: 0,
          good: 0,
          fair: 0,
          poor: 0,
          with_contracts: 0,
          arbitrageable: 0
        }

        tickers.each_value do |ticker|
          result = analyze_match(ticker)

          case result.match_quality
          when QUALITY_EXCELLENT then stats[:excellent] += 1
          when QUALITY_GOOD then stats[:good] += 1
          when QUALITY_FAIR then stats[:fair] += 1
          when QUALITY_POOR then stats[:poor] += 1
          end

          stats[:with_contracts] += 1 if result.has_contract
          stats[:arbitrageable] += 1 if result.matched_venues >= 2
        end

        stats
      end

      private

      def normalize_symbol(symbol)
        symbol.to_s.upcase
          .gsub(/USDT$|USDC$|USD$|BUSD$/, '')
          .gsub(/[-_]/, '')
          .gsub(/PERP$/, '')
      end

      def extract_base_asset(market)
        market[:base_asset]&.upcase ||
          market[:symbol]&.upcase&.gsub(/USDT?$|USD$|PERP$/, '')
      end

      def determine_quality(venue_count, has_contract)
        if venue_count >= 4 && has_contract
          QUALITY_EXCELLENT
        elsif venue_count >= 3
          QUALITY_GOOD
        elsif venue_count >= 2
          QUALITY_FAIR
        else
          QUALITY_POOR
        end
      end

      def build_pair_match(symbol, venue1, venue2, strategy, priority:)
        {
          symbol: symbol,
          venue1: venue1,
          venue2: venue2,
          strategy: strategy,
          priority: priority
        }
      end

      def log(message)
        @logger.info("[TickerMatcher] #{message}")
      end
    end
  end
end
