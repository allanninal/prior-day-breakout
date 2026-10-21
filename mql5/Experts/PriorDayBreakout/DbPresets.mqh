//+------------------------------------------------------------------+
//|                                                    DbPresets.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Validated presets: symbol, timeframe and target that passed BOTH |
//| the Python out-of-sample screen and the Strategy Tester (see the |
//| README). Live, the EA opens orders only on one of these rows.    |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#ifndef DB_PRESETS_MQH
#define DB_PRESETS_MQH
#define DB_PRESET_N 2
//--- one row per validated chart: its own target (R)
struct DbPreset { string sym; ENUM_TIMEFRAMES tf; double rr; };
const DbPreset g_db_presets[DB_PRESET_N]=
  {
   {"XAUEUR",PERIOD_H1,2.0},
   {"XAUEUR",PERIOD_M15,1.0}
  };
//--- the broker may add a suffix to the symbol ("XAUEUR.m"): the preset name must be its start
bool DbPresetValidated(const string sym,const ENUM_TIMEFRAMES tf,const double rr)
  {
   for(int i=0; i<DB_PRESET_N; i++)
      if(g_db_presets[i].tf==tf && MathAbs(g_db_presets[i].rr-rr)<1e-9 && StringFind(sym,g_db_presets[i].sym)==0)
         return(true);
   return(false);
  }
#endif
