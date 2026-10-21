//+------------------------------------------------------------------+
//|                                                 PriorDayBreakout.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Prior Day Breakout: the previous-day high/low breakout.          |
//|  * levels: high and low of the previous trading day (M1 bars of  |
//|    the latest earlier server day, up to 7 days back);            |
//|  * signal: the first CLOSE of a bar above the high (buy) or     |
//|    below the low (sell), bars opening 01:00-20:00 server time,   |
//|    once per side per day; decided on the closed bar only;       |
//|  * entry: market order at the open of the next bar (buy at ask,  |
//|    sell at bid); skipped when the stop is under 8 x the spread;  |
//|  * stop: the other side of the previous-day range;               |
//|  * target: Target x the stop distance (the preset's own value);  |
//|  * exit: always flat at 23:00 server time; one position at a time|
//| Fixed 0.01 lot (or the broker minimum).                          |
//| Live the EA only opens trades on a validated preset (symbol,     |
//| timeframe, target); in the Strategy Tester it always trades so   |
//| the Market validator can run it.                                 |
//| Automation, not a strategy with an edge: no profit is promised.  |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property strict
#include <Trade/Trade.mqh>
#include "DbPanel.mqh"
#include "DbPresets.mqh"

#define DB_NAME "Prior Day Breakout"

input group "Rule"
input double InpTargetR  = 2.0;     // Target, x the stop distance (R); the preset's own value
input group "Trade"
input long   InpMagic    = 26101801;// Magic number
input int    InpSlippage = 30;      // Maximum slippage, points
input group "Display"
input bool   InpPanel    = true;    // Show the panel
input bool   InpLevels   = true;    // Draw the previous-day high and low
input bool   InpDebug    = false;   // Log every signal and trade (Experts tab)

#define DB_FROM_SEC  3600              // bars opening from 01:00 server time
#define DB_TO_SEC    (20*3600)         // no entry from 20:00
#define DB_FLAT_SEC  (23*3600)         // flat at 23:00
#define DB_MIN_SPREADS 8.0             // skip a trade whose stop is under 8 x the entry spread
#define DB_MAX_STOP_PCT 50.0           // never open a trade whose stop would lose more than this % of equity

CTrade   g_trade;
datetime g_bar0=0;                     // open time of the current bar
long     g_day=-1;                     // server day (days since 1970) of the last decided bar
bool     g_doneL=false,g_doneS=false,g_lvl=false;
double   g_hi=0,g_lo=0;                // previous-day high / low
string   g_msg="";
datetime g_msg_time=0;
int      g_panel_h=200;
bool     g_validated=true;
int      g_last_sig=0;
datetime g_last_sig_bar=0;
datetime g_lvl_drawn=0;

//+------------------------------------------------------------------+
string Num(const double v) { return(DoubleToString(v,MathAbs(v-MathRound(v))<1e-9 ? 0 : 1)); }
datetime NowSrv(void) { return(MQLInfoInteger(MQL_TESTER) ? TimeCurrent() : TimeTradeServer()); }
string TfName(const ENUM_TIMEFRAMES tf) { return(StringSubstr(EnumToString(tf==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : tf),7)); }
string Stamp(const datetime t) { return(TimeToString(t,TIME_DATE|TIME_MINUTES)); }

void Say(const string m,const string full="")
  {
   g_msg=m;
   g_msg_time=TimeLocal();
   if(InpDebug || full!="")
      Print(DB_NAME+": "+(full!="" ? full : m));
  }


bool MarketOpen(void)
  {
   datetime now=NowSrv();
   MqlDateTime dt;
   TimeToStruct(now,dt);
   int tod=(int)(now%86400);
   datetime from,to;
   for(int s=0; SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)dt.day_of_week,s,from,to); s++)
     {
      int f=(int)(from%86400),t=(int)(to%86400);
      if(t==0)
         t=86400;
      if(f<t ? (tod>=f && tod<t) : (tod>=f || tod<t))
         return(true);
     }
   return(false);
  }

double NormPrice(const double p)
  {
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts>0)
      return(NormalizeDouble(MathRound(p/ts)*ts,_Digits));
   return(NormalizeDouble(p,_Digits));
  }

//--- money lost from `price` to `sl` by one lot
double LossPerLot(const double price,const double sl)
  {
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0)
      tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double by_tick=(tick>0 ? MathAbs(price-sl)/tick : 0)*tv;
   double p=0;
   if(price!=sl && OrderCalcProfit(sl<price ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,1.0,price,sl,p))
      return(MathMax(by_tick,MathAbs(p)));
   return(by_tick);
  }

int LotDigits(void)
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   int d=0;
   while(d<8 && step>0 && MathAbs(step*MathPow(10,d)-MathRound(step*MathPow(10,d)))>1e-9)
      d++;
   return(d);
  }

//--- the volume for an entry at `price` with stop `sl`; 0 = refuse (message in `why`)
double EntryLots(const bool buy,const double price,const double sl,string &why)
  {
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   why="";
   double lots=MathMax(0.01,vmin);                    // 0.01, or the broker minimum when that is larger
   if(step>0)
      lots=MathCeil(lots/step-1e-9)*step;
   lots=NormalizeDouble(MathMin(lots,vmax),8);
   if(LossPerLot(price,sl)*lots>AccountInfoDouble(ACCOUNT_EQUITY)*DB_MAX_STOP_PCT/100.0)
     { why=StringFormat("the stop would lose more than %.0f%% of equity",DB_MAX_STOP_PCT); return(0); }
   double m=0;
   if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,lots,price,m) || m>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95)
     { why="not enough free margin"; return(0); }
   return(lots);
  }

//--- this EA's position on the symbol: ticket (0 = none), direction +1/-1
ulong FindPos(int &dir)
  {
   dir=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      return(t);
     }
   return(0);
  }

//+------------------------------------------------------------------+
//| The rule                                                         |
//+------------------------------------------------------------------+
//--- M1 high/low of [from, to); returns the number of bars
int M1Range(const datetime from,const datetime to,double &hi,double &lo)
  {
   MqlRates r[];
   int n=CopyRates(_Symbol,PERIOD_M1,from,to-1,r);
   if(n<=0)
      return(0);
   hi=r[0].high;
   lo=r[0].low;
   for(int i=1; i<n; i++)
     {
      hi=MathMax(hi,r[i].high);
      lo=MathMin(lo,r[i].low);
     }
   return(n);
  }

//--- previous trading day's high/low: the latest earlier day with M1 bars, up to 7 days back
bool PrevDay(const datetime day,double &hi,double &lo)
  {
   for(int k=1; k<=7; k++)
      if(M1Range(day-k*86400,day-(k-1)*86400,hi,lo)>0)
         return(true);
   return(false);
  }

//--- the decision for one CLOSED bar (open time tb, close c): +1 buy, -1 sell, 0 none. Sets the once-per-side flags.
int Decide(const datetime tb,const double c)
  {
   long day=(long)(tb/86400);
   if(day!=g_day)
     {
      g_day=day;
      g_doneL=false;
      g_doneS=false;
      g_lvl=false;
     }
   datetime d0=(datetime)(day*86400);
   long tod=tb-d0;
   if(tod<DB_FROM_SEC)
      return(0);
   if(!g_lvl)
     {
      g_lvl=true;
      g_hi=0;
      g_lo=0;
      if(!PrevDay(d0,g_hi,g_lo))
        {
         g_hi=0;
         g_lo=0;
        }
     }
   if(g_hi==0 && g_lo==0)
      return(0);
   if(c>g_hi && !g_doneL)
     {
      g_doneL=true;
      return(1);
     }
   if(c<g_lo && !g_doneS)
     {
      g_doneS=true;
      return(-1);
     }
   return(0);
  }

//--- after a restart: replay today's closed bars so a side that already fired today is not taken again
void ReplayToday(void)
  {
   datetime b0=iTime(_Symbol,_Period,0);
   datetime last=iTime(_Symbol,_Period,1);
   if(b0==0 || last==0)
      return;
   datetime d0=(datetime)((last/86400)*86400);
   MqlRates r[];
   int n=CopyRates(_Symbol,_Period,d0,b0-1,r);
   for(int i=0; i<n; i++)
      Decide(r[i].time,r[i].close);
  }

//--- why a new entry is not allowed right now ("" = allowed)
string EntryBlocked(const datetime now)
  {
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return("Algo Trading is off");
   if(!MarketOpen())
      return("market closed");
   if(!g_validated && !MQLInfoInteger(MQL_TESTER))
      return("not a validated preset");
   return("");
  }


bool OpenTrade(const int side,const double sl_level)
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0 || bid<=0)
      return(false);
   bool buy=(side>0);
   double fill=buy ? ask : bid;
   double sd=(fill-sl_level)*side;
   if(!(sd>0.0) || sd<DB_MIN_SPREADS*(ask-bid))
     {
      Say("skipped: stop under 8 x spread");
      return(false);
     }
   double sl=NormPrice(sl_level);
   double tp=(InpTargetR>0 ? NormPrice(fill+side*InpTargetR*sd) : 0);
   string why;
   double lots=EntryLots(buy,fill,sl,why);
   if(lots<=0)
     {
      Say("skipped: "+why,"entry skipped: "+why);
      return(false);
     }
   bool ok=(buy ? g_trade.Buy(lots,_Symbol,0,sl,tp,DB_NAME) : g_trade.Sell(lots,_Symbol,0,sl,tp,DB_NAME));
   if(!ok)
     {
      Say("refused, code "+IntegerToString(g_trade.ResultRetcode()),"order refused ("+g_trade.ResultRetcodeDescription()+")");
      return(false);
     }
   Say((buy ? "BUY " : "SELL ")+DoubleToString(lots,LotDigits()),
       StringFormat("%s %s lots at %s, stop %s%s",buy ? "BUY" : "SELL",DoubleToString(lots,LotDigits()),DoubleToString(fill,_Digits),
                    DoubleToString(sl,_Digits),tp>0 ? ", target "+DoubleToString(tp,_Digits) : ""));
   return(true);
  }

//--- called once per new bar: decides on the bar that just closed
void OnNewBar(void)
  {
   datetime tb=iTime(_Symbol,_Period,1);
   double c=iClose(_Symbol,_Period,1);
   if(tb==0)
      return;
   datetime now=NowSrv();
   int side=Decide(tb,c);
   if(side==0)
      return;
   g_last_sig=side;
   g_last_sig_bar=tb;
   if(InpDebug)
      Print("DBG ",Stamp(tb),": signal ",side>0 ? "BUY" : "SELL");
   long day=(long)(tb/86400);
   if((long)(now/86400)!=day || (now%86400)>=DB_TO_SEC)
      return;                                            // outside the entry window
   int pdir;
   if(FindPos(pdir)!=0)
      return;                                            // one position at a time
   string b=EntryBlocked(now);
   if(b!="")
     {
      Say("skipped: "+b,InpDebug ? "entry skipped: "+b : "");
      return;
     }
   OpenTrade(side,side>0 ? g_lo : g_hi);
  }

//--- every tick: the 23:00 exit, from the position's own open time
void ManageTimed(void)
  {
   int dir;
   ulong t=FindPos(dir);
   if(t==0)
      return;
   datetime now=NowSrv();
   datetime po=(datetime)PositionGetInteger(POSITION_TIME);
   datetime exit_t=(datetime)((po/86400)*86400+DB_FLAT_SEC);
   if(now>=exit_t)
     {
      if(!MarketOpen())
         return;                                         // retry on the next tick once the market is open
      if(g_trade.PositionClose(t))
         Say("closed: 23:00","position closed: flat at 23:00");
     }
  }



//+------------------------------------------------------------------+
//| Chart: previous-day high and low (closed values, drawn once a day)|
//+------------------------------------------------------------------+
void DrawLevels(void)
  {
   if(!InpLevels || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return;
   if(!g_lvl || (g_hi==0 && g_lo==0))
      return;
   datetime d0=(datetime)(g_day*86400);
   if(g_lvl_drawn==d0)
      return;
   g_lvl_drawn=d0;
   string n[2]={"DBK_PDH","DBK_PDL"};
   double v[2]={g_hi,g_lo};
   for(int i=0; i<2; i++)
     {
      string nm=n[i]+"_"+TimeToString(d0,TIME_DATE);
      if(ObjectFind(0,nm)<0)
         ObjectCreate(0,nm,OBJ_TREND,0,d0,v[i],d0+DB_FLAT_SEC,v[i]);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,i==0 ? C'126,192,143' : C'226,124,124');
      ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,nm,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      ObjectSetString(0,nm,OBJPROP_TEXT,i==0 ? "previous-day high" : "previous-day low");
     }
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void Draw(void)
  {
   g_cursor=0;
   Box("bg",0,0,UI_W,g_panel_h+UI_PAD,UiBack(),UiRule());
   Box("hd",0,0,UI_W,UI_HEAD-4,g_ui_light ? C'240,241,244' : C'32,35,40',UiRule());
   Text("title",UI_PAD,5,DB_NAME,UiText(),g_ui_font+1,"Segoe UI Semibold");
   Text("ed",UI_W-UI_PAD-28,7,"FREE",UiDim(),g_ui_font-1);
   int y=Section("s_sig",UI_HEAD-6,"RULE");
   y=Row("r_rule",y,"Rule","prev-day high/low",UiText());
   y=Row("r_tf",y,"Chart",_Symbol+" "+TfName((ENUM_TIMEFRAMES)_Period),UiText());
   y=Row("r_tg",y,"Target",Num(InpTargetR)+" R",UiText());
   y=Row("r_pair",y,"Preset",g_validated ? "validated" : "not validated",g_validated ? UiPos() : UiWarn());
   y=Row("r_hi",y,"Prev-day high",(g_lvl && g_hi>0) ? DoubleToString(g_hi,_Digits) : "-",UiText());
   y=Row("r_lo",y,"Prev-day low",(g_lvl && g_lo>0) ? DoubleToString(g_lo,_Digits) : "-",UiText());
   string last=(g_last_sig==0 ? "none yet" : (g_last_sig>0 ? "BUY " : "SELL ")+Stamp(g_last_sig_bar));
   y=Row("r_last",y,"Last signal",last,g_last_sig>0 ? UiPos() : (g_last_sig<0 ? UiNeg() : UiDim()));
   y=Section("s_pos",y,"POSITION");
   int dir;
   ulong t=FindPos(dir);
   if(t!=0)
     {
      y=Row("p_side",y,"Side",dir>0 ? "BUY" : "SELL",dir>0 ? UiPos() : UiNeg());
      y=Row("p_vol",y,"Volume",DoubleToString(PositionGetDouble(POSITION_VOLUME),LotDigits()),UiText());
      y=Row("p_sl",y,"Stop loss",DoubleToString(PositionGetDouble(POSITION_SL),_Digits),UiText());
      double pl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      y=Row("p_pl",y,"Open P/L",SMoney(pl)+" "+AccountInfoString(ACCOUNT_CURRENCY),Sign(pl));
     }
   else
     {
      y=Row("p_side",y,"Side","flat",UiDim());
      y=Row("p_vol",y,"Volume","-",UiDim());
      y=Row("p_sl",y,"Stop loss","-",UiDim());
      y=Row("p_pl",y,"Open P/L","-",UiDim());
     }
   y=Section("s_st",y,"STATE");
   y=Row("s_lot",y,"Lot","0.01",UiText());
   if(g_msg!="" && TimeLocal()-g_msg_time<30)
      y=Row("msg2",y,"Last action",g_msg,UiDim());
   else
      if(ObjectFind(0,DB_PREFIX+"msg2_l")>=0)
        {
         ObjectDelete(0,DB_PREFIX+"msg2_l");
         ObjectDelete(0,DB_PREFIX+"msg2_v");
         CacheClear();
        }
   if(y!=g_panel_h)
     {
      g_panel_h=y;
      CacheClear();
      Draw();
      return;
     }
   if(g_panel_dirty)
     {
      ChartRedraw();
      g_panel_dirty=false;
     }
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpTargetR<0 || (InpTargetR>0 && InpTargetR<0.1))
     {
      Print(DB_NAME+": check the inputs (the target must be 0 or at least 0.1 R)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_NO);
   g_validated=DbPresetValidated(_Symbol,(ENUM_TIMEFRAMES)_Period,InpTargetR);
   g_bar0=iTime(_Symbol,_Period,0);
   ReplayToday();
   PrintFormat("%s: previous-day breakout, target %s R on %s %s, %s",DB_NAME,Num(InpTargetR),_Symbol,
               TfName((ENUM_TIMEFRAMES)_Period),g_validated ? "validated preset" : "NOT a validated preset");
   if(!g_validated && !MQLInfoInteger(MQL_TESTER))
      Alert(DB_NAME+": "+_Symbol+" "+TfName((ENUM_TIMEFRAMES)_Period)+" with these settings is not a validated preset. No orders will be sent.");
   if(InpPanel && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE)))
     {
      g_ui_light=(ChartGetInteger(0,CHART_COLOR_BACKGROUND)==clrWhite);
      g_ui_corner=DB_RIGHT;
      EventSetTimer(2);
      Draw();
     }
   DrawLevels();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   PanelDelete();
   ObjectsDeleteAll(0,"DBK_PDH");
   ObjectsDeleteAll(0,"DBK_PDL");
  }

void OnTick()
  {
   ManageTimed();
   datetime b=iTime(_Symbol,_Period,0);
   if(b==0 || b==g_bar0)
      return;
   g_bar0=b;
   OnNewBar();
   DrawLevels();
  }

void OnTimer()
  {
   if(InpPanel && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE)))
      Draw();
  }

//--- debug: one line per closed trade (entry and exit time, side, prices, stop at entry) for the parity check
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(!InpDebug || trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.symbol!=_Symbol)
      return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic)
      return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)
      return;
   ulong pid=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   if(!HistorySelectByPosition(pid))
      return;
   double pin=0,sl=0,vol=0,swap=0,profit=0;
   datetime tin=0,tout=0;
   int side=0;
   double pout=0;
   for(int i=0; i<HistoryDealsTotal(); i++)
     {
      ulong d=HistoryDealGetTicket(i);
      long e=HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN)
        {
         pin=HistoryDealGetDouble(d,DEAL_PRICE);
         tin=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         side=(HistoryDealGetInteger(d,DEAL_TYPE)==DEAL_TYPE_BUY ? 1 : -1);
         vol=HistoryDealGetDouble(d,DEAL_VOLUME);
         ulong o=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
         if(HistoryOrderSelect(o))
            sl=HistoryOrderGetDouble(o,ORDER_SL);
        }
      else
         if(e==DEAL_ENTRY_OUT)
           {
            pout=HistoryDealGetDouble(d,DEAL_PRICE);
            tout=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            profit+=HistoryDealGetDouble(d,DEAL_PROFIT);
           }
      swap+=HistoryDealGetDouble(d,DEAL_SWAP);
     }
   PrintFormat("TRD %s %s %s %s %.*f %.*f %.*f %.2f %.2f",TimeToString(tin,TIME_DATE|TIME_SECONDS),TimeToString(tout,TIME_DATE|TIME_SECONDS),
               side>0 ? "BUY" : "SELL",DoubleToString(vol,2),_Digits,pin,_Digits,pout,_Digits,sl,profit,swap);
  }
//+------------------------------------------------------------------+
