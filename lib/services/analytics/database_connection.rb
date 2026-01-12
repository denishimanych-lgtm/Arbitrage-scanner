# frozen_string_literal: true

require 'pg'
require 'connection_pool'
require 'yaml'
require 'erb'

module ArbitrageBot
  module Services
    module Analytics
      # Thread-safe PostgreSQL connection pool
      class DatabaseConnection
        class << self
          def pool
            @pool ||= create_pool
          end

          def with_connection(&block)
            pool.with(&block)
          end

          # Execute query with automatic connection handling
          def execute(sql, params = [])
            with_connection do |conn|
              if params.empty?
                conn.exec(sql)
              else
                conn.exec_params(sql, params)
              end
            end
          end

          # Execute query and return first row as hash
          def query_one(sql, params = [])
            result = execute(sql, params)
            return nil if result.ntuples.zero?

            result[0].transform_keys(&:to_sym)
          end

          # Execute query and return all rows as array of hashes
          def query_all(sql, params = [])
            result = execute(sql, params)
            result.map { |row| row.transform_keys(&:to_sym) }
          end

          # Insert and return the inserted row
          def insert(table, data)
            columns = data.keys.join(', ')
            placeholders = (1..data.size).map { |i| "$#{i}" }.join(', ')
            sql = "INSERT INTO #{table} (#{columns}) VALUES (#{placeholders}) RETURNING *"
            query_one(sql, data.values)
          end

          # Check connection health
          def connected?
            with_connection { |conn| conn.exec('SELECT 1') }
            true
          rescue StandardError
            false
          end

          # Reset pool (useful for fork safety)
          def reset!
            @pool&.shutdown { |conn| conn.close }
            @pool = nil
          end

          # Get current config
          def config
            @config ||= load_config
          end

          private

          def create_pool
            cfg = config
            pool_size = cfg[:pool] || 5

            ConnectionPool.new(size: pool_size, timeout: 5) do
              PG.connect(
                host: cfg[:host],
                port: cfg[:port],
                dbname: cfg[:database],
                user: cfg[:username],
                password: cfg[:password]
              )
            end
          end

          def load_config
            config_path = File.join(ArbitrageBot.root, 'config', 'database.yml')
            return default_config unless File.exist?(config_path)

            yaml_content = ERB.new(File.read(config_path)).result
            config = YAML.safe_load(yaml_content, permitted_classes: [], permitted_symbols: [], aliases: true)
            env = ENV.fetch('ARBITRAGE_ENV', 'development')

            config[env].transform_keys(&:to_sym)
          rescue StandardError => e
            ArbitrageBot.logger.error("[DatabaseConnection] Config load error: #{e.message}")
            default_config
          end

          def default_config
            {
              host: ENV.fetch('PG_HOST', 'localhost'),
              port: ENV.fetch('PG_PORT', 5432).to_i,
              database: ENV.fetch('PG_DATABASE', 'arbitrage_dev'),
              username: ENV.fetch('PG_USER', 'arbitrage'),
              password: ENV['PG_PASSWORD'],
              pool: ENV.fetch('PG_POOL', 5).to_i
            }
          end
        end
      end
    end
  end
end
