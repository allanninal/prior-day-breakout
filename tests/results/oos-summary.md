# Out-of-sample results of the two presets (backtest, not live trading)

Source: the Strategy Tester run of the EA itself (MetaTrader 5, model "1 minute OHLC", broker history, server time),
XAUEUR, out of sample 2023-07-01 to 2026-10-09, 0.01 lot, results in R (R = the stop distance of each trade), spread and
swap included, no commission. Settings frozen on 2020-01 to 2023-06 data before the later period was opened.

| Preset | Target | OOS trades | PF | net R | t | max drawdown (R) | half A / half B (R) | buys / sells (R) |
|---|---:|---:|---:|---:|---:|---:|---|---|
| XAUEUR H1 | 2 R | 612 | 1.37 | 39.3 | 2.91 | 6.9 | 23.6 / 15.7 | 36.9 / 2.4 |
| XAUEUR M15 | 1 R | 690 | 1.27 | 36.6 | 2.47 | 6.7 | 26.6 / 10.0 | 35.4 / 1.2 |

Halves: A = 2023-07 to 2025-02, B = 2025-03 to 2026-10-08. Pre-registered pass criteria: trades >= 60, PF >= 1.15, net R > 0,
t >= 2.0, net R > 0 in both halves, buys-only and sells-only both > 0 with at least 15 trades each. Both rows pass them.

In-sample (2020-01 to 2023-06) profit factors were only 1.05 to 1.09. Win rate about 52 %, average win 0.46 R, average loss
0.36 R, about +0.06 R per trade. Of 392 judged units over 37 symbols, 8 nominal passes against 8.3 expected from chance
alone, none surviving the Holm correction (smallest adjusted p 0.33). Out of sample, gold rose about 110 %.

# Entries and exits of the EA against the research simulation (MT5 Strategy Tester, same period)

| Preset | simulation trades | EA trades | same entry time and side | same exit time and price as the research tester run |
|---|---:|---:|---:|---:|
| XAUEUR H1, target 2 R | 612 | 612 | 100 % | 612 / 612 |
| XAUEUR M15, target 1 R | 690 | 690 | 100 % | 690 / 690 |

Net R of the EA against the simulation: 39.31 against 40.10 (H1) and 36.60 against 36.63 (M15); the small difference is the same
one seen between the research tester run and the simulation: identical entries, small fill-price differences.

# MetaTrader 4 edition, same two presets (MT4 Strategy Tester, every tick from M1 history, fixed 25-point spread)

| Preset | simulation trades | EA trades | entry match | PF | t | net R (EA) | net R (simulation) |
|---|---:|---:|---:|---:|---:|---:|---:|
| XAUEUR H1, target 2 R | 612 | 612 | 99.84 % | 1.40 | 3.14 | 42.65 | 40.10 |
| XAUEUR M15, target 1 R | 690 | 690 | 99.86 % | 1.29 | 2.66 | 39.46 | 36.63 |

The test ran in three date chunks (MT4 keeps about 512,000 bars of a chart); the one entry that differs per run is the first
day of a chunk or the last day of the test, which MT4 includes. Validator-style run (EURUSD H1): 138 trades, 0 error lines.

# MetaTrader 5 release check, version 1.01 (compile 0 errors, 0 warnings; MQL5 validator set 2025-10-01 to 2026-10-01)

| Check | Result |
|---|---|
| Memory | every-tick run 364 MB (XAUEUR H1, 52,115,889 ticks, 2026-01 to 2026-10); validator-style runs 62 to 190 MB |
| Speed | 1 min 21 s for the same 52 M ticks; per tick only a position lookup and a time compare, the rule runs once per bar |
| Non-repainting | 142 signals identical on every tick and on 1-minute OHLC (XAUEUR H1, 2026-01 to 2026-10) |
| Validator-style runs (EURUSD H1, XAUEUR D1, GBPUSD M30, EURUSD M1, XAUEUR H1 with a 100 deposit) | trades on all (370 / 0 / 408 / 434 / 12 deals; D1 has no entries by design), 0 error lines |
