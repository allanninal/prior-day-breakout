# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Self-test of tests/reference.py on synthetic M1 data (no broker data needed).

    python3 tests/check_reference.py [seeds]        default 30 seeds, 40 weekdays each, chart H1 and M15

For every random walk it checks the rule's own invariants on the trades the reference returns: at most one buy and one
sell per day; the signal bar opens at or after 01:00 and the entry opens before 20:00 of the same day; the stop is the
other side of the previous day's range; the stop distance is at least 8 x the entry spread; no two trades overlap; every
trade is flat by 23:00 of its entry day; a target exit is at the target, a stop exit is at or beyond the stop."""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from reference import run, MIN_SPREADS, CUTOFF_SEC, FLAT_SEC, FROM_SEC  # noqa: E402


def synth(seed, days=40):
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2024-01-01", periods=days * 7 // 5 + 7, freq="D")
    idx = idx[idx.dayofweek < 5][:days]
    times = np.concatenate([d + pd.to_timedelta(np.arange(24 * 60), unit="m") for d in idx])
    ret = rng.normal(0, 0.25, len(times)) + 0.0004 * np.sin(np.arange(len(times)) / 300.0)
    close = 2000 + np.cumsum(ret)
    open_ = np.concatenate(([2000.0], close[:-1]))
    span = np.abs(rng.normal(0, 0.15, len(times)))
    high, low = np.maximum(open_, close) + span, np.minimum(open_, close) - span
    spread = rng.choice([0.2, 0.3, 0.35, 0.5], len(times))
    return pd.DataFrame({"open": open_, "high": high, "low": low, "close": close, "spread": spread}, index=times)


def main(seeds):
    problems, trades_total, runs = [], 0, 0
    for seed in range(seeds):
        m1 = synth(seed)
        t = m1.index.values.astype("datetime64[s]").astype(np.int64)
        day = t // 86400
        starts = np.concatenate(([0], np.flatnonzero(np.diff(day)) + 1))
        dh = dict(zip(day[starts], np.maximum.reduceat(m1.high.to_numpy(), starts)))
        dl = dict(zip(day[starts], np.minimum.reduceat(m1.low.to_numpy(), starts)))
        days = list(day[starts])
        for tf, rr in ((60, 2.0), (15, 1.0)):
            tr = run(m1, tf, rr)
            runs += 1
            trades_total += len(tr)
            if tr.empty:
                continue
            sp = dict(zip(t, m1.spread.to_numpy()))
            prev = {d: days[i - 1] for i, d in enumerate(days) if i > 0}
            last_exit = 0
            seen = set()
            for r in tr.itertuples():
                d = r.entry_t // 86400
                tag = (seed, tf, d, r.side)
                if tag in seen:
                    problems.append(("two trades on one side in a day",) + tag)
                seen.add(tag)
                if r.entry_t % 86400 >= CUTOFF_SEC or r.entry_t % 86400 < FROM_SEC:
                    problems.append(("entry outside 01:00-20:00",) + tag)
                if r.entry_t < last_exit:
                    problems.append(("overlap",) + tag)
                if r.exit_t > d * 86400 + FLAT_SEC + 60 or r.exit_t < r.entry_t:
                    problems.append(("not flat by 23:00",) + tag)
                p = prev[d]
                want_sl = dl[p] if r.side > 0 else dh[p]
                fill_sd = r.sd
                if abs((r.entry - r.side * fill_sd) - want_sl) > 1e-9:
                    problems.append(("stop is not the other side of the range",) + tag)
                if fill_sd < MIN_SPREADS * sp[r.entry_t] - 1e-12:
                    problems.append(("stop under 8 x spread",) + tag)
                if r.why == "target" and (r.exit - r.entry) * r.side < rr * fill_sd - 1e-9:
                    problems.append(("target exit short of the target",) + tag)
                if r.why == "stop" and (r.exit - (r.entry - r.side * fill_sd)) * r.side > 1e-9:
                    problems.append(("stop exit better than the stop",) + tag)
                last_exit = r.exit_t
    print(f"runs: {runs} (seeds x 2 timeframes), trades checked: {trades_total}")
    print(f"violations: {len(problems)}")
    for p in problems[:10]:
        print("  ", p)
    print("RESULT:", "PASS" if not problems else "FAIL")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 30))
