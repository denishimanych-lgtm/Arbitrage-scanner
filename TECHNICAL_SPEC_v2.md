# АРБИТРАЖНЫЙ СКАНЕР DEX ↔ FUTURES
## Техническое Задание v3.0

**Дата:** 2025-12-25
**Версия:** 3.0
**Статус:** In Development

---

## ОБНОВЛЕНИЕ v3.0: НОВАЯ АРХИТЕКТУРА

### Ключевые изменения в v3.0

1. **Symbol Inventory** — ежедневный скан бирж + маппинг контрактов через CoinGecko
2. **Orderbook Fetcher** — on-demand запрос ордербука перед алертом
3. **Opportunity Validator** — проверка направления сделки + расчёт размера позиции
4. **Strategy ID** — уникальный идентификатор для каждой возможности
5. **Расширенные биржи** — 8 CEX + 2 DEX + 2 PerpDEX

### Новый Pipeline обработки

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    SYMBOL INVENTORY (раз в день)                        │
│  • Скан всех CEX Futures → 2000+ тикеров                               │
│  • CoinGecko API → contract addresses для каждого токена               │
│  • Результат: unified_symbols в Redis                                   │
│  • { "BONK": { solana: "DezX...", exchanges: [binance, mexc...] } }    │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    PRICE COLLECTORS (realtime)                          │
│  CEX Spot (8): Binance, Bybit, MEXC, OKX, Gate, KuCoin, HTX, BingX     │
│  CEX Futures (8): те же биржи                                           │
│  DEX (1): Jupiter (Solana)                                              │
│  PerpDEX (2): Hyperliquid, dYdX                                         │
│                                                                          │
│  → Price Engine (Redis cache, TTL 60 сек)                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    SPREAD ENGINE v3                                      │
│  1. Вычисляет спред между всеми парами venues                          │
│  2. Фильтрует: spread > threshold?                                      │
│  3. Quick direction check: можем ли мы шортить?                         │
│  4. Если ДА → запускает Orderbook Fetcher                              │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    ORDERBOOK FETCHER (on-demand)                        │
│  • CEX: REST API depth endpoint (limit: 20 уровней)                    │
│  • DEX: Jupiter Quote API на разные суммы ($1k, $5k, $10k, $25k, $50k) │
│  • Результат: best_bid, best_ask, depth[], timestamp                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    OPPORTUNITY VALIDATOR                                │
│  • Direction check: можно ли шортить на high venue?                    │
│    - Spot/DEX: только BUY (нельзя шортить)                             │
│    - Futures/PerpDEX: можно LONG и SHORT                               │
│  • Latency check: данные свежие? (< 5 сек)                             │
│  • Size calculation: на сколько $ можно войти по лучшей цене           │
│  • Profit calculation: gross - fees - slippage = net                    │
│  • Strategy ID: SF-BONK-S5.2-1234                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    ALERT MANAGER v2                                     │
│  • Blacklist check                                                      │
│  • Cooldown check (по символу, 5 мин)                                   │
│  • Format alert (новый формат с orderbook данными)                      │
│  • Send to Telegram                                                     │
│  • Track strategy (для аналитики)                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Правило направления сделки

```
LOW venue (цена ниже) → HIGH venue (цена выше)

ВАЛИДНЫЕ КОМБИНАЦИИ:
✅ DEX/Spot (low) → Futures (high) = BUY spot + SHORT futures
✅ Futures (low) → Futures (high) = LONG low + SHORT high
✅ PerpDEX (low) → Futures (high) = LONG perpdex + SHORT futures

НЕВАЛИДНЫЕ КОМБИНАЦИИ:
❌ Futures (low) → Spot/DEX (high) = нужен SHORT на споте (невозможно!)
❌ Spot (low) → Spot (high) = нет хеджа
```

### Новый формат алерта

```
🔥🔥 BONK | 12.3%
━━━━━━━━━━━━━━━━━━━━━━━
📋 DF-BONK-S12.3-1234
📊 DEX ↔ Futures

💹 PRICES:
🟢 Jupiter DEX:
   $0.00002345 (bid: $0.00002340)
🔴 MEXC Futures:
   $0.00002635 (ask: $0.00002640)
📈 Delta: $0.0000029

💰 PROFIT ESTIMATE:
Gross: 12.3%
Fees:  -0.28%
Slip:  -~0.1%
━━━━━━━━━━━━━━━
Net:   +11.92%

💵 ~$1,490 on $12.5K position

✅ ACTION:
1️⃣ BUY BONK on Jupiter DEX
2️⃣ SHORT BONK on MEXC Futures
3️⃣ Enter in parts, match sizes
4️⃣ Wait for convergence

📊 LIQUIDITY:
Low venue:  $25K available
High venue: $50K available
Max entry:  $25K
Suggested:  $12.5K

🔗 LINKS:
• Buy: https://jup.ag/swap/USDC-DezX...
• Short: https://futures.mexc.com/...
• Chart: https://dexscreener.com/...

━━━━━━━━━━━━━━━━━━━━━━━
⏰ 14:32:05.123 | Latency: 45ms
⚠️ DYOR - verify before trading!
```

### Новые компоненты (файлы)

```
lib/
├── services/
│   ├── symbol_inventory.rb      # Ежедневный скан + контракты
│   ├── orderbook_fetcher.rb     # On-demand orderbook
│   ├── opportunity_validator.rb # Валидация + расчёты
│   ├── alert_formatter_v2.rb    # Новый формат
│   └── alert_manager_v2.rb      # Трекинг стратегий
├── engines/
│   └── spread_engine_v3.rb      # Интеграция всех компонентов
└── orchestrator_v2.rb           # Координатор v2

bin/
└── start_v2.rb                  # Скрипт запуска v2
```

### Биржи и venues

| Тип | Биржи | Venue ID |
|-----|-------|----------|
| CEX Spot | Binance, Bybit, MEXC, OKX, Gate, KuCoin, HTX, BingX | `{exchange}_spot` |
| CEX Futures | Binance, Bybit, MEXC, OKX, Gate, KuCoin, HTX, BingX | `{exchange}_futures` |
| DEX | Jupiter (Solana) | `jupiter_dex` |
| PerpDEX | Hyperliquid, dYdX | `hyperliquid_perp`, `dydx_perp` |

### Strategy ID формат

```
{TYPE}-{SYMBOL}-S{spread}-{timestamp}

TYPE:
  SF = Spot ↔ Futures
  DF = DEX ↔ Futures
  FF = Futures ↔ Futures
  PF = PerpDEX ↔ Futures

Примеры:
  DF-BONK-S12.3-1234   (DEX-Futures, BONK, spread 12.3%)
  SF-BTC-S0.5-5678     (Spot-Futures, BTC, spread 0.5%)
  FF-ETH-S0.8-9012     (Futures-Futures, ETH, spread 0.8%)
```

---

## ОРИГИНАЛЬНАЯ СПЕЦИФИКАЦИЯ (v2.0)

Далее следует оригинальная спецификация v2.0 для справки.

---

## 1. EXECUTIVE SUMMARY

### 1.1 Цель продукта

Realtime-система для обнаружения ценовых расхождений между **децентрализованными биржами (DEX)** и **фьючерсами на централизованных биржах (CEX)**.

**Основной кейс использования:**
Новые монеты появляются на DEX (Solana/Jupiter), затем листятся на фьючерсах второго эшелона (MEXC, Bybit, Gate). При этом цены могут расходиться на **5-40%** из-за:
- Разной ликвидности
- Задержки арбитражников
- Разных механик ценообразования (AMM vs orderbook)
- Спекулятивных настроений на фьючерсах

### 1.2 Основные торговые стратегии

#### Стратегия 1: Хедж-арбитраж (безрисковый)
```
Действия:
1. Покупка токена на DEX (spot)
2. Одновременный SHORT на фьючерсе (равный объем)
3. Ожидание схождения цен
4. Закрытие обеих позиций

Прибыль = начальный спред - комиссии - slippage

Требования:
- Минимальный спред ≥5% (комиссии DEX ~2-3%)
- Достаточная ликвидность на обеих площадках
- Возможность депозита токена на CEX
```

#### Стратегия 2: Скальпинг-арбитраж (спекулятивный)
```
Действия:
1. DEX используется как индикатор "справедливой" цены
2. Futures цена > DEX → SHORT futures
3. Futures цена < DEX → LONG futures
4. Закрытие сделки через 1-5 минут

Логика:
- Futures следует за DEX (до листинга на крупных биржах)
- Спред = переоцененность/недооцененность

Требования:
- Минимальный спред ≥2%
- Быстрое исполнение (<3 сек от алерта)
- Новые токены (<30 дней на DEX)
```

### 1.3 Метрики успеха

**MVP:**
- Задержка алерта: <5 сек от появления спреда
- Количество отслеживаемых пар: 200+
- Uptime: >95%
- Ложные алерты: <10% (разные токены с одним тикером)

**Production:**
- Задержка алерта: <3 сек
- Количество пар: 500+
- Uptime: >99%
- Ложные алерты: <5%

---

## 2. ФУНКЦИОНАЛЬНЫЕ ТРЕБОВАНИЯ

### 2.1 Сбор данных

#### 2.1.1 CEX Futures (приоритет)

**MVP Phase 1 (2 биржи):**
- ✅ **MEXC Futures** - основная биржа для новых листингов
- ✅ **Bybit Futures** - второй эшелон, большие объемы

**MVP Phase 2 (+3 биржи):**
- Gate.io Futures
- OKX Futures
- Binance Futures

**Post-MVP:**
- Bingx Futures
- Bitmart Futures

**Данные по каждому фьючерсу:**
```json
{
  "symbol": "PEPE/USDT",
  "price": 0.00001234,
  "volume_24h": 5000000,
  "market": "futures",
  "exchange": "MEXC",
  "max_position_size": 1000000, // optional
  "deposit_enabled": true,      // optional (Post-MVP)
  "withdraw_enabled": true      // optional (Post-MVP)
}
```

#### 2.1.2 DEX (Solana - приоритет)

**MVP Phase 1:**
- ✅ **Jupiter Aggregator** (Solana) - агрегирует Raydium, Orca, etc.
  - API: `https://quote-api.jup.ag/v6/quote`
  - Polling interval: 2-5 секунд
  - Rate limit: нет публичного (soft limit 1 req/sec на токен)

**Источник метаданных:**
- ✅ **DexScreener API** - ликвидность, объемы, графики
  - API: `https://api.dexscreener.com/latest/dex/tokens/{address}`
  - Rate limit: 300 req/min (5 req/sec)
  - Cache TTL: 5 минут

**Post-MVP:**
- 1inch / DexScreener для EVM сетей (Ethereum, BSC, Avalanche)

**Данные по каждому DEX токену:**
```json
{
  "symbol": "PEPE",
  "contract_address": "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr",
  "network": "solana",
  "price": 0.00001100,
  "liquidity_usd": 850000,
  "volume_24h": 320000,
  "pool_age_days": 12,
  "buy_tax": 0,    // % комиссия при покупке (от GoPlus)
  "sell_tax": 0    // % комиссия при продаже
}
```

#### 2.1.3 Дополнительные источники (опционально)

**Token Mapping:**
- Jupiter Token List API: `https://token.jup.ag/all`
- Обновление: 1 раз в час
- Назначение: маппинг symbol → contract address

**Security Check (Post-MVP):**
- GoPlus API: `https://api.gopluslabs.io/api/v1/token_security/{chain_id}`
- Rate limit: 200 req/day FREE, 10k req/day PRO ($199/мес)
- Использование: выборочно для новых токенов (<24h)

**Rankings & Links (Post-MVP):**
- CoinGecko API (fallback вместо CoinMarketCap)
- Rate limit: 10-50 req/min
- Cache TTL: 7 дней

---

### 2.2 Сопоставление токенов CEX ↔ DEX

**Проблема:**
CEX оперирует тикерами (`PEPE/USDT`), DEX - адресами контрактов (`7GCihgDB...`). Нужен механизм сопоставления.

**Решение (3 этапа):**

#### Этап 1: Загрузка маппинга при старте
```ruby
# При старте приложения:
1. Загрузить Jupiter Token List (https://token.jup.ag/all)
2. Построить mapping: { "PEPE" => "7GCihgDB8fe6..." }
3. Сохранить в Redis с TTL 24 часа
4. Фоновая задача обновляет mapping каждый час
```

#### Этап 2: Поиск соответствия для фьючерса
```ruby
# При получении фьючерса с MEXC:
futures_symbol = "PEPEUSDT"

1. Нормализовать: "PEPEUSDT" → "PEPE/USDT" → "PEPE"
2. Найти в маппинге адрес контракта Solana
3. Если найден → получить цену с Jupiter
4. Если НЕ найден → скип (токен не торгуется на Solana DEX)
```

#### Этап 3: Валидация соответствия
```ruby
# Проверка что это ДЕЙСТВИТЕЛЬНО тот же токен:
if liquidity_usd < 100_000
  # Скорее всего скам-токен с таким же тикером
  skip_alert
end

if pool_age_days > 180 && spread < 5%
  # Старый токен, маленький спред - скорее всего разные токены
  skip_alert
end
```

**Обработка коллизий (одинаковые тикеры):**

Пример: PEPE существует на Ethereum, Solana, BSC

```ruby
# Приоритет:
1. Solana (MVP)
2. Ethereum (Post-MVP)
3. BSC (Post-MVP)

# Если несколько токенов с одним тикером на одной сети:
# → Приоритет по ликвидности (max liquidity_usd)
```

**Fallback:**
```ruby
# Если нет в Jupiter Token List:
1. DexScreener Search API: /search/?q={symbol}
2. Выбрать результат с наибольшей ликвидностью на Solana
3. Кэшировать в Redis на 7 дней
```

---

### 2.3 Фильтрация и валидация

#### 2.3.1 Настраиваемые фильтры

**MVP (обязательные):**
```ruby
Config:
  min_spread_percent: 2.0              # Минимальный спред
  min_liquidity_usd: 500_000           # Мин. ликвидность пула DEX
  min_volume_24h_dex: 200_000          # Мин. объем 24ч на DEX
  min_volume_24h_futures: 200_000      # Мин. объем 24ч на фьючерсе
```

**MVP (опциональные):**
```ruby
Config:
  max_pool_age_days: 30                # Только новые токены
  enabled_exchanges: ["MEXC", "Bybit"] # Список бирж
  enabled_networks: ["solana"]         # Список сетей
  blacklist: []                        # Черный список (символы/адреса)
```

**Post-MVP (расширенные):**
```ruby
Config:
  direction: "both"                    # "long" | "short" | "both"
  require_deposit_enabled: false       # Проверять статус депозита
  max_buy_tax: 5.0                     # Макс. комиссия покупки на DEX
  max_sell_tax: 5.0                    # Макс. комиссия продажи
  min_spread_by_age:                   # Динамический порог
    "0-7": 2.0                         # 0-7 дней: 2%
    "7-30": 3.0                        # 7-30 дней: 3%
    "30+": 5.0                         # >30 дней: 5%
```

#### 2.3.2 Расчет спреда

**Формула:**
```ruby
spread_percent = (futures_price - dex_price) / dex_price * 100

# Примеры:
# DEX: $1.00, Futures: $1.05 → spread = +5.0% (SHORT futures)
# DEX: $1.10, Futures: $1.00 → spread = -9.1% (LONG futures)
```

**Направление сделки:**
```ruby
if spread_percent > 0
  direction = "SHORT"  # Futures переоценен → шортить
  strategy = "HEDGE: Buy DEX + Short Futures"
elsif spread_percent < 0
  direction = "LONG"   # Futures недооценен → лонговать
  strategy = "LONG Futures (DEX higher)"
end
```

**Валидация спреда:**
```ruby
# Фильтр нереалистичных спредов (разные токены)
MAX_REALISTIC_SPREAD = 50.0

if spread_percent.abs > MAX_REALISTIC_SPREAD
  # Скорее всего это разные токены с одинаковым тикером
  skip_alert
end
```

#### 2.3.3 Приоритизация по возрасту токена

```ruby
# "Свежие" токены - более агрессивные алерты:

def should_alert?(token, spread_percent)
  case token.pool_age_days
  when 0..7
    spread_percent.abs >= 2.0  # Новые: 2%+
  when 7..30
    spread_percent.abs >= 3.0  # Средние: 3%+
  else
    spread_percent.abs >= 5.0  # Старые: 5%+ (скорее всего разные токены)
  end
end
```

---

### 2.4 Формат алерта

#### 2.4.1 MVP - Базовая версия

```
🔥 ARBITRAGE: PEPE | Solana

📊 Spread: +5.23% (SHORT)
💰 Profit potential: ~$523 per $10k

Prices:
🟢 DEX (Jupiter):  $0.00001100
🔴 Futures (MEXC): $0.00001157

Metrics:
💧 Liquidity: $850k
📈 Volume 24h: $320k (DEX) / $5.2M (Futures)
🕐 Pool age: 12 days

Links:
🔗 Trade DEX: https://jup.ag/swap/SOL-7GCihgDB...
🔗 Trade Futures: https://futures.mexc.com/exchange/PEPE_USDT
📊 Chart: https://dexscreener.com/solana/7GCihgDB...

Contract: 7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr
```

#### 2.4.2 Post-MVP - Расширенная версия

Дополнительно:
```
Position sizing:
📏 Max position (Futures): $50,000
⚠️ Recommended: $5,000 (10% of max)

Fees estimate:
💸 DEX fees: ~2.5% ($250)
💸 Futures fees: ~0.06% ($6)
💸 Total cost: $256
✅ Net profit: $267 (2.67%)

Security:
✅ GoPlus: No honeypot detected
✅ Tax: 0% buy / 0% sell
⚠️ Holders: 234 (low)

Rankings:
📊 CMC: #458 | 🦎 CG: Not listed
```

#### 2.4.3 Cooldown механизм

```ruby
Config:
  alert_cooldown_seconds: 300  # 5 минут между алертами на один символ

# Логика:
# После отправки алерта для PEPE:
# - Следующий алерт для PEPE возможен через 5 минут
# - Алерты для других символов отправляются без задержки
```

---

### 2.5 Telegram интерфейс

#### 2.5.1 Команды управления

**Информационные:**
```
/start         - Приветствие и список команд
/help          - Подробная справка
/status        - Статистика системы (кол-во пар, uptime, алертов)
/ping          - Проверка работоспособности бота
```

**Мониторинг:**
```
/top [N]       - Топ N текущих спредов (по умолчанию 10)
                 Пример: /top 20

/venues        - Список подключенных бирж и их статус
                 Пример вывода:
                 ✅ MEXC Futures: 145 symbols
                 ✅ Bybit Futures: 178 symbols
                 ✅ Jupiter (Solana): 2341 tokens
```

**Настройка фильтров:**
```
/threshold <N>      - Установить мин. спред в % (по умолчанию 2.0)
                      Пример: /threshold 3.5

/cooldown <seconds> - Установить задержку между алертами
                      Пример: /cooldown 600 (10 минут)

/liquidity <USD>    - Установить мин. ликвидность пула
                      Пример: /liquidity 1000000 ($1M)

/volume <USD>       - Установить мин. объем 24ч
                      Пример: /volume 500000
```

**Черный список:**
```
/blacklist              - Показать черный список
/blacklist add <SYMBOL> - Добавить символ
                          Пример: /blacklist add SCAM
/blacklist remove <SYMBOL> - Удалить символ
```

**Управление системой:**
```
/pause         - Приостановить отправку алертов
/resume        - Возобновить отправку алертов
```

#### 2.5.2 Пример диалога

```
User: /status

Bot:
📊 Arbitrage Scanner Status

Uptime: 2d 14h 35m
Monitored pairs: 234
Alerts sent (24h): 18

Active collectors:
✅ MEXC Futures: 145 symbols
✅ Bybit Futures: 178 symbols
✅ Jupiter DEX: 2341 tokens

Last update: 2s ago
Redis: ✅ Connected
```

```
User: /top 5

Bot:
🔥 Top 5 Spreads (live)

1. PEPE | +5.23% SHORT
   DEX $0.00001100 → MEXC $0.00001157
   Liquidity: $850k

2. WIF | +4.87% SHORT
   DEX $1.234 → Bybit $1.294
   Liquidity: $2.1M

3. BONK | -3.45% LONG
   DEX $0.00002100 → MEXC $0.00002027
   Liquidity: $1.5M

[...]

Updated: just now
```

---

## 3. ТЕХНИЧЕСКИЕ ТРЕБОВАНИЯ

### 3.1 Архитектура системы

#### 3.1.1 Компоненты

```
┌─────────────────────────────────────────────────────┐
│                   ORCHESTRATOR                      │
│         (координация всех компонентов)              │
└─────────────────────────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  COLLECTORS  │ │  COLLECTORS  │ │  COLLECTORS  │
│              │ │              │ │              │
│ MEXC Futures │ │Bybit Futures │ │ Jupiter DEX  │
│  (WebSocket) │ │  (WebSocket) │ │ (REST Poll)  │
└──────────────┘ └──────────────┘ └──────────────┘
         │               │               │
         └───────────────┼───────────────┘
                         ▼
              ┌────────────────────┐
              │   PRICE ENGINE     │
              │  (агрегация цен)   │
              │  Redis: arb:price  │
              └────────────────────┘
                         │
                         ▼
              ┌────────────────────┐
              │   SPREAD ENGINE    │
              │ (расчет спредов)   │
              │   фильтрация       │
              └────────────────────┘
                         │
                         ▼
              ┌────────────────────┐
              │  ALERT MANAGER     │
              │   (cooldown,       │
              │    blacklist)      │
              └────────────────────┘
                         │
                         ▼
              ┌────────────────────┐
              │  TELEGRAM BOT      │
              │  (уведомления,     │
              │   управление)      │
              └────────────────────┘
```

#### 3.1.2 Data Flow

```ruby
# 1. Сбор цен
CEX Collector → receives futures price via WebSocket
              → normalize symbol
              → PriceEngine.update_price(symbol, venue, price, metadata)

Jupiter Collector → polls Jupiter API every 3 sec
                  → finds contract address for symbol
                  → gets quote from Jupiter
                  → enriches with DexScreener data (liquidity, volume)
                  → PriceEngine.update_price(symbol, "Jupiter", price, metadata)

# 2. Агрегация в PriceEngine
PriceEngine → stores in Redis: arb:price:{SYMBOL} → { venue => price }
            → triggers callback: on_price_update(symbol)

# 3. Расчет спредов в SpreadEngine
SpreadEngine → on_price_update callback
             → fetch all prices for symbol from Redis
             → calculate spreads between all venue pairs
             → filter invalid pairs (spot-spot, low volume)
             → filter by threshold (min_spread_percent)
             → filter unrealistic spreads (>50%)
             → triggers callback: on_spread_detected(spread_data)

# 4. Управление алертами
AlertManager → on_spread_detected callback
             → check blacklist
             → check cooldown (last alert time)
             → format alert message
             → send to TelegramBot

# 5. Отправка алерта
TelegramBot → send_message(chat_id, formatted_alert)
            → log sent alert
            → update cooldown timestamp in Redis
```

#### 3.1.3 Зависимости между модулями

```ruby
# lib/orchestrator.rb
class Orchestrator
  def initialize
    @price_engine = PriceEngine.new
    @spread_engine = SpreadEngine.new(price_engine: @price_engine)
    @alert_manager = AlertManager.new
    @telegram_bot = TelegramBot.new

    # Collectors
    @mexc_futures = MexcFuturesCollector.new
    @bybit_futures = BybitCollector.new(market: 'futures')
    @jupiter = JupiterCollector.new  # NEW

    # Wire callbacks
    @mexc_futures.on_price_update { |data| @price_engine.update(data) }
    @bybit_futures.on_price_update { |data| @price_engine.update(data) }
    @jupiter.on_price_update { |data| @price_engine.update(data) }

    @spread_engine.on_spread_detected { |spread| @alert_manager.handle(spread) }
    @alert_manager.on_alert { |msg| @telegram_bot.send_alert(msg) }
  end
end
```

---

### 3.2 Источники данных (детально)

#### 3.2.1 CEX Futures API

**MEXC Futures (WebSocket):**
```ruby
# WebSocket URL:
wss://contract.mexc.com/edge

# Subscribe message:
{
  "method": "sub.deal",
  "param": {
    "symbol": "PEPE_USDT"
  }
}

# Response format:
{
  "channel": "push.deal",
  "data": {
    "M": 1,  // direction (1=buy, 2=sell)
    "O": 2,  // order type
    "T": 1702123456789,
    "p": 0.00001157,  // price
    "v": 12345        // volume
  },
  "symbol": "PEPE_USDT",
  "ts": 1702123456789
}

# Volume 24h API:
GET https://contract.mexc.com/api/v1/contract/ticker
Response:
{
  "data": [{
    "symbol": "PEPE_USDT",
    "lastPrice": 0.00001157,
    "volume24": 5200000,
    ...
  }]
}
```

**Bybit Futures (WebSocket):**
```ruby
# WebSocket URL:
wss://stream.bybit.com/v5/public/linear

# Subscribe:
{
  "op": "subscribe",
  "args": ["tickers.PEPEUSDT"]
}

# Response:
{
  "topic": "tickers.PEPEUSDT",
  "data": {
    "symbol": "PEPEUSDT",
    "lastPrice": "0.00001157",
    "volume24h": "5200000",
    ...
  }
}
```

#### 3.2.2 Jupiter (Solana DEX) API

**Quote API (цены):**
```ruby
# Endpoint:
GET https://quote-api.jup.ag/v6/quote

# Parameters:
inputMint: So11111111111111111111111111111111111111112  # SOL
outputMint: 7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr # PEPE
amount: 1000000000  # 1 SOL in lamports
slippageBps: 50     # 0.5% slippage

# Response:
{
  "inputMint": "So11111...",
  "outputMint": "7GCihg...",
  "inAmount": "1000000000",
  "outAmount": "90909090",  // = price calculation
  "priceImpactPct": 0.25,
  "routePlan": [...]
}

# Price calculation:
price_pepe_in_sol = outAmount / inAmount
price_sol_in_usdt = 100  # from another quote or oracle
price_pepe_in_usdt = price_pepe_in_sol * price_sol_in_usdt
```

**Token List API (маппинг):**
```ruby
# Endpoint:
GET https://token.jup.ag/all

# Response:
[
  {
    "address": "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr",
    "symbol": "PEPE",
    "name": "Pepe",
    "decimals": 6,
    "logoURI": "https://...",
    "tags": ["community"]
  },
  ...
]

# Использование:
# 1. Load при старте
# 2. Build hash: { "PEPE" => "7GCihgDB..." }
# 3. Cache в Redis (TTL 24h)
# 4. Refresh каждый час в фоне
```

#### 3.2.3 DexScreener API (метаданные)

```ruby
# Endpoint:
GET https://api.dexscreener.com/latest/dex/tokens/{address}

# Example:
GET https://api.dexscreener.com/latest/dex/tokens/7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr

# Response:
{
  "pairs": [
    {
      "chainId": "solana",
      "dexId": "raydium",
      "pairAddress": "ABC123...",
      "baseToken": {
        "address": "7GCihgDB...",
        "symbol": "PEPE"
      },
      "quoteToken": {
        "symbol": "USDC"
      },
      "priceUsd": "0.00001100",
      "liquidity": {
        "usd": 850000
      },
      "volume": {
        "h24": 320000
      },
      "pairCreatedAt": 1701000000000,
      "url": "https://dexscreener.com/solana/ABC123..."
    }
  ]
}

# Usage:
# - liquidity.usd → фильтр мин. ликвидности
# - volume.h24 → фильтр мин. объема
# - pairCreatedAt → расчет возраста пула
# - url → ссылка в алерте
# - Cache: 5 минут
```

#### 3.2.4 Rate Limits (сводная таблица)

| API | Limit (Free) | Достаточно? | Решение |
|-----|--------------|-------------|---------|
| Jupiter Quote | No public limit | ✅ Да | Soft limit 1 req/sec |
| Jupiter Token List | No limit | ✅ Да | Update 1x/hour |
| DexScreener | 300 req/min (5/sec) | ⚠️ Узкое место | Cache 5 min |
| MEXC Futures WS | No limit | ✅ Да | - |
| MEXC REST | 20 req/sec | ✅ Да | - |
| Bybit WS | No limit | ✅ Да | - |
| GoPlus (optional) | 200 req/day | ❌ Мало | Pro $199/мес OR выборочно |
| CoinGecko (optional) | 10-50 req/min | ⚠️ Мало | Cache 7 дней |

---

### 3.3 Хранилище данных (Redis)

#### 3.3.1 Структура ключей

```ruby
# Цены (TTL: 60 сек)
arb:price:{SYMBOL}
Value: Hash { venue => price }
Example:
  arb:price:PEPE/USDT = {
    "MEXC Futures": "0.00001157",
    "Bybit Futures": "0.00001160",
    "Jupiter": "0.00001100"
  }

# Метаданные токенов (TTL: 5 мин)
arb:metadata:{SYMBOL}
Value: Hash
Example:
  arb:metadata:PEPE/USDT = {
    "contract_address": "7GCihgDB...",
    "network": "solana",
    "liquidity_usd": "850000",
    "volume_24h": "320000",
    "pool_age_days": "12"
  }

# Маппинг symbol → contract (TTL: 24 часа)
arb:contract:{SYMBOL}
Value: String (contract address)
Example:
  arb:contract:PEPE = "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr"

# Cooldown алертов (TTL: 300 сек)
arb:alert:cooldown:{SYMBOL}
Value: Timestamp
Example:
  arb:alert:cooldown:PEPE/USDT = 1702123456

# Настройки пользователя (без TTL)
arb:config:threshold = "2.0"
arb:config:cooldown = "300"
arb:config:min_liquidity = "500000"
arb:blacklist = Set["SCAM", "RUGPULL", ...]

# Статистика (без TTL)
arb:stats:alerts_sent_24h = 18
arb:stats:uptime_start = 1702000000

# Token bucket для rate limiting (TTL: 60 сек)
arb:ratelimit:dexscreener:tokens = 300
arb:ratelimit:dexscreener:refill_at = 1702123456
```

#### 3.3.2 Кэширование стратегия

| Тип данных | TTL | Обоснование |
|------------|-----|-------------|
| Цены | 60 сек | Стейл цены опасны для алертов |
| Ликвидность/объемы | 5 мин | Меняются медленно, экономия API calls |
| Маппинг токенов | 24 часа | Редко меняется |
| CoinGecko данные | 7 дней | Статические метаданные |
| GoPlus проверки | 30 дней | Безопасность контракта редко меняется |

#### 3.3.3 Персистентность (Production)

```ruby
# redis.conf настройки:
save 900 1      # Save every 15 min if ≥1 key changed
save 300 10     # Save every 5 min if ≥10 keys changed
save 60 10000   # Save every 1 min if ≥10k keys changed

appendonly yes  # Enable AOF
appendfsync everysec  # Fsync every second (balance)

# Backup стратегия:
# - RDB snapshots каждые 6 часов → S3/Backblaze
# - AOF для точности восстановления
```

---

### 3.4 Rate Limiting & Throttling

#### 3.4.1 Token Bucket реализация

```ruby
# lib/services/rate_limiter.rb
class RateLimiter
  def initialize(name:, max_tokens:, refill_rate:)
    @name = name
    @max_tokens = max_tokens
    @refill_rate = refill_rate  # tokens per second
    @redis_key = "arb:ratelimit:#{name}:tokens"
  end

  def acquire(tokens = 1)
    current = redis.get(@redis_key).to_i

    # Refill tokens
    last_refill = redis.get("#{@redis_key}:last_refill").to_i
    elapsed = Time.now.to_i - last_refill
    refill = [elapsed * @refill_rate, @max_tokens - current].min
    current = [current + refill, @max_tokens].min

    if current >= tokens
      redis.decrby(@redis_key, tokens)
      redis.set("#{@redis_key}:last_refill", Time.now.to_i)
      true
    else
      false  # Rate limited
    end
  end
end

# Использование:
dexscreener_limiter = RateLimiter.new(
  name: "dexscreener",
  max_tokens: 300,
  refill_rate: 5  # 5 req/sec = 300 req/min
)

if dexscreener_limiter.acquire
  # Make API call
else
  # Wait or skip
end
```

#### 3.4.2 Priority Queue для ограниченных API

```ruby
# Для GoPlus (200 req/day = ~8 req/hour):
class GoPlus Priority Queue
  HIGH:   Новые токены (<24h)
  MEDIUM: Токены с объемом >$100k
  LOW:    Остальные (проверка раз в 6 часов)

# Логика:
def should_check_goplus?(token)
  return true if token.age_hours < 24  # Всегда проверять новые

  last_check = redis.get("arb:goplus:last_check:#{token.address}")
  return false if last_check && (Time.now.to_i - last_check.to_i) < 6.hours

  token.volume_24h > 100_000  # Проверять только высоколиквидные
end
```

---

### 3.5 Производительность

#### 3.5.1 Latency требования

**Breakdown целевой latency (<3 сек):**

```
WebSocket update      →  100-500ms  (CEX)
Jupiter API poll      →  200-800ms  (DEX)
Redis update          →  1-5ms
Spread calculation    →  <1ms
DexScreener enrichment → 200-500ms  (cached: <5ms)
Alert formatting      →  <1ms
Telegram send         →  200-800ms
─────────────────────────────────────
TOTAL (worst case):     1.7-2.6 sec  ✅
TOTAL (cached):         0.5-1.3 sec  ✅
```

**Оптимизации:**
- DexScreener кэш (5 мин) → экономит 200-500ms на 95% алертов
- Jupiter polling каждые 2-3 сек (не чаще) → снижает нагрузку
- Concurrent API calls где возможно

#### 3.5.2 Throughput (обновлений/сек)

```
Collectors:
- MEXC WebSocket:     ~50-100 updates/sec
- Bybit WebSocket:    ~50-100 updates/sec
- Jupiter Polling:    ~10-20 updates/sec (200 tokens / 10 sec interval)
TOTAL INPUT:          ~110-220 updates/sec

Processing:
- PriceEngine (Redis HSET):  ~10,000 ops/sec capacity
- SpreadEngine (calculations): CPU-bound, ~1000/sec capacity
- AlertManager (filters):      ~5000/sec capacity
BOTTLENECK: None (headroom 5-10x)
```

#### 3.5.3 Масштабируемость

**Текущая архитектура (single instance):**
- Поддерживает: 500+ пар
- Memory: ~200-500MB
- CPU: ~20-40% (2 cores)

**Горизонтальное масштабирование (future):**
```
Instance 1: MEXC + Bybit collectors
Instance 2: Gate + OKX collectors
Instance 3: Jupiter + DexScreener

Shared Redis cluster
Load balancer для Telegram webhook (если используется)
```

---

### 3.6 Стек технологий

#### 3.6.1 Ruby 3.2+ (обоснование)

**Преимущества:**
- Отличная поддержка multi-threading (Ractor для параллелизма)
- Богатая экосистема гемов для WebSocket, HTTP, Redis
- Быстрая разработка и итерации
- Semantic Logger для структурированного логирования

**Альтернативы рассмотренные:**
- Python: медленнее, GIL проблемы
- Node.js: callback hell для сложной логики
- Go: быстрее, но длиннее разработка

#### 3.6.2 Redis 7.0+ (конфигурация)

```ruby
# Gemfile
gem 'redis', '~> 5.0'
gem 'hiredis-client', '~> 0.18'  # Faster C-based driver
gem 'connection_pool', '~> 2.4'

# Config
REDIS_POOL = ConnectionPool.new(size: 10, timeout: 5) do
  Redis.new(
    url: ENV['REDIS_URL'],
    driver: :hiredis,
    reconnect_attempts: 3
  )
end
```

#### 3.6.3 Основные гемы

```ruby
# Gemfile

# HTTP & WebSocket
gem 'faraday', '~> 2.0'
gem 'faraday-retry', '~> 2.0'
gem 'faye-websocket', '~> 0.11'
gem 'eventmachine', '~> 1.2'

# Data & Parsing
gem 'oj', '~> 3.16'  # Fast JSON
gem 'concurrent-ruby', '~> 1.2'  # Thread-safe collections

# Telegram
gem 'telegram-bot-ruby', '~> 2.0'

# Utilities
gem 'dotenv', '~> 3.0'
gem 'semantic_logger', '~> 4.15'

# Development & Testing
group :development, :test do
  gem 'rspec', '~> 3.13'
  gem 'webmock', '~> 3.19'
  gem 'vcr', '~> 6.2'
  gem 'pry', '~> 0.14'
  gem 'rubocop', '~> 1.60'
end
```

---

## 4. НАДЕЖНОСТЬ И ОТКАЗОУСТОЙЧИВОСТЬ

### 4.1 Reconnect механизм

```ruby
# lib/collectors/base_collector.rb
class BaseCollector
  MAX_RECONNECT_ATTEMPTS = 10
  BACKOFF_BASE = 2  # seconds

  def connect
    @reconnect_attempts = 0

    @ws.on :close do |event|
      logger.warn "WebSocket closed", code: event.code
      schedule_reconnect
    end

    @ws.on :error do |event|
      logger.error "WebSocket error", message: event.message
      schedule_reconnect
    end
  end

  def schedule_reconnect
    @reconnect_attempts += 1

    if @reconnect_attempts > MAX_RECONNECT_ATTEMPTS
      logger.fatal "Max reconnect attempts reached, giving up"
      notify_admin("Collector #{name} failed to reconnect")
      return
    end

    delay = BACKOFF_BASE ** @reconnect_attempts
    logger.info "Reconnecting in #{delay}s (attempt #{@reconnect_attempts})"

    sleep(delay)
    connect
  end
end
```

### 4.2 Health Checks

```ruby
# lib/services/health_checker.rb
class HealthChecker
  def check_all
    {
      redis: check_redis,
      collectors: check_collectors,
      data_freshness: check_data_freshness,
      telegram: check_telegram
    }
  end

  def check_redis
    REDIS_POOL.with { |r| r.ping == "PONG" }
  rescue => e
    logger.error "Redis health check failed", error: e.message
    notify_admin("Redis is DOWN")
    false
  end

  def check_collectors
    collectors.map do |collector|
      {
        name: collector.name,
        status: collector.connected? ? "UP" : "DOWN",
        last_update: collector.last_update_at
      }
    end
  end

  def check_data_freshness
    # Проверка что цены обновлялись в последние 60 сек
    symbols = redis.keys("arb:price:*")
    stale_count = symbols.count do |key|
      ttl = redis.ttl(key)
      ttl < 0 || ttl > 60  # Expired или слишком старый
    end

    if stale_count > symbols.size * 0.1  # >10% stale
      notify_admin("#{stale_count} symbols have stale data")
    end
  end
end

# Запуск каждые 60 сек
Thread.new do
  loop do
    sleep 60
    HealthChecker.new.check_all
  end
end
```

### 4.3 Error Handling (категории)

```ruby
# Recoverable errors (retry)
- Network timeouts → Retry with backoff
- WebSocket disconnect → Reconnect
- Redis connection lost → Reconnect pool
- API rate limit → Wait and retry

# Non-recoverable errors (skip)
- Invalid API response format → Log + skip
- Symbol not found in mapping → Skip + log
- Blacklisted symbol → Skip silently

# Critical errors (alert admin)
- Redis unavailable >5 minutes
- All collectors down
- No price updates >10 minutes
- Config file corrupted
```

### 4.4 Graceful Shutdown

```ruby
# bin/scanner
trap('INT') do
  logger.info "Received INT signal, shutting down gracefully..."
  orchestrator.shutdown
  exit 0
end

# lib/orchestrator.rb
def shutdown
  logger.info "Shutting down orchestrator..."

  # 1. Stop accepting new price updates
  @price_engine.stop

  # 2. Close all WebSocket connections
  @collectors.each(&:close)

  # 3. Flush pending alerts
  @alert_manager.flush

  # 4. Save stats to Redis
  save_stats

  # 5. Close Redis connections
  REDIS_POOL.shutdown { |conn| conn.quit }

  logger.info "Shutdown complete"
end
```

---

## 5. МОНИТОРИНГ И ЛОГИРОВАНИЕ

### 5.1 Логирование

```ruby
# config/application.rb
SemanticLogger.default_level = :info
SemanticLogger.add_appender(
  file_name: 'log/arbitrage.log',
  formatter: :json,  # Structured logging
  level: :info
)

# Console appender для разработки
if ENV['RACK_ENV'] == 'development'
  SemanticLogger.add_appender(io: $stdout, formatter: :color)
end

# Ротация логов
# - Ежедневная ротация
# - Хранение 7 дней
# - Gzip старых логов
```

**Примеры логов:**

```json
{
  "timestamp": "2025-12-16T10:30:45.123Z",
  "level": "info",
  "name": "SpreadEngine",
  "message": "Spread detected",
  "payload": {
    "symbol": "PEPE/USDT",
    "spread_percent": 5.23,
    "dex_price": 0.00001100,
    "futures_price": 0.00001157,
    "venue_low": "Jupiter",
    "venue_high": "MEXC Futures"
  }
}
```

### 5.2 Метрики (опционально - Prometheus)

```ruby
# gem 'prometheus-client'

# Счетчики
prices_processed_total = Prometheus::Counter.new(
  :prices_processed_total,
  docstring: 'Total price updates processed',
  labels: [:venue]
)

spreads_detected_total = Prometheus::Counter.new(
  :spreads_detected_total,
  docstring: 'Total spreads detected',
  labels: [:symbol]
)

alerts_sent_total = Prometheus::Counter.new(
  :alerts_sent_total,
  docstring: 'Total alerts sent'
)

# Гистограммы (latency)
api_latency = Prometheus::Histogram.new(
  :api_latency_seconds,
  docstring: 'API call latency',
  labels: [:api_name],
  buckets: [0.1, 0.5, 1, 2, 5]
)

# Gauge (текущее состояние)
active_symbols = Prometheus::Gauge.new(
  :active_symbols,
  docstring: 'Number of symbols being tracked'
)
```

### 5.3 Alerting на проблемы

```ruby
# lib/services/system_alerter.rb
class SystemAlerter
  ADMIN_CHAT_ID = ENV['ADMIN_TELEGRAM_CHAT_ID']

  def alert(severity, message)
    emoji = case severity
            when :critical then "🚨"
            when :warning then "⚠️"
            when :info then "ℹ️"
            end

    telegram_bot.send_message(
      chat_id: ADMIN_CHAT_ID,
      text: "#{emoji} #{severity.upcase}: #{message}"
    )
  end
end

# Примеры использования:
SystemAlerter.alert(:critical, "Redis connection lost")
SystemAlerter.alert(:warning, "MEXC collector disconnected (attempt 3/10)")
SystemAlerter.alert(:info, "Successfully reconnected to Bybit")
```

### 5.4 Daily Summary

```ruby
# lib/services/daily_summary.rb
class DailySummary
  def send
    stats = {
      alerts_sent: redis.get('arb:stats:alerts_sent_24h').to_i,
      uptime_percent: calculate_uptime,
      top_symbols: top_symbols_by_alerts(5),
      avg_spread: calculate_avg_spread,
      collectors_status: collectors_health
    }

    message = format_summary(stats)
    telegram_bot.send_message(chat_id: ADMIN_CHAT_ID, text: message)

    # Reset daily counters
    redis.del('arb:stats:alerts_sent_24h')
  end

  def format_summary(stats)
    <<~MSG
      📊 Daily Summary (#{Date.today})

      Alerts sent: #{stats[:alerts_sent]}
      Uptime: #{stats[:uptime_percent]}%
      Avg spread: #{stats[:avg_spread]}%

      Top symbols:
      #{stats[:top_symbols].map { |s, c| "  #{s}: #{c} alerts" }.join("\n")}

      Collectors:
      #{stats[:collectors_status].map { |c| "  #{c[:name]}: #{c[:status]}" }.join("\n")}
    MSG
  end
end

# Запуск в 00:00 UTC каждый день
# Можно использовать cron или rufus-scheduler
```

---

## 6. БЕЗОПАСНОСТЬ

### 6.1 API ключи и секреты

**Хранение (Development):**
```bash
# .env файл (НЕ коммитить в git!)
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=123456789
REDIS_URL=redis://localhost:6379/0
```

**Хранение (Production):**
```bash
# Варианты:
1. AWS Secrets Manager
2. HashiCorp Vault
3. Environment variables (systemd EnvironmentFile)
4. Encrypted credentials (Rails-style)

# Пример systemd:
[Service]
EnvironmentFile=/etc/arbitrage-scanner/secrets.env
```

**Ротация:**
```ruby
# Telegram bot token rotation:
# 1. BotFather → /revoke → новый token
# 2. Update .env
# 3. Restart service

# Рекомендуется: каждые 90 дней
```

### 6.2 Telegram Bot Security

```ruby
# lib/services/telegram_bot.rb
class TelegramBot
  ALLOWED_CHAT_IDS = ENV['TELEGRAM_CHAT_ID'].split(',').map(&:to_i)

  def authorized?(message)
    ALLOWED_CHAT_IDS.include?(message.chat.id)
  end

  def handle_message(message)
    unless authorized?(message)
      logger.warn "Unauthorized access attempt", chat_id: message.chat.id
      return
    end

    # Rate limiting
    if rate_limited?(message.from.id)
      bot.send_message(
        chat_id: message.chat.id,
        text: "Too many requests, please wait"
      )
      return
    end

    # Process command
    process_command(message)
  end

  # Max 10 commands per minute per user
  def rate_limited?(user_id)
    key = "arb:telegram:ratelimit:#{user_id}"
    count = redis.incr(key)
    redis.expire(key, 60) if count == 1
    count > 10
  end
end
```

### 6.3 Redis Security

```bash
# redis.conf (production)
requirepass YOUR_STRONG_PASSWORD_HERE
bind 127.0.0.1  # или VPC internal IP
protected-mode yes

# Отключить опасные команды:
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG "CONFIG_abc123"
rename-command SHUTDOWN "SHUTDOWN_abc123"
```

### 6.4 Защита от инъекций

```ruby
# Symbol normalization - whitelist символов
def normalize_symbol(raw_symbol)
  # Разрешены только: A-Z, 0-9, /, -
  raw_symbol.gsub(/[^A-Z0-9\/-]/, '')
end

# JSON parsing - безопасный парсер
Oj.load(json_string, mode: :strict)  # Не исполняет код

# Redis keys - escaping
def redis_key(symbol)
  "arb:price:#{symbol.gsub(':', '_')}"  # Экранируем :
end
```

---

## 7. РАЗВЕРТЫВАНИЕ

### 7.1 Требования к серверу

**Минимальные:**
- OS: Ubuntu 22.04 LTS
- RAM: 2GB
- CPU: 2 cores
- Disk: 20GB SSD
- Network: 100 Mbps, <100ms latency к биржам

**Рекомендуемые (Production):**
- RAM: 4GB
- CPU: 4 cores
- Disk: 50GB SSD (для логов)
- Network: 1 Gbps, <50ms latency

**Провайдеры:**
- Hetzner VPS: €5-20/мес (отличный latency к EU биржам)
- DigitalOcean: $12-24/мес
- AWS/GCP: дороже, но больше сервисов

### 7.2 Установка

```bash
# 1. Установка Ruby
sudo apt update
sudo apt install -y build-essential git curl

# Через rbenv
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc

rbenv install 3.2.2
rbenv global 3.2.2

# 2. Установка Redis
sudo apt install -y redis-server
sudo systemctl enable redis-server
sudo systemctl start redis-server

# 3. Clone проекта
git clone https://github.com/youruser/crypto-arbitrage-scanner.git
cd crypto-arbitrage-scanner

# 4. Установка зависимостей
bundle install

# 5. Конфигурация
cp .env.example .env
nano .env  # Заполнить ключи

# 6. Проверка
bin/setup
```

### 7.3 Конфигурация (.env.example)

```bash
# .env.example

# Telegram
TELEGRAM_BOT_TOKEN=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
TELEGRAM_CHAT_ID=123456789

# Redis
REDIS_URL=redis://localhost:6379/0

# Настройки (опционально, есть дефолты)
MIN_SPREAD_PERCENT=2.0
MIN_LIQUIDITY_USD=500000
MIN_VOLUME_24H_DEX=200000
MIN_VOLUME_24H_FUTURES=200000
ALERT_COOLDOWN_SECONDS=300

# Мониторинг (опционально)
ADMIN_TELEGRAM_CHAT_ID=987654321

# Логирование
LOG_LEVEL=info  # debug | info | warn | error
```

### 7.4 SystemD Service

```ini
# /etc/systemd/system/arbitrage-scanner.service

[Unit]
Description=Crypto Arbitrage Scanner
After=network.target redis.service
Requires=redis.service

[Service]
Type=simple
User=scanner
Group=scanner
WorkingDirectory=/opt/arbitrage-scanner
EnvironmentFile=/opt/arbitrage-scanner/.env

ExecStart=/home/scanner/.rbenv/shims/ruby /opt/arbitrage-scanner/bin/scanner
ExecStop=/bin/kill -INT $MAINPID

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arbitrage-scanner

# Limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

**Использование:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable arbitrage-scanner
sudo systemctl start arbitrage-scanner
sudo systemctl status arbitrage-scanner

# Логи
journalctl -u arbitrage-scanner -f
```

### 7.5 Мониторинг Production

```bash
# Логи приложения
tail -f /opt/arbitrage-scanner/log/arbitrage.log

# SystemD журналы
journalctl -u arbitrage-scanner -f --since "10 minutes ago"

# Redis мониторинг
redis-cli INFO stats
redis-cli DBSIZE
redis-cli --latency

# Ресурсы сервера
htop
iotop
nethogs  # Network usage
```

---

## 8. ТЕСТИРОВАНИЕ

### 8.1 Unit тесты (RSpec)

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:suite) do
    # Setup test Redis DB
    REDIS_TEST = Redis.new(url: 'redis://localhost:6379/15')
  end

  config.after(:each) do
    REDIS_TEST.flushdb
  end
end

# spec/services/symbol_mapper_spec.rb
RSpec.describe SymbolMapper do
  describe '#normalize' do
    it 'converts BTCUSDT to BTC/USDT' do
      expect(SymbolMapper.normalize('BTCUSDT')).to eq('BTC/USDT')
    end

    it 'removes futures suffixes' do
      expect(SymbolMapper.normalize('BTC-PERP')).to eq('BTC/USD')
    end

    it 'handles stablecoins' do
      expect(SymbolMapper.normalize('BTCBUSD')).to eq('BTC/USDT')
    end
  end
end

# Цель: 80%+ code coverage
```

### 8.2 Integration тесты

```ruby
# spec/integration/arbitrage_flow_spec.rb
RSpec.describe 'Arbitrage Flow' do
  it 'detects spread and sends alert', :vcr do
    # Setup
    orchestrator = Orchestrator.new
    telegram_spy = spy('TelegramBot')
    allow(orchestrator).to receive(:telegram_bot).and_return(telegram_spy)

    # Simulate price updates
    orchestrator.price_engine.update(
      symbol: 'PEPE/USDT',
      venue: 'Jupiter',
      price: 0.00001100,
      metadata: { liquidity_usd: 850000 }
    )

    orchestrator.price_engine.update(
      symbol: 'PEPE/USDT',
      venue: 'MEXC Futures',
      price: 0.00001157
    )

    # Expect
    expect(telegram_spy).to have_received(:send_alert)
      .with(hash_including(symbol: 'PEPE/USDT', spread_percent: 5.18))
  end
end
```

### 8.3 Manual QA Checklist

```markdown
## MVP QA Checklist

### Сбор данных
- [ ] MEXC Futures WebSocket подключается
- [ ] Bybit Futures WebSocket подключается
- [ ] Jupiter API возвращает цены
- [ ] DexScreener API возвращает ликвидность
- [ ] Цены обновляются в Redis (TTL 60s)

### Маппинг токенов
- [ ] Jupiter Token List загружается при старте
- [ ] Symbol → contract mapping работает
- [ ] Коллизии (одинаковые тикеры) обрабатываются
- [ ] Fallback на DexScreener работает

### Фильтрация
- [ ] Спред <2% игнорируется
- [ ] Ликвидность <$500k игнорируется
- [ ] Объем <$200k игнорируется
- [ ] Blacklist работает
- [ ] Спред >50% отфильтровывается

### Алерты
- [ ] Формат алерта соответствует ТЗ
- [ ] Ссылки на Jupiter/DexScreener работают
- [ ] Cooldown 5 минут работает
- [ ] Алерты приходят в Telegram <5 сек

### Telegram команды
- [ ] /status показывает статистику
- [ ] /top 10 показывает спреды
- [ ] /threshold 3.5 меняет порог
- [ ] /blacklist add/remove работает
- [ ] /venues показывает биржи

### Надежность
- [ ] Reconnect после WebSocket disconnect
- [ ] Graceful shutdown (SIGINT)
- [ ] Логи пишутся корректно
- [ ] Health check работает

### Производительность
- [ ] 200+ пар отслеживается
- [ ] Latency алерта <5 сек
- [ ] Memory usage <500MB
- [ ] CPU usage <50%
```

---

## 9. ПОЭТАПНЫЙ ПЛАН РАЗРАБОТКИ

### 9.1 MVP Phase 1 (2-3 недели)

**Критерии готовности:**
✅ Система работает стабильно 24/7
✅ Обнаруживает арбитраж DEX ↔ Futures
✅ Отправляет алерты в Telegram <5 сек
✅ Минимальный набор фильтров работает

**Список фичей:**

| # | Задача | Время | Приоритет |
|---|--------|-------|-----------|
| 1 | Jupiter Collector (REST polling) | 3 дня | КРИТИЧНО |
| 2 | Token Mapping Service (symbol → contract) | 2 дня | КРИТИЧНО |
| 3 | DexScreener Integration (ликвидность) | 2 дня | КРИТИЧНО |
| 4 | Обновить SpreadEngine (фильтры, направление) | 2 дня | ВЫСОКИЙ |
| 5 | Обновить формат алерта (ссылки, метрики) | 1 день | ВЫСОКИЙ |
| 6 | Тесты (SymbolMapper, SpreadEngine, integration) | 3 дня | ВЫСОКИЙ |
| 7 | Документация (README.md) | 1 день | СРЕДНИЙ |
| 8 | Deployment (SystemD service) | 1 день | СРЕДНИЙ |

**Итого:** ~15 рабочих дней

---

### 9.2 MVP Phase 2 (+2 недели)

**Добавленные фичи:**

| # | Задача | Время | Приоритет |
|---|--------|-------|-----------|
| 9 | Gate.io Futures Collector | 1 день | СРЕДНИЙ |
| 10 | OKX Futures Collector (уже есть) | - | - |
| 11 | Binance Futures (уже есть) | - | - |
| 12 | Фильтры: network, age, direction | 2 дня | СРЕДНИЙ |
| 13 | Health Checker + System Alerts | 2 дня | СРЕДНИЙ |
| 14 | Daily Summary в Telegram | 1 день | НИЗКИЙ |
| 15 | Prometheus Metrics (опционально) | 3 дня | НИЗКИЙ |
| 16 | Grafana Dashboard (опционально) | 2 дня | НИЗКИЙ |

**Итого:** +11 дней

---

### 9.3 Post-MVP (+4 недели)

**Расширения:**

| # | Задача | Время | Приоритет |
|---|--------|-------|-----------|
| 17 | EVM сети поддержка (Ethereum, BSC) | 5 дней | СРЕДНИЙ |
| 18 | GoPlus интеграция (безопасность) | 3 дня | СРЕДНИЙ |
| 19 | Статус депозита/вывода CEX | 4 дня | НИЗКИЙ |
| 20 | PostgreSQL для истории спредов | 5 дней | НИЗКИЙ |
| 21 | Мониторинг изменения спреда (подписки) | 3 дня | НИЗКИЙ |
| 22 | Web Dashboard (Sinatra + Stimulus) | 7 дней | НИЗКИЙ |

**Итого:** +27 дней

---

## 10. КРИТЕРИИ ПРИЕМКИ MVP

### 10.1 Функциональные критерии

- [x] Система получает список фьючерсов с MEXC и Bybit
- [x] Для каждого фьючерса находит соответствующий токен на Solana (Jupiter Token List)
- [x] Получает цены с Jupiter API
- [x] Обогащает данными с DexScreener (ликвидность, объемы)
- [x] Расчет спреда: `(futures - dex) / dex * 100`
- [x] Фильтрация:
  - Спред ≥2%
  - Ликвидность ≥$500k
  - Объем DEX ≥$200k
  - Объем Futures ≥$200k
  - Спред ≤50% (реалистичный лимит)
- [x] Алерт содержит:
  - Название монеты, сеть, спред, направление
  - Цены на DEX и Futures
  - Ликвидность, объемы 24ч
  - Ссылки на Jupiter, DexScreener, Futures биржу
  - Адрес контракта
- [x] Telegram команды работают: /status, /top, /threshold, /blacklist
- [x] Cooldown 5 минут между алертами на один символ

### 10.2 Технические критерии

- [x] Цены обновляются с задержкой <5 сек
- [x] Задержка алерта от обнаружения спреда <5 сек
- [x] WebSocket collectors автоматически reconnect при disconnect
- [x] Graceful shutdown при SIGINT
- [x] Логи структурированные (JSON) и читаемые
- [x] Redis TTL настроен (60s для цен, 5m для метаданных)
- [x] Rate limiting для DexScreener API (5 req/sec)
- [x] Кэширование Jupiter Token List (обновление 1x/час)

### 10.3 Производительность

- [x] Отслеживание ≥200 торговых пар одновременно
- [x] Memory usage <500MB (single instance)
- [x] CPU usage <50% (2 cores, idle ~20%)
- [x] Latency алерта: 95th percentile <5 сек

### 10.4 Надежность

- [x] Uptime >95% за неделю
- [x] Ложные алерты <10% (разные токены с одним тикером)
- [x] Zero downtime при перезапуске Redis (reconnect pool)
- [x] Health check endpoint отвечает на системные проверки

---

## 11. ИЗВЕСТНЫЕ ОГРАНИЧЕНИЯ

### 11.1 API Rate Limits

| API | Бесплатный лимит | Платный план | Решение в MVP |
|-----|------------------|--------------|---------------|
| DexScreener | 300 req/min | Нет платного | Кэш 5 мин |
| Jupiter Quote | Нет публичного | - | Soft limit 1 req/sec |
| GoPlus | 200 req/day | $199/мес (10k/day) | НЕ используется в MVP |
| CoinGecko | 10-50 req/min | $129/мес (500/min) | НЕ используется в MVP |

### 11.2 Latency DEX vs CEX

**Проблема:**
- CEX WebSocket: realtime updates (~100ms latency)
- Jupiter REST polling: 2-5 сек интервал

**Следствие:**
- Спреды могут быть уже неактуальны к моменту алерта
- Арбитражники с прямым WebSocket доступом будут быстрее

**Решение:**
- Добавить timestamp в алерт: "Spread as of 3 seconds ago"
- Рекомендовать пользователям быструю проверку цен перед входом

### 11.3 Токены без маппинга

**Проблема:**
- Новые токены могут отсутствовать в Jupiter Token List
- Обновление списка: 1 раз в час

**Решение:**
- Fallback на DexScreener Search API
- Кэширование результатов поиска (7 дней)

**Ограничение:**
- Токены, появившиеся <1 часа назад, могут быть пропущены до обновления списка

### 11.4 Скам-токены (фильтрация)

**Проблема:**
- Множество скамов с тикерами известных монет
- Пример: 100+ "PEPE" токенов на Solana

**Фильтрация:**
1. Ликвидность ≥$500k (отсекает 95% скамов)
2. Объем 24ч ≥$200k
3. Спред ≤50% (разные токены обычно имеют огромные расхождения)

**Остаточный риск:**
- Хорошо профинансированные скамы (honeypot с высокой ликвидностью)
- Решение Post-MVP: GoPlus интеграция

---

## 12. РИСКИ И МИТИГАЦИЯ

### 12.1 Риск: API недоступность

| API | Риск | Вероятность | Митигация |
|-----|------|-------------|-----------|
| Jupiter | Downtime | Низкая | Fallback: прямые вызовы Raydium/Orca |
| DexScreener | Rate limit | Средняя | Кэш 5 мин + priority queue |
| MEXC WebSocket | Disconnect | Средняя | Автоматический reconnect |

### 12.2 Риск: Rate limit превышение

**Сценарий:**
- DexScreener: 300 req/min
- 500 токенов * 1 req/token = 500 req
- 500 req / 60 сек = 8.3 req/sec > 5 req/sec лимит

**Митигация:**
1. Кэширование ликвидности 5 минут
2. Priority queue:
   - Высокий приоритет: новые токены (<24h), spread >5%
   - Низкий приоритет: старые токены, малые спреды
3. Обновление только токенов, которые активно торгуются

### 12.3 Риск: Ложные алерты (разные токены)

**Сценарий:**
- PEPE на Solana: $0.000011
- PEPE скам на Solana: $0.000001
- MEXC торгует легитимный PEPE
- Система находит "спред" 1000%+

**Митигация:**
1. ✅ Фильтр ликвидности ($500k+)
2. ✅ Максимальный реалистичный спред (50%)
3. ✅ Проверка адреса контракта через Jupiter Token List
4. 🔜 Post-MVP: GoPlus проверка (honeypot detection)

**Ожидаемый результат:**
- <10% ложных алертов в MVP
- <5% в Post-MVP с GoPlus

### 12.4 Риск: Арбитраж невозможен (практически)

**Сценарии:**
1. **Депозит закрыт на CEX**
   - Невозможен хедж-арбитраж (buy DEX + short CEX)
   - Решение Post-MVP: проверка статуса депозита

2. **Высокий slippage на DEX**
   - Ликвидность $500k, но сделка на $10k = 5% slippage
   - Решение: Указывать "рекомендуемый размер позиции" в алерте

3. **Tax на покупку/продажу DEX токена**
   - Buy tax 10% + Sell tax 10% = спред нужен >20%
   - Решение Post-MVP: GoPlus API (tax detection)

4. **CEX delisting announcement**
   - Фьючерс торгуется с дисконтом перед закрытием
   - Решение: Мониторинг анонсов бирж (сложно)

**Митигация общая:**
- Disclaimer в алертах: "Всегда проверяйте возможность исполнения"
- Ссылки на GoPlus/DexScreener для верификации

---

## ПРИЛОЖЕНИЯ

### A. API Endpoints (Reference)

```markdown
## Jupiter API

### Quote
GET https://quote-api.jup.ag/v6/quote
Params: inputMint, outputMint, amount, slippageBps

### Token List
GET https://token.jup.ag/all

### Price API (простой способ)
GET https://price.jup.ag/v4/price
Params: ids (comma-separated contract addresses)
Response: { data: { "7GCihg...": { price: 0.000011 } } }

---

## DexScreener API

### Token Info
GET https://api.dexscreener.com/latest/dex/tokens/{address}

### Search
GET https://api.dexscreener.com/latest/dex/search
Params: q={symbol}

---

## MEXC Futures API

### WebSocket
wss://contract.mexc.com/edge
Subscribe: {"method":"sub.deal","param":{"symbol":"PEPE_USDT"}}

### REST Ticker
GET https://contract.mexc.com/api/v1/contract/ticker

---

## Bybit API

### WebSocket
wss://stream.bybit.com/v5/public/linear
Subscribe: {"op":"subscribe","args":["tickers.PEPEUSDT"]}

### REST Tickers
GET https://api.bybit.com/v5/market/tickers
Params: category=linear
```

---

### B. Redis Schema (Full)

```ruby
# === PRICES ===
arb:price:PEPE/USDT = Hash { "MEXC Futures" => "0.00001157", "Jupiter" => "0.00001100" }
TTL: 60 seconds

# === METADATA ===
arb:metadata:PEPE/USDT = Hash {
  "contract_address" => "7GCihgDB...",
  "network" => "solana",
  "liquidity_usd" => "850000",
  "volume_24h" => "320000",
  "pool_age_days" => "12",
  "dexscreener_url" => "https://dexscreener.com/solana/..."
}
TTL: 5 minutes (300 seconds)

# === TOKEN MAPPING ===
arb:contract:PEPE = "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr"
TTL: 24 hours (86400 seconds)

# === ALERT COOLDOWN ===
arb:alert:cooldown:PEPE/USDT = 1702123456 (unix timestamp)
TTL: 300 seconds (5 minutes)

# === CONFIG ===
arb:config:threshold = "2.0"
arb:config:cooldown = "300"
arb:config:min_liquidity = "500000"
arb:config:min_volume_dex = "200000"
arb:config:min_volume_futures = "200000"
arb:blacklist = Set ["SCAM", "RUGPULL"]
NO TTL (persistent)

# === STATS ===
arb:stats:alerts_sent_24h = 18
arb:stats:uptime_start = 1702000000
arb:stats:top_symbols = ZSet { "PEPE/USDT" => 5, "WIF/USDT" => 3 }
NO TTL (reset daily by cron)

# === RATE LIMITING ===
arb:ratelimit:dexscreener:tokens = 295  # remaining tokens
arb:ratelimit:dexscreener:refill_at = 1702123460
TTL: 60 seconds

arb:ratelimit:jupiter:tokens = 58
TTL: 60 seconds

# === CACHE (GoPlus, CoinGecko - Post-MVP) ===
arb:goplus:7GCihgDB... = Hash { "is_honeypot" => false, "buy_tax" => 0, "sell_tax" => 0 }
TTL: 30 days

arb:coingecko:pepe = Hash { "rank" => 458, "url" => "https://coingecko.com/..." }
TTL: 7 days
```

---

### C. Полный шаблон алерта

```
🔥 ARBITRAGE OPPORTUNITY: {SYMBOL} | {NETWORK}

📊 Spread: {SPREAD_PERCENT}% ({DIRECTION})
💰 Profit potential: ~${PROFIT_EST} per $10k position

Strategy: {STRATEGY_TYPE}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💹 PRICES:
🟢 DEX ({DEX_NAME}):     ${DEX_PRICE}
🔴 Futures ({CEX_NAME}): ${FUTURES_PRICE}
📈 Delta:                ${PRICE_DELTA}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 METRICS:
💧 Liquidity:     ${LIQUIDITY_USD}
📊 Volume (DEX):  ${VOLUME_DEX_24H}
📊 Volume (Fut):  ${VOLUME_FUTURES_24H}
🕐 Pool age:      {POOL_AGE_DAYS} days

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔗 LINKS:
• Trade DEX: {JUPITER_SWAP_URL}
• Trade Futures: {FUTURES_URL}
• Chart: {DEXSCREENER_URL}

📄 Contract: {CONTRACT_ADDRESS}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⏰ Detected: {TIMESTAMP}
⚠️ Verify liquidity & taxes before trading!
```

**Пример заполненный:**
```
🔥 ARBITRAGE OPPORTUNITY: PEPE | Solana

📊 Spread: +5.18% (SHORT)
💰 Profit potential: ~$518 per $10k position

Strategy: HEDGE (Buy DEX + Short Futures)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💹 PRICES:
🟢 DEX (Jupiter):     $0.00001100
🔴 Futures (MEXC):    $0.00001157
📈 Delta:             $0.00000057

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 METRICS:
💧 Liquidity:     $850,000
📊 Volume (DEX):  $320,000
📊 Volume (Fut):  $5,200,000
🕐 Pool age:      12 days

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔗 LINKS:
• Trade DEX: https://jup.ag/swap/SOL-7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr
• Trade Futures: https://futures.mexc.com/exchange/PEPE_USDT
• Chart: https://dexscreener.com/solana/7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr

📄 Contract: 7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⏰ Detected: 2025-12-16 10:30:45 UTC
⚠️ Verify liquidity & taxes before trading!
```

---

### D. SystemD Unit File (Full)

```ini
# /etc/systemd/system/arbitrage-scanner.service

[Unit]
Description=Crypto Arbitrage Scanner DEX-Futures
Documentation=https://github.com/youruser/crypto-arbitrage-scanner
After=network-online.target redis.service
Wants=network-online.target
Requires=redis.service

[Service]
Type=simple

# User/Group
User=scanner
Group=scanner

# Working Directory
WorkingDirectory=/opt/arbitrage-scanner

# Environment
Environment="RACK_ENV=production"
Environment="RAILS_ENV=production"
EnvironmentFile=/opt/arbitrage-scanner/.env

# Execution
ExecStartPre=/usr/bin/env bundle check
ExecStart=/home/scanner/.rbenv/shims/bundle exec ruby /opt/arbitrage-scanner/bin/scanner
ExecStop=/bin/kill -INT $MAINPID
ExecReload=/bin/kill -HUP $MAINPID

# Restart policy
Restart=always
RestartSec=10
StartLimitInterval=5min
StartLimitBurst=4

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arbitrage-scanner

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/arbitrage-scanner/log /opt/arbitrage-scanner/tmp

# Resource Limits
LimitNOFILE=65536
LimitNPROC=512
MemoryLimit=1G
CPUQuota=200%

# Hardening (optional, может сломать некоторые gems)
# ProtectKernelTunables=true
# ProtectControlGroups=true
# RestrictRealtime=true

[Install]
WantedBy=multi-user.target
```

---

## CHANGELOG

**v2.0 (2025-12-16)**
- 🆕 Полностью переработанное ТЗ
- 🆕 Добавлены разделы: Сопоставление токенов, Rate Limiting, Безопасность, Развертывание
- 🆕 Детальные API endpoints и примеры
- 🆕 Полная Redis schema
- 🆕 Критерии приемки и план тестирования
- 🆕 Риски и митигация
- ✏️ Уточнены нечеткие требования (возраст токена, коллизии тикеров)
- ✏️ Изменены приоритеты (2-3 биржи в MVP вместо 12)
- ✏️ Заменены источники данных (DexScreener вместо 1inch, CoinGecko вместо CMC)
- ❌ Убраны нереалистичные фичи из MVP (GoPlus, EVM сети, история спредов)

**v1.0 (Original)**
- Базовое ТЗ без технических деталей

---

## АВТОРЫ

**Product Owner:** [Your Name]
**Technical Lead:** [Your Name]
**Contributors:** Claude Code (AI Assistant)

---

## ЛИЦЕНЗИЯ

Proprietary - All Rights Reserved

---

**КОНЕЦ ДОКУМЕНТА**
