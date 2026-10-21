# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Python statement of the Prior Day Breakout rule, written from the rule text (README), on M1 bars.

    trades = run(m1, tf_minutes=60, target_r=2.0)

`m1` is a pandas DataFrame indexed by server time (naive timestamps, M1 open time) with columns open, high, low, close
(bid prices) and spread (in PRICE units, e.g. 0.35, not points). It returns one row per trade (gross, before swap):
entry/exit time, side, fill prices, stop distance, exit reason.

Rule: levels = high/low of the previous trading day (the previous day that has bars); on the chart timeframe, from the
bar that opens 01:00 on, the first CLOSE above the high (buy) or below the low (sell), once per side per day; the entry is
the next bar's open if it is before 20:00 of the same day; buys fill at open + spread, sells at the bid; the stop is the
other side of the range; skipped when the stop distance is under 8 x the entry spread; target = target_r x the stop
distance; the position is flat at 23:00 (the first M1 bar at or after it); one position at a time. Stops and targets are
tested on the M1 extremes (a buy on the bid low and high, a sell on the ask = bid + spread); the stop first when both fall
in one M1 bar; a gap fills the stop at the open."""
import numpy as np
import pandas as pd

FROM_SEC = 3600           # signal bars from 01:00
CUTOFF_SEC = 20 * 3600    # no entry from 20:00
FLAT_SEC = 23 * 3600      # flat at 23:00
MIN_SPREADS = 8.0         # skip when the stop is under 8 x the spread


def run(m1: pd.DataFrame, tf_minutes: int = 60, target_r: float = 2.0) -> pd.DataFrame:
    t = m1.index.values.astype("datetime64[s]").astype(np.int64)
    o, h, l, c, sp = (m1[k].to_numpy(float) for k in ("open", "high", "low", "close", "spread"))
    n = len(t)
    day = t // 86400
    starts = np.concatenate(([0], np.flatnonzero(np.diff(day)) + 1))
    dh, dl = np.maximum.reduceat(h, starts), np.minimum.reduceat(l, starts)
    pdh = np.concatenate(([np.nan], dh[:-1]))
    pdl = np.concatenate(([np.nan], dl[:-1]))
    day_of_start = day[starts]
    gidx = np.searchsorted(day_of_start, day)             # M1 index -> day group
    sec = tf_minutes * 60
    key = t // sec
    fm = np.concatenate(([0], np.flatnonzero(np.diff(key)) + 1))            # first M1 index of each chart bar
    last = np.concatenate((fm[1:] - 1, [n - 1]))
    bar_open, bar_close = key[fm] * sec, c[last]
    rows, free, cur_day, done = [], 0, -1, [False, False]
    for j in range(len(fm) - 1):
        bday, btod = bar_open[j] // 86400, bar_open[j] % 86400
        if bday != cur_day:
            cur_day, done = bday, [False, False]
        if btod < FROM_SEC:
            continue
        g = gidx[fm[j]]
        hi, lo = pdh[g], pdl[g]
        if np.isnan(hi) or np.isnan(lo):
            continue
        side = 0
        if bar_close[j] > hi and not done[0]:
            done[0], side = True, 1
        elif bar_close[j] < lo and not done[1]:
            done[1], side = True, -1
        if side == 0:
            continue
        e = fm[j + 1]
        if t[e] // 86400 != cur_day or t[e] % 86400 >= CUTOFF_SEC or e < free:
            continue
        fill = o[e] + sp[e] if side > 0 else o[e]
        sl = lo if side > 0 else hi
        sd = (fill - sl) * side
        if not (sd > 0) or sd < MIN_SPREADS * sp[e]:
            continue
        tp = fill + side * target_r * sd if target_r > 0 else np.nan
        fx = int(np.searchsorted(t, cur_day * 86400 + FLAT_SEC, side="left"))
        px, why, m_exit, nxt = (o[fx] if side > 0 else o[fx] + sp[fx]) if fx < n else c[-1], "time", min(fx, n - 1), min(fx, n - 1)
        for m in range(e, min(fx, n)):
            if side > 0:
                if l[m] <= sl:
                    px, why, m_exit, nxt = min(sl, o[m]), "stop", m, m + 1
                    break
                if tp == tp and h[m] >= tp:
                    px, why, m_exit, nxt = max(tp, o[m]), "target", m, m + 1
                    break
            else:
                if h[m] + sp[m] >= sl:
                    px, why, m_exit, nxt = max(sl, o[m] + sp[m]), "stop", m, m + 1
                    break
                if tp == tp and l[m] + sp[m] <= tp:
                    px, why, m_exit, nxt = min(tp, o[m] + sp[m]), "target", m, m + 1
                    break
        rows.append(dict(entry_t=t[e], exit_t=t[m_exit], side=side, entry=fill, exit=px, sd=sd, why=why,
                         gross_r=(px - fill) * side / sd))
        free = nxt
    return pd.DataFrame(rows)
