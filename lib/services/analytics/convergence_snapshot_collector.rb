# frozen_string_literal: true

module ArbitrageBot
  module Services
    module Analytics
      # Captures periodic snapshots of prices and orderbook depths during convergence tracking
      class ConvergenceSnapshotCollector
        MAX_SNAPSHOTS_PER_SIGNAL = 500
        REDIS_TTL = 7 * 24 * 3600 # 7 days

        def initialize
          @logger = ArbitrageBot.logger
          @redis = Redis.new(
            url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
            connect_timeout: 5,
            read_timeout: 10
          )
        end

        # Capture a snapshot of current prices
        # @param signal_id [String] UUID of the signal
        # @param symbol [String] trading symbol
        # @param buy_venue [Hash] buy venue info with :venue_id
        # @param sell_venue [Hash] sell venue info with :venue_id
        # @param current_spread [Float] current spread percentage
        # @return [Boolean] success
        def capture_snapshot(signal_id:, symbol:, buy_venue:, sell_venue:, current_spread:)
          # Get current prices
          buy_prices = fetch_venue_prices(buy_venue, symbol)
          sell_prices = fetch_venue_prices(sell_venue, symbol)

          return false unless buy_prices && sell_prices

          # Get next sequence number
          seq = next_snapshot_seq(signal_id)
          return false if seq > MAX_SNAPSHOTS_PER_SIGNAL

          snapshot = {
            signal_id: signal_id,
            snapshot_seq: seq,
            snapshot_at: Time.now.iso8601,
            buy_venue_bid: buy_prices[:bid],
            buy_venue_ask: buy_prices[:ask],
            sell_venue_bid: sell_prices[:bid],
            sell_venue_ask: sell_prices[:ask],
            spread_pct: current_spread,
            buy_venue_bid_depth_usd: buy_prices[:bid_depth_usd],
            buy_venue_ask_depth_usd: buy_prices[:ask_depth_usd],
            sell_venue_bid_depth_usd: sell_prices[:bid_depth_usd],
            sell_venue_ask_depth_usd: sell_prices[:ask_depth_usd]
          }

          # Store in Redis for quick access
          store_in_redis(signal_id, snapshot)

          # Store in PostgreSQL for persistence (async for performance)
          store_in_postgres_async(snapshot)

          true
        rescue StandardError => e
          @logger.error("[SnapshotCollector] capture_snapshot error: #{e.message}")
          false
        end

        # Get all snapshots for a signal from Redis
        # @param signal_id [String]
        # @return [Array<Hash>] snapshots sorted by sequence
        def get_snapshots(signal_id)
          key = redis_key(signal_id)
          snapshots_json = @redis.lrange(key, 0, -1)

          snapshots_json.map { |s| JSON.parse(s, symbolize_names: true) }
            .sort_by { |s| s[:snapshot_seq] }
        rescue StandardError => e
          @logger.error("[SnapshotCollector] get_snapshots error: #{e.message}")
          []
        end

        # Get first and last snapshots for analysis
        # @param signal_id [String]
        # @return [Hash] { first: snapshot, last: snapshot }
        def get_bookend_snapshots(signal_id)
          snapshots = get_snapshots(signal_id)
          return nil if snapshots.empty?

          {
            first: snapshots.first,
            last: snapshots.last,
            count: snapshots.size
          }
        end

        # Get snapshots from PostgreSQL (for historical analysis)
        # @param signal_id [String]
        # @return [Array<Hash>]
        def get_snapshots_from_db(signal_id)
          sql = <<~SQL
            SELECT * FROM convergence_snapshots
            WHERE signal_id = $1
            ORDER BY snapshot_seq
          SQL

          DatabaseConnection.query_all(sql, [signal_id])
        rescue StandardError => e
          @logger.error("[SnapshotCollector] get_snapshots_from_db error: #{e.message}")
          []
        end

        private

        def redis_key(signal_id)
          "convergence:snapshots:#{signal_id}"
        end

        def seq_key(signal_id)
          "convergence:snapshot_seq:#{signal_id}"
        end

        def next_snapshot_seq(signal_id)
          @redis.incr(seq_key(signal_id)).to_i
        end

        def store_in_redis(signal_id, snapshot)
          key = redis_key(signal_id)
          @redis.rpush(key, snapshot.to_json)
          @redis.ltrim(key, -MAX_SNAPSHOTS_PER_SIGNAL, -1) # Keep last N
          @redis.expire(key, REDIS_TTL)
          @redis.expire(seq_key(signal_id), REDIS_TTL)
        end

        def store_in_postgres_async(snapshot)
          # Insert asynchronously to not block tracking
          Thread.new do
            store_in_postgres(snapshot)
          rescue StandardError => e
            @logger.error("[SnapshotCollector] async store error: #{e.message}")
          end
        end

        def store_in_postgres(snapshot)
          sql = <<~SQL
            INSERT INTO convergence_snapshots (
              signal_id, snapshot_at, snapshot_seq,
              buy_venue_bid, buy_venue_ask,
              sell_venue_bid, sell_venue_ask,
              spread_pct,
              buy_venue_bid_depth_usd, buy_venue_ask_depth_usd,
              sell_venue_bid_depth_usd, sell_venue_ask_depth_usd
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            ON CONFLICT (signal_id, snapshot_seq) DO NOTHING
          SQL

          DatabaseConnection.execute(sql, [
            snapshot[:signal_id],
            snapshot[:snapshot_at],
            snapshot[:snapshot_seq],
            snapshot[:buy_venue_bid],
            snapshot[:buy_venue_ask],
            snapshot[:sell_venue_bid],
            snapshot[:sell_venue_ask],
            snapshot[:spread_pct],
            snapshot[:buy_venue_bid_depth_usd],
            snapshot[:buy_venue_ask_depth_usd],
            snapshot[:sell_venue_bid_depth_usd],
            snapshot[:sell_venue_ask_depth_usd]
          ])
        end

        # Fetch current prices from Redis cache
        # @param venue [Hash] venue info
        # @param symbol [String]
        # @return [Hash, nil] { bid:, ask:, bid_depth_usd:, ask_depth_usd: }
        def fetch_venue_prices(venue, symbol)
          prices_json = @redis.get('prices:latest')
          return nil unless prices_json

          prices = JSON.parse(prices_json)

          # Build price key based on venue type
          venue_key = build_venue_key(venue, symbol)
          price_data = prices[venue_key]

          return nil unless price_data

          {
            bid: price_data['bid']&.to_f,
            ask: price_data['ask']&.to_f,
            bid_depth_usd: nil, # Would need orderbook fetch for this
            ask_depth_usd: nil
          }
        rescue StandardError => e
          @logger.debug("[SnapshotCollector] fetch_venue_prices error: #{e.message}")
          nil
        end

        def build_venue_key(venue, symbol)
          # Handle different venue formats
          venue_id = venue['venue_id'] || venue[:venue_id]
          exchange = venue['exchange'] || venue[:exchange]
          dex = venue['dex'] || venue[:dex]
          venue_type = venue['type'] || venue[:type]

          base_symbol = symbol.to_s.upcase
            .gsub(/USDT$|USDC$|USD$|BUSD$/, '')
            .gsub(/[-_]/, '')

          if venue_id
            "#{venue_id}:#{base_symbol}"
          elsif exchange
            market_type = venue_type&.to_s&.include?('futures') ? 'futures' : 'spot'
            "#{exchange}_#{market_type}:#{base_symbol}"
          elsif dex
            "#{dex}:#{base_symbol}"
          else
            nil
          end
        end
      end
    end
  end
end
