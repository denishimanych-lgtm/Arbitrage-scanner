# Crypto Arbitrage Bot v2 - Technical Requirements

## 1. ЦЕЛЬ И ПОДХОД

### 1.1 Цель
Проверить гипотезы о существовании арбитражных возможностей через форвард-тест:
- Существуют ли заявленные спреды?
- Как часто появляются?
- Сходятся ли?
- Какой реальный net PnL после всех издержек?

### 1.2 Подход
- Все стратегии — гипотезы до подтверждения данными
- Логируем всё для анализа
- Торгуем малыми суммами
- Решения принимаем по результатам

### 1.3 Статус цифр в документе
Все количественные оценки (%, доходность, частота) — ГИПОТЕЗЫ.
Нет бэктеста на tick-level данных. Форвард-тест покажет реальные цифры.

---

## 2. СТРАТЕГИИ

### 2.1 SPATIAL ARBITRAGE (хеджированный)

#### Источник edge
Кто платит:
- Ретейл трейдеры исполняющие market orders на одной бирже
- Арбитражёры без хеджа (берут price risk)
- Market makers ребалансирующие inventory между биржами

Почему они не арбитражат сами:

| Участник | Причина |
|----------|---------|
| Ретейл | Нет аккаунтов на нескольких биржах, нет капитала для хеджа |
| Фонды | Compliance запрещает некоторые биржи, AML процедуры |
| MM | Арбитраж — не их бизнес, inventory risk — их издержка |

Механизм: MM на бирже A с перекосом inventory снижает цену. На бирже B цена не изменилась. Спред = inventory cost который MM готов платить.

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Risk-premium capture |
| Основной риск | Spread divergence (расширение вместо схождения) |
| Вторичный | Counterparty, Liquidity |
| Удержание при движении цены | Да (хеджировано) |

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Спред расширяется | ? | Floating loss | Стоп по расширению или время |
| Заморозка вывода | Редко, критично | Потеря хеджа | Лимит 20% на биржу |
| Делистинг токена | Редко | Gap при закрытии | Blacklist низколиквидных |
| ADL на futures | При экстремальной vol | Потеря хеджа | Не входить при высоком OI |
| Ликвидация шорта | При недостаточной марже | Потеря в худший момент | Плечо max 3x |

#### Экономика (ГИПОТЕЗА)
```
Gross edge (спред 5%):         5.00%
- Комиссии вход (2 ноги):     -0.20%
- Комиссии выход (2 ноги):    -0.20%
- Funding (perp, 24ч):        -0.05%
- Slippage вход:              -0.30%
- Slippage выход:             -0.30%
- Неполное схождение:         -0.50%
================================
Net (оценка):                  3.45%  ⚠️ Требует проверки форвард-тестом
```

#### Реализация

```ruby
class SpatialHedgedStrategy
  MIN_SPREAD_PCT = 3.0
  MAX_SPREAD_EXPANSION = 5.0  # Стоп если расширился на 5%
  MAX_HOLD_HOURS = 168        # 7 дней максимум

  def find_opportunities
    symbols = load_active_symbols

    symbols.each do |symbol|
      prices = fetch_all_venue_prices(symbol)

      # Все комбинации: spot↔futures, cex↔dex
      opportunities = calculate_spreads(prices)

      opportunities.each do |opp|
        next if opp[:spread_pct] < MIN_SPREAD_PCT
        next unless validate(opp)

        generate_alert(opp)
      end
    end
  end

  def validate(opp)
    checks = []

    # Свежесть данных
    checks << (opp[:price_age_ms] < 5000)

    # Ликвидность
    checks << (opp[:min_liquidity_usd] >= 5000)

    # Net spread после комиссий
    checks << (opp[:net_spread_pct] >= 0.5)

    # Shortable (если хедж)
    checks << venue_supports_short?(opp[:high_venue])

    checks.all?
  end

  def calculate_spreads(prices)
    results = []

    prices.keys.combination(2).each do |venue_a, venue_b|
      price_a, price_b = prices[venue_a], prices[venue_b]

      if price_a[:ask] < price_b[:bid]
        spread_pct = (price_b[:bid] - price_a[:ask]) / price_a[:ask] * 100
        results << {
          symbol: price_a[:symbol],
          low_venue: venue_a,
          high_venue: venue_b,
          spread_pct: spread_pct,
          net_spread_pct: spread_pct - estimate_costs(venue_a, venue_b)
        }
      end
    end

    results
  end
end
```

#### Формат алерта
```
🔥 HEDGED | ALPHA | 5.2%
━━━━━━━━━━━━━━━━━━━━━━━

📊 ПЛОЩАДКИ:
   🟢 LOW: Gate Spot — $0.557
   🔴 HIGH: Binance Futures — $0.586

💹 СПРЕД:
   Gross: 5.2%
   Net (оценка): 3.8%

💰 ЛИКВИДНОСТЬ:
   Gate asks: $45K в 1%
   Binance bids: $120K в 1%

⚠️ КЛАСС: Risk-premium capture
   Риск: spread divergence

✅ ДЕЙСТВИЕ:
   1️⃣ LONG ALPHA Gate Spot
   2️⃣ SHORT ALPHA Binance Futures

📝 ID: `hedge_abc123`
/taken hedge_abc123
```

---

### 2.2 SPATIAL ARBITRAGE (ручной)

#### Источник edge
Кто платит:
- Трейдеры которым нужна срочность (не могут ждать трансфер)
- Те кто боится price risk во время перевода

Почему не арбитражат сами:

| Участник | Причина |
|----------|---------|
| Ретейл | Страх price risk |
| Институционалы | Compliance не позволяет без хеджа |
| Боты | Большинство хеджируют |

Механизм: Вы принимаете price risk за время трансфера. Платят вам премию за этот риск.

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Speculative |
| Основной риск | Price move за время трансфера |
| Вторичный | Transfer delay, Deposit freeze |
| Удержание при движении цены | Нет — это и есть риск |

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Цена упала за трансфер | Каждая сделка (вероятностно) | -1% до -10% | Только быстрые сети, буфер |
| Депозит завис | 1-5% транзакций | Полная exposure | Проверка статуса ДО входа |
| Сеть перегружена | При волатильности | Задержка = больше risk | Не торговать при congestion |
| Спред закрылся | Часто | Profit → 0 | Входить только при spread > буфер |

#### Экономика (ГИПОТЕЗА)
```
Gross edge (спред 3%):         3.00%
- Комиссия покупка:           -0.10%
- Комиссия продажа:           -0.10%
- Network fee:                -0.05%
- Slippage:                   -0.20%
- Expected adverse move:      -0.42% (√2 × 0.3%/мин)
================================
Net (средняя оценка):          2.13%

Распределение (ГИПОТЕЗА):
- 70% сделок: +2-3%
- 20% сделок: 0 до +1%
- 10% сделок: -2% до -5%
```

#### Реализация

```ruby
class SpatialManualStrategy
  MIN_SPREAD_PCT = 2.0

  # Волатильность по активам (требует калибровки)
  VOLATILITY_PER_MIN = {
    'BTC' => 0.15,
    'ETH' => 0.20,
    'SOL' => 0.30,
    default: 0.25
  }

  # Время трансфера по сетям (минуты)
  TRANSFER_TIME = {
    'SOL' => 2,
    'ARB' => 3,
    'OP' => 3,
    'MATIC' => 7,
    'ETH' => 12,
    'BTC' => 30
  }

  def find_opportunities
    symbols = load_active_symbols

    symbols.each do |symbol|
      prices = fetch_spot_prices(symbol) # Только spot↔spot

      prices.keys.combination(2).each do |ex_a, ex_b|
        spread = calculate_spread(prices[ex_a], prices[ex_b])
        next unless spread

        # Проверяем что spread > safety buffer
        buffer = calculate_safety_buffer(symbol)
        next if spread[:spread_pct] < buffer

        # Проверяем deposit/withdraw
        network = find_best_network(ex_a, ex_b, symbol)
        next unless network && network[:enabled]

        generate_alert(spread, network)
      end
    end
  end

  def calculate_safety_buffer(symbol)
    vol = VOLATILITY_PER_MIN[symbol] || VOLATILITY_PER_MIN[:default]
    transfer_time = estimate_transfer_time(symbol)

    # Buffer = 3 × expected volatility за время трансфера
    Math.sqrt(transfer_time) * vol * 3
  end

  def find_best_network(ex_a, ex_b, symbol)
    networks_a = fetch_networks(ex_a, symbol)
    networks_b = fetch_networks(ex_b, symbol)

    common = networks_a.keys & networks_b.keys

    common
      .select { |n| networks_a[n][:withdraw_enabled] && networks_b[n][:deposit_enabled] }
      .min_by { |n| TRANSFER_TIME[n] || 999 }
      .then { |n| n ? { network: n, enabled: true, time: TRANSFER_TIME[n] } : nil }
  end
end
```

#### Формат алерта
```
⚠️ MANUAL | SOL | 3.2%
━━━━━━━━━━━━━━━━━━━━━━━

📊 ПЛОЩАДКИ:
   🟢 BUY: Kraken — $185.00
   🔴 SELL: Binance — $190.92

⏱ ТРАНСФЕР:
   Сеть: Solana (~2 мин)
   Withdraw: ✅
   Deposit: ✅

📊 РИСК:
   Волатильность: 0.3%/мин
   Safety buffer: 0.85%
   Spread 3.2% > Buffer ✅

⚠️ КЛАСС: Speculative
   Риск: price move за трансфер

✅ ДЕЙСТВИЕ:
   1️⃣ Купить SOL на Kraken
   2️⃣ Вывести (Solana network)
   3️⃣ Продать на Binance
   ⚡ Действовать быстро!

📝 ID: `manual_def456`
```

---

### 2.3 FUNDING RATE ARBITRAGE

#### Источник edge
Кто платит:
- Лонги с плечом (ретейл, дегены)
- Спекулянты на направление

Почему не арбитражат сами:

| Участник | Причина |
|----------|---------|
| Ретейл лонги | Хотят exposure к росту, хедж убивает upside |
| Фонды | Compliance может запрещать perps |
| Спекулянты | Арбитраж не их бизнес |

Механизм: Рынок перекошен в лонги → funding положительный → лонги платят шортам. Вы собираете премию, нейтрализуя price risk.

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Risk-premium capture |
| Основной риск | Funding flip (стал отрицательным) |
| Вторичный | Counterparty, ADL, Liquidation |
| Удержание при движении цены | Да (хеджировано) |

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Funding flip | Регулярно | Платите вместо получения | Выход при N периодов < 0 |
| ADL на шорте | При экстремальном росте | Потеря хеджа | Мониторинг OI, плечо ≤3x |
| Ликвидация | При недостаточной марже | Потеря позиции + fees | Консервативная маржа |
| Execution gap | При волатильности | Вход по худшей цене | Лимиты, не маркеты |

#### Экономика (ГИПОТЕЗА)
```
Средний funding (бычий рынок): 0.05-0.1% / 8ч
APR (gross): 50-100%

Минус:
- Комиссии открытия: 0.1-0.2%
- Периоды отрицательного funding: ?%
- Execution gap: ?%

Net APR: НЕИЗВЕСТЕН без форвард-теста
```

#### Реализация

```ruby
class FundingRateStrategy
  MIN_FUNDING_RATE = 0.03      # 0.03% за 8ч минимум для алерта
  MIN_FUNDING_SPREAD = 0.02   # Spread между биржами
  EXIT_THRESHOLD = 0.01       # Выход если funding < 0.01%
  NEGATIVE_PERIODS_EXIT = 3   # Выход после 3 отрицательных периодов

  def check_opportunities
    symbols = load_perp_symbols

    symbols.each do |symbol|
      rates = fetch_funding_rates_all_venues(symbol)

      # Алерт на высокий funding
      max_rate = rates.max_by(&:rate)
      if max_rate.rate >= MIN_FUNDING_RATE
        generate_funding_alert(symbol, rates)
      end

      # Алерт на cross-venue spread
      if rates.size >= 2
        spread = rates.max_by(&:rate).rate - rates.min_by(&:rate).rate
        if spread >= MIN_FUNDING_SPREAD
          generate_funding_spread_alert(symbol, rates, spread)
        end
      end
    end
  end

  def should_exit?(symbol, position)
    history = load_funding_history(symbol, periods: 10)

    # Выход если последние N периодов отрицательные
    recent = history.last(NEGATIVE_PERIODS_EXIT)
    return true if recent.all? { |r| r.rate < 0 }

    # Выход если текущий funding слишком низкий
    return true if history.last.rate < EXIT_THRESHOLD

    false
  end
end
```

#### Формат алерта
```
💰 FUNDING | ETH | 0.08%/8h
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 RATES:
   Binance:     0.080% (87% APR)
   Bybit:       0.065% (71% APR)
   OKX:         0.055% (60% APR)
   HyperLiquid: 0.095% (103% APR) ← MAX

📈 ИСТОРИЯ (7д):
   Средний: 0.05%
   Подряд положительный: 14 дней

💡 СТРАТЕГИЯ:
   LONG ETH Spot + SHORT ETH Perp

⚠️ КЛАСС: Risk-premium capture
   Риск: funding flip

📍 ВЫХОД:
   • Funding < 0.01%
   • 3 периода отрицательный

📝 ID: `fund_ghi789`
```

---

### 2.4 PERP DEX vs CEX FUNDING SPREAD (ГИПОТЕЗА)

#### Источник edge (НЕПРОВЕРЕННАЯ ГИПОТЕЗА)
Кто платит: Дегены на perp DEX (HyperLiquid, dYdX) — retail-heavy площадки

Почему не арбитражат сами:

| Участник | Причина |
|----------|---------|
| CEX MM | Сложность интеграции on-chain |
| Фонды | Не все могут работать с DeFi |
| Ретейл | Не мониторят spread CEX↔DEX |

Гипотеза: Perp DEX менее эффективны, funding может расходиться с CEX сильнее.

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Risk-premium capture |
| Основной риск | Smart contract risk на DEX |
| Вторичный | Ликвидность DEX, oracle manipulation |

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Smart contract exploit | Редко, катастрофично | Потеря всего на DEX | Лимит exposure на DEX |
| Oracle manipulation | Редко | Ликвидация по неверной цене | Мониторинг oracle health |
| Низкая ликвидность | Часто на альтах | Slippage, не выйти | Только топ пары |
| DEX downtime | Иногда | Не выйти вовремя | Мониторинг статуса |

#### Реализация

```ruby
class PerpDexFundingStrategy
  PERP_DEXES = [:hyperliquid, :dydx_v4, :vertex]
  CEX_PERPS = [:binance_futures, :okx_futures, :bybit_futures]

  MIN_CROSS_VENUE_SPREAD = 0.02  # 0.02% минимум spread

  def check_opportunities
    symbols = load_common_symbols

    symbols.each do |symbol|
      dex_rates = PERP_DEXES.filter_map { |d| fetch_funding(d, symbol) }
      cex_rates = CEX_PERPS.filter_map { |c| fetch_funding(c, symbol) }

      next if dex_rates.empty? || cex_rates.empty?

      best = find_best_spread(dex_rates, cex_rates)

      if best[:spread] >= MIN_CROSS_VENUE_SPREAD
        generate_alert(symbol, best)
      end
    end
  end

  def find_best_spread(dex_rates, cex_rates)
    max_spread = { spread: 0 }

    dex_rates.product(cex_rates).each do |dex, cex|
      spread = (dex.rate - cex.rate).abs

      if spread > max_spread[:spread]
        max_spread = {
          spread: spread,
          high: dex.rate > cex.rate ? dex : cex,
          low: dex.rate > cex.rate ? cex : dex,
          is_dex_higher: dex.rate > cex.rate
        }
      end
    end

    max_spread
  end
end
```

#### Формат алерта
```
🔥 FUNDING SPREAD | ETH | 0.04%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 CROSS-VENUE:
   HyperLiquid: 0.095%/8h (HIGH)
   Binance:     0.055%/8h (LOW)
   Spread:      0.040%/8h (43% APR)

💡 СТРАТЕГИЯ:
   LONG Binance Perp + SHORT HyperLiquid Perp

⚠️ КЛАСС: Risk-premium + Smart contract risk
   ⚠️ ГИПОТЕЗА — edge не подтверждён

📝 ID: `dexspread_jkl012`
```

---

### 2.5 STATISTICAL ARBITRAGE (Z-score)

#### Источник edge
Кто платит:
- Моментум-трейдеры (покупают растущее)
- Ретейл следующий за narratives
- Фонды с single-asset mandate

Почему не арбитражат сами:

| Участник | Причина |
|----------|---------|
| Ретейл | Не знают о коинтеграции |
| Моментум фонды | Их стратегия противоположна mean reversion |
| Крипто фонды | Часто single-asset mandate |

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Speculative (mean reversion bet) |
| Основной риск | Regime change — соотношение изменилось навсегда |
| Вторичный | Timing — отклонение дольше чем вы solvent |
| Удержание | Только до стоп-лосса |

⚠️ Это НЕ арбитраж. Это ставка на mean reversion.

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Regime change | ? | Стоп-лосс, -3-5% | Стоп по Z-score, рекалибровка |
| Пара расходится дальше | 15-30%? | Floating loss → стоп | Жёсткий стоп |
| Корреляция breakdown | При кризисах | Хедж не работает | Не торговать при высоком VIX |
| Ликвидность падает | При stress | Не выйти | Мониторинг обоих активов |

#### Экономика (ГИПОТЕЗА)
```
Из академической литературы (НЕ крипто, НЕ проверено):
- Win rate: 70-85%
- Avg win: +2-3%
- Avg loss: -3-5%
- Sharpe: 1.4-1.5

⚠️ Требует проверки на крипто парах
```

#### Реализация

```ruby
class StatArbStrategy
  PAIRS = [
    { a: 'BTC', b: 'ETH', name: 'BTC/ETH' },
    { a: 'SOL', b: 'ETH', name: 'SOL/ETH' },
    { a: 'LTC', b: 'BCH', name: 'LTC/BCH' },
    { a: 'LINK', b: 'UNI', name: 'LINK/UNI' }
  ]

  LOOKBACK_DAYS = 90
  ENTRY_ZSCORE = 2.0
  STOP_ZSCORE = 3.5
  EXIT_ZSCORE = 0.5

  def check_opportunities
    PAIRS.each do |pair|
      history = load_spread_history(pair, LOOKBACK_DAYS)
      next if history.size < 30

      current = calculate_current_spread(pair)
      stats = calculate_stats(history)
      zscore = (current - stats[:mean]) / stats[:std]

      if zscore.abs >= ENTRY_ZSCORE
        generate_alert(pair, zscore, stats, current)
      end

      # Логируем для анализа
      log_zscore(pair, zscore, current)
    end
  end

  def calculate_stats(history)
    mean = history.sum / history.size.to_f
    variance = history.map { |x| (x - mean)**2 }.sum / history.size
    std = Math.sqrt(variance)

    { mean: mean, std: std }
  end

  def calculate_current_spread(pair)
    price_a = get_price(pair[:a])
    price_b = get_price(pair[:b])

    price_b / price_a
  end
end
```

#### Формат алерта
```
📊 STAT ARB | BTC/ETH | Z = -2.7
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📈 АНАЛИЗ (90д):
   Средний: 24.1 ETH/BTC
   Текущий: 26.8 ETH/BTC
   Std Dev: 0.8
   Z-score: -2.7

💡 ИНТЕРПРЕТАЦИЯ:
   ETH "дешёвый" относительно BTC

⚠️ КЛАСС: SPECULATIVE
   ⚠️ Это ставка, НЕ арбитраж
   Риск: regime change

📍 УРОВНИ:
   Вход: Z = -2.7
   Стоп: Z = -3.5
   Тейк: Z = 0

✅ ДЕЙСТВИЕ:
   LONG ETH + SHORT BTC (равные USD)

📝 ID: `stat_mno345`
```

---

### 2.6 STABLECOIN DEPEG

#### Источник edge
Кто платит:
- Паникующие держатели (продают в убыток)
- Трейдеры которым срочно нужна ликвидность

Почему не арбитражат сами:

| Участник | Причина |
|----------|---------|
| Ретейл | Страх полного краха (LUNA/UST травма) |
| Фонды | Risk mandate не позволяет |
| MM | Не хотят counterparty risk на эмитента |

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Speculative (event-driven bet) |
| Основной риск | Стейбл не восстанавливается → полная потеря |
| Вторичный | Долгое восстановление |

⚠️ Это НЕ арбитраж. Это ставка на событие.

#### Failure cases

| Сценарий | Оценка частоты | Эффект | Действие |
|----------|----------------|--------|----------|
| Полный крах (UST) | Редко | -100% | Due diligence, стоп-лосс |
| Долгое восстановление | Средне | Capital lock | Position sizing |
| Регуляторный запрет | Низко | Делистинг | Мониторинг новостей |
| Cascading depeg | При системном кризисе | Несколько стейблов | Лимит общей exposure |

#### Реализация

```ruby
class StablecoinDepegStrategy
  STABLES = %w[USDT USDC DAI FRAX TUSD]
  DEPEG_ALERT_THRESHOLD = 0.99    # Алерт при < $0.99
  DEPEG_ENTRY_THRESHOLD = 0.97    # Вход при < $0.97
  STOP_LOSS_PCT = 0.10            # Стоп -10% от входа

  def monitor
    STABLES.each do |stable|
      prices = fetch_prices_all_venues(stable)
      avg_price = prices.values.map { |p| p[:last] }.sum / prices.size

      if avg_price < DEPEG_ALERT_THRESHOLD
        curve_data = fetch_curve_balance(stable) rescue nil
        generate_alert(stable, avg_price, curve_data)
      end
    end
  end

  def fetch_curve_balance(stable)
    # Curve pool imbalance = ранний сигнал stress
    # >70% одного актива = проблема
    pool = CurveAdapter.get_3pool
    {
      balance_pct: pool.balance_pct(stable),
      total_liquidity: pool.tvl
    }
  end
end
```

#### Формат алерта
```
🚨 DEPEG | USDC | $0.912
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 ЦЕНЫ:
   Binance: $0.910
   OKX: $0.915
   Kraken: $0.912

🔴 CURVE 3POOL:
   USDC: 78% (STRESS!)
   USDT: 15%
   DAI: 7%

⚠️ КЛАСС: SPECULATIVE
   Риск полного краха существует

💡 ЕСЛИ ВХОДИТЬ:
   Вход: $0.912
   Стоп: $0.82 (-10%)
   Тейк: $0.99

📝 ID: `depeg_pqr678`
```

---

## 3. ГИПОТЕЗЫ О НЕИЗВЕСТНОМ EDGE

Дисклеймер: Непроверенные идеи. Требуют исследования.

### 3.1 Token Unlock Pressure
**Гипотеза:** Цена падает после unlock, рынок недооценивает это.
**Кто платит:** VC/команда которые не хеджируются (legal/conflict of interest)
**Что проверить:** Собрать данные unlock events за 12 мес, посмотреть price action.

### 3.2 Listing Frontrun (публичные сигналы)
**Гипотеза:** Есть паттерны перед анонсом листинга (on-chain activity).
**Кто платит:** Медленные участники.
⚠️ Граница с insider trading. Только публичные сигналы.

### 3.3 Structured Products Mispricing
**Гипотеза:** Binance Dual Investment = упакованные опционы с markup.
**Кто платит:** Ретейл не понимающий true cost.
**Что проверить:** Разложить на call/put, сравнить implied vol с Deribit.

### 3.4 New Chain Launch Inefficiency
**Гипотеза:** При запуске нового L2 первые дни — неэффективность.
**Кто платит:** Early adopters торгующие по любой цене.
**Риск:** Smart contract risk, мосты.

---

## 4. SOLIDITY БЭКЛОГ

### 4.1 Flash Loan Arbitrage

#### Суть
Заём неограниченного капитала в одной атомарной транзакции. Не прибыльно → откат, потеря только gas.

#### Источник edge
Кто платит:
- DEX LP (через price impact)
- Трейдеры создавшие дисбаланс между пулами

Почему не арбитражат:

| Участник | Причина |
|----------|---------|
| Ретейл | Нет навыков Solidity |
| CEX трейдеры | Не работают с DeFi |
| Фонды | Compliance, smart contract risk |

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Quasi-risk-free (только gas) |
| Основной риск | Smart contract bugs |
| Вторичный | Failed tx = gas loss |

#### Архитектура контракта

```solidity
// PSEUDO-CODE — требует аудит

contract FlashLoanArbitrage {
    address owner;

    function executeArbitrage(
        address loanToken,
        uint256 loanAmount,
        address[] calldata path,
        address[] calldata dexes
    ) external onlyOwner {
        ILendingPool(AAVE).flashLoan(
            address(this),
            loanToken,
            loanAmount,
            abi.encode(path, dexes)
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) external returns (bool) {
        (address[] memory path, address[] memory dexes) =
            abi.decode(params, (address[], address[]));

        uint256 currentAmount = amount;

        for (uint i = 0; i < path.length - 1; i++) {
            currentAmount = swap(dexes[i], path[i], path[i+1], currentAmount);
        }

        uint256 amountOwed = amount + premium;
        require(currentAmount > amountOwed, "Not profitable");

        IERC20(asset).approve(AAVE, amountOwed);
        return true;
    }
}
```

#### Ruby мониторинг

```ruby
class FlashLoanMonitor
  def find_opportunities
    pools = load_dex_pools

    pools.combination(2).each do |pool_a, pool_b|
      next unless same_pair?(pool_a, pool_b)

      spread = calculate_spread(pool_a, pool_b)
      next if spread < min_spread_for_flash

      profit = simulate_flash_loan(pool_a, pool_b)

      if profit > min_profit_after_gas
        generate_alert(pool_a, pool_b, profit)
      end
    end
  end
end
```

#### Формат алерта
```
⚡ FLASH LOAN | WETH/USDC
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 ПУЛЫ:
   Uniswap V3: 1 WETH = 3,450 USDC
   SushiSwap:  1 WETH = 3,485 USDC
   Spread: 1.01%

💰 СИМУЛЯЦИЯ:
   Loan: 100 WETH
   Route: Uni → Sushi
   Est. profit: $850
   Gas: ~$50
   Net: ~$800

⚠️ СТАТУС: BACKLOG
   Требует: Solidity контракт + аудит

📝 ID: `flash_stu901`
```

#### Требования

| Компонент | Оценка |
|-----------|--------|
| Solidity контракт | 2-3 недели |
| Аудит | $10,000-50,000 |
| Тестнет | 2 недели |
| Mainnet MVP | 1 месяц |

---

### 4.2 MEV Extraction

#### Суть
Sandwich attacks, frontrunning, backrunning — прибыль из порядка транзакций.

#### Источник edge
Кто платит: Трейдеры с высоким slippage tolerance, большие свопы
Почему не арбитражат: Не контролируют порядок транзакций

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Infrastructure business |
| Основной риск | Конкуренция, smart contract bugs |
| Вторичный | Regulatory risk |

#### Архитектура
```
Mempool Monitor → Analysis Engine → Bundle Builder → Flashbots Relay
                         ↓
               Simulation (Anvil)
```

#### Ruby мониторинг

```ruby
class MempoolMonitor
  def watch_pending
    stream_pending_txs do |tx|
      next unless dex_swap?(tx)

      opportunity = analyze_sandwich(tx)

      if opportunity[:profit] > min_profit
        log_opportunity(opportunity)
        # Для исполнения нужен Solidity бот
      end
    end
  end

  def analyze_sandwich(tx)
    decoded = decode_swap(tx)

    frontrun = simulate_frontrun(decoded)
    backrun = simulate_backrun(decoded)
    gas = estimate_gas(2)
    priority = estimate_priority_fee

    {
      profit: frontrun + backrun - gas - priority,
      frontrun_amount: optimal_frontrun(decoded),
      victim: tx
    }
  end
end
```

#### Формат алерта (информационный)
```
🔍 MEV | Sandwich
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 VICTIM:
   Swap: 50 ETH → USDC
   Slippage: 3%
   Pool: Uniswap V3

💰 OPPORTUNITY:
   Frontrun: +$120
   Backrun: +$80
   Gas + Priority: -$50
   Net: ~$150

⚠️ СТАТУС: BACKLOG
   Требует: MEV инфраструктура

📝 ID: `mev_vwx234`
```

#### Требования

| Компонент | Оценка |
|-----------|--------|
| Mempool access | Blocknative ($500/мес) или нода |
| Solidity bot | 4-6 недель |
| Flashbots интеграция | 1-2 недели |
| Симуляция | 1 неделя |
| Аудит | $20,000+ |
| Капитал | $50,000+ |

---

### 4.3 Liquidation Arbitrage

#### Суть
Ликвидация позиций на Aave/Compound/Maker с бонусом 5-15%.

#### Источник edge
Кто платит: Заёмщики не следящие за Health Factor
Почему не арбитражат: Не мониторят или не могут погасить вовремя

#### Класс риска

| Параметр | Значение |
|----------|----------|
| Класс | Quasi-risk-free (с flash loan) |
| Основной риск | Конкуренция, gas wars |
| Вторичный | Smart contract risk |

#### Ruby мониторинг

```ruby
class LiquidationMonitor
  PROTOCOLS = [:aave_v3, :compound_v3, :maker]

  def monitor
    PROTOCOLS.each do |protocol|
      positions = fetch_at_risk(protocol)

      positions.each do |pos|
        next unless pos.health_factor < 1.0

        liq = calculate_liquidation(pos)

        if liq[:net_profit] > min_profit
          generate_alert(pos, liq)
        end
      end
    end
  end

  def calculate_liquidation(pos)
    debt_to_cover = pos.debt * 0.5
    collateral_seized = debt_to_cover * (1 + pos.liquidation_bonus)
    gas = estimate_gas
    flash_fee = debt_to_cover * 0.0005

    {
      debt_to_cover: debt_to_cover,
      collateral_seized: collateral_seized,
      bonus: collateral_seized - debt_to_cover,
      gas: gas,
      flash_fee: flash_fee,
      net_profit: (collateral_seized - debt_to_cover) - gas - flash_fee
    }
  end
end
```

#### Формат алерта
```
💀 LIQUIDATION | Aave V3
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 ПОЗИЦИЯ:
   Address: 0x1234...5678
   Health Factor: 0.95
   Collateral: 10 ETH ($34,500)
   Debt: 25,000 USDC

💰 LIQUIDATION:
   Debt to cover: $12,500
   Collateral seized: $13,125
   Bonus: $625 (5%)
   Gas: ~$30
   Flash fee: ~$6
   Net: ~$589

⚠️ СТАТУС: BACKLOG
   Требует: Solidity контракт

📝 ID: `liq_yza567`
```

#### Требования

| Компонент | Оценка |
|-----------|--------|
| Position monitoring (Ruby) | 1-2 недели |
| Solidity контракт | 2-3 недели |
| Аудит | $10,000-20,000 |

---

### 4.4 Solidity Backlog Summary

| Стратегия | Сложность | Капитал | Разработка | Аудит |
|-----------|-----------|---------|------------|-------|
| Flash Loan | Средняя | $0 | 4-6 нед | $10-50K |
| MEV | Высокая | $50K+ | 8-12 нед | $20K+ |
| Liquidation | Средняя | $0 | 4-6 нед | $10-20K |

Рекомендуемый порядок:
1. Flash Loan — вход в Solidity
2. Liquidation — похожая архитектура
3. MEV — отдельный продукт

---

## 5. АНАЛИТИЧЕСКИЙ СЛОЙ

### 5.1 Что логируем

```sql
-- Все обнаруженные спреды
CREATE TABLE spread_log (
  id SERIAL PRIMARY KEY,
  symbol VARCHAR(20),
  strategy VARCHAR(50),
  low_venue VARCHAR(50),
  high_venue VARCHAR(50),
  spread_pct DECIMAL(10,4),
  passed_validation BOOLEAN,
  rejection_reason VARCHAR(100),
  detected_at TIMESTAMP
);

-- Funding rates
CREATE TABLE funding_log (
  id SERIAL PRIMARY KEY,
  symbol VARCHAR(20),
  exchange VARCHAR(30),
  venue_type VARCHAR(20),
  rate DECIMAL(10,6),
  period_hours INTEGER,
  recorded_at TIMESTAMP
);

-- Z-scores
CREATE TABLE zscore_log (
  id SERIAL PRIMARY KEY,
  pair VARCHAR(20),
  zscore DECIMAL(6,3),
  spread_value DECIMAL(20,8),
  mean DECIMAL(20,8),
  std DECIMAL(20,8),
  recorded_at TIMESTAMP
);

-- Сигналы
CREATE TABLE signals (
  id UUID PRIMARY KEY,
  strategy VARCHAR(50),
  class VARCHAR(20),
  symbol VARCHAR(20),
  details JSONB,
  status VARCHAR(20),
  detected_at TIMESTAMP,
  sent_at TIMESTAMP,
  taken_at TIMESTAMP,
  closed_at TIMESTAMP
);

-- Результаты
CREATE TABLE trade_results (
  id SERIAL PRIMARY KEY,
  signal_id UUID REFERENCES signals(id),
  pnl_pct DECIMAL(10,4),
  hold_hours DECIMAL(10,2),
  notes TEXT,
  recorded_at TIMESTAMP
);
```

### 5.2 Telegram команды

| Команда | Описание |
|---------|----------|
| /status | Статус системы |
| /signals | Последние 10 сигналов |
| /taken {id} | Взял в работу |
| /result {id} +2.3% | Записать результат |
| /result {id} -1.5% slippage | С комментарием |
| /stats | Общая статистика |
| /stats {strategy} | По стратегии |

### 5.3 Формат статистики
```
📊 СТАТИСТИКА (30д)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SPATIAL HEDGED:
  Сигналов: 127
  Взято: 34
  Win rate: 71% (22/31)
  Avg PnL: +1.2%
  Worst: -2.8%

FUNDING:
  Сигналов: 45
  Взято: 8
  Avg daily: 0.12%

STAT ARB:
  Сигналов: 12
  Взято: 3
  Win rate: 67%

⚠️ Данные из ручного /result
```

---

## 6. КРИТЕРИИ УСПЕХА

### 6.1 Через 1 месяц форвард-теста

| Метрика | Что проверяем |
|---------|---------------|
| Сигналов/день по стратегии | Есть ли возможности? |
| % сигналов где спред реально был | Качество обнаружения |
| % где спред сошёлся | Валидность гипотезы |
| Net PnL по взятым | Реальная доходность |
| Win rate | % прибыльных |
| Worst case | Максимальный убыток |

### 6.2 Решения

| Результат | Действие |
|-----------|----------|
| Net PnL > 0, edge подтверждён | Масштабировать |
| Net PnL ≈ 0 | Оптимизировать или отказаться |
| Net PnL < 0 | Отказаться, пересмотреть |
| Ruby ~0, но Solidity opportunities есть | Приоритизировать Solidity |

---

## 7. ФАЗЫ РАЗРАБОТКИ

### Phase 1: Core (3-4 недели)
- Adapters: Binance, OKX, Bybit, Gate
- Spatial hedged + manual
- Telegram bot с алертами
- Logging для анализа
- Команды /taken, /result

### Phase 2: Funding (2 недели)
- Funding rate collection
- HyperLiquid adapter
- Funding alerts
- Cross-venue spread

### Phase 3: Extended (2-3 недели)
- Statistical arbitrage (Z-score)
- Stablecoin monitor
- Curve pool integration

### Phase 4: Solidity (отдельный проект)
- Flash Loan контракт
- Аудит
- Тестнет → Mainnet
