//+------------------------------------------------------------------+
//|                                                  PriorDayBreakout.mq5 |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property copyright "Copyright 2026, Allan Niñal <https://www.allanninal.dev/mql5>"
#property link      "https://www.allanninal.dev/mql5"
#property version   "1.01"
#property description "Previous-day high/low breakout on closed bars, stop at the other side of the range, fixed target, flat at 23:00. Fixed 0.01 lot."
#property description "Automation, not a strategy with an edge: no profit is promised."
#include "PriorDayBreakout.mqh"
