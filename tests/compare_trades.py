# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Compare the EA's own trade lines with tests/reference.py on your M1 history.

    python3 tests/compare_trades.py <tester or Experts log> <m1.csv> --tf 60 --target 2.0 [--from 2023-07-01]

1. Run the EA in the Strategy Tester with "Log every signal and trade" on. It prints one line per closed trade:
   `TRD <entry time> <exit time> BUY|SELL <lots> <entry> <exit> <stop> <profit> <swap>` (server time).
2. Export the symbol's M1 bars from the same terminal to a CSV with the header `time,open,high,low,close,spread`
   (server time, bid prices, `spread` in PRICE units).
3. The script lists the entries (time and side) the log and the reference share, and those only one of them has.
Entries are the check that matters here: they depend only on closed bars. Exit times can differ by minutes because the
tester builds its own tick path from M1 bars."""
import argparse
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from reference import run  # noqa: E402

TRD = re.compile(r"TRD (\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d) (\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d) (BUY|SELL) ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("m1")
    ap.add_argument("--tf", type=int, default=60, help="chart timeframe in minutes")
    ap.add_argument("--target", type=float, default=2.0)
    ap.add_argument("--from", dest="t_from", default=None)
    a = ap.parse_args()
    ea = set()
    for line in Path(a.log).read_text(errors="replace").splitlines():
        m = TRD.search(line)
        if m:
            t = pd.to_datetime(m.group(1), format="%Y.%m.%d %H:%M:%S").to_datetime64().astype("datetime64[s]").astype(np.int64)
            ea.add((int(t), 1 if m.group(3) == "BUY" else -1))
    m1 = pd.read_csv(a.m1, parse_dates=["time"], index_col="time")
    ref = run(m1, a.tf, a.target)
    if a.t_from:
        ref = ref[ref.entry_t >= int(np.datetime64(a.t_from, "s").astype(np.int64))]
    rs = set(zip(ref.entry_t.astype(int), ref.side.astype(int)))
    print(f"EA trades: {len(ea)}  reference trades: {len(rs)}  same entry and side: {len(ea & rs)}")
    print(f"only in the EA log: {len(ea - rs)}  only in the reference: {len(rs - ea)}")
    return 0 if ea == rs else 1


if __name__ == "__main__":
    sys.exit(main())
