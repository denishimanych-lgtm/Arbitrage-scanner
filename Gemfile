# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.2.0'

# Telegram Bot
gem 'telegram-bot-ruby', '~> 2.0'

# HTTP & WebSocket
gem 'faraday', '~> 2.0'
gem 'faraday-retry', '~> 2.0'
gem 'faye-websocket', '~> 0.11'
gem 'eventmachine', '~> 1.2'

# Redis
gem 'redis', '~> 5.0'
gem 'hiredis-client', '~> 0.18'

# Concurrency
gem 'concurrent-ruby', '~> 1.2'

# JSON parsing (fast)
gem 'oj', '~> 3.16'

# Environment
gem 'dotenv', '~> 3.0'

# Logging
gem 'semantic_logger', '~> 4.15'

# Terminal colors
gem 'colorize', '~> 1.1'

# Ethereum/Web3 for DEX (Uniswap) - disabled for now, requires autoreconf
# gem 'eth', '~> 0.5'

group :development, :test do
  gem 'rspec', '~> 3.13'
  gem 'webmock', '~> 3.19'
  gem 'vcr', '~> 6.2'
  gem 'pry', '~> 0.14'
  gem 'rubocop', '~> 1.60', require: false
  gem 'rubocop-rspec', '~> 2.26', require: false
  gem 'mock_redis', '~> 0.44'
end
