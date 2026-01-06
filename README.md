# Arbitrage Scanner

Real-time arbitrage detection system for DEX ↔ Futures price spreads.

## Features

- **Multi-Exchange Support**: 8 CEX (Binance, Bybit, OKX, Gate, MEXC, KuCoin, HTX, Bitget), 8 DEX, 5 PerpDEX
- **Real-time Monitoring**: Continuous price tracking with 1-second updates
- **Smart Safety Checks**: 7 validation checks including liquidity, slippage, and timing
- **Lagging Detection**: Identifies price delays between exchanges
- **Telegram Alerts**: Formatted notifications with action instructions
- **Configurable Filters**: Threshold, cooldown, blacklist management

## Quick Start

### Prerequisites

- Ruby 3.2+
- Redis 7.0+
- Telegram Bot Token

### Installation

```bash
# Clone repository
git clone https://github.com/denishimanych-lgtm/Arbitrage-scanner.git
cd Arbitrage-scanner

# Install dependencies
bundle install

# Configure environment
cp .env.example .env
# Edit .env with your Telegram credentials

# Start Redis
redis-server

# Run scanner
ruby bin/scanner
```

### Docker

```bash
# Build and run
docker-compose up -d

# View logs
docker-compose logs -f scanner

# Run discovery only
docker-compose --profile discovery up discovery
```

## Commands

### Entry Points

```bash
bin/scanner        # Main scanner with all components
bin/discovery      # Run ticker discovery only
bin/price_monitor  # Price monitoring only
bin/alert_worker   # Alert processing only
bin/telegram_bot   # Telegram bot only
```

### Telegram Commands

| Command | Description |
|---------|-------------|
| `/status` | System status and statistics |
| `/top [N]` | Top N current spreads |
| `/threshold <N>` | Set minimum spread % |
| `/cooldown <sec>` | Set alert cooldown |
| `/blacklist` | Manage blacklist |
| `/venues` | Show connected exchanges |
| `/pause` / `/resume` | Pause/resume alerts |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | - | Telegram bot token (required) |
| `TELEGRAM_CHAT_ID` | - | Target chat ID (required) |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `MIN_SPREAD_PCT` | `2.0` | Minimum spread to alert |
| `ALERT_COOLDOWN_SECONDS` | `300` | Cooldown between alerts |
| `MAX_SLIPPAGE_PCT` | `2.0` | Maximum acceptable slippage |

### Settings File

Edit `config/settings.yml` for detailed configuration.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ORCHESTRATOR                            │
│              (coordinates all components)                    │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   DISCOVERY  │     │    PRICE     │     │   TELEGRAM   │
│     JOB      │     │   MONITOR    │     │     BOT      │
└──────────────┘     └──────────────┘     └──────────────┘
                              │
                              ▼
                     ┌──────────────┐
                     │  ORDERBOOK   │
                     │   ANALYSIS   │
                     └──────────────┘
                              │
                              ▼
                     ┌──────────────┐
                     │   SAFETY     │
                     │   CHECKS     │
                     └──────────────┘
                              │
                              ▼
                     ┌──────────────┐
                     │   ALERT      │
                     │    JOB       │
                     └──────────────┘
```

## Signal Types

| Type | Description | High Venue |
|------|-------------|------------|
| **Auto** | Can be automated | Futures/PerpDEX (shortable) |
| **Manual** | Requires manual execution | Spot/DEX (non-shortable) |
| **Lagging** | Price delay detected | Any |

## Safety Checks

1. **Exit Liquidity** - Minimum $5K exit liquidity
2. **Position Size** - Minimum $1K position
3. **Slippage** - Maximum 2% total slippage
4. **Latency** - Data freshness < 5 seconds
5. **Depth vs History** - Not dangerously low vs average
6. **Spread Freshness** - Signal data < 60 seconds old
7. **Direction Validity** - High venue must be shortable

## Development

```bash
# Run tests
bundle exec rspec

# Run specific test
bundle exec rspec spec/services/blacklist_spec.rb

# Check syntax
ruby -c lib/**/*.rb
```

## License

Proprietary - All Rights Reserved

## Author

Built with Claude Code
