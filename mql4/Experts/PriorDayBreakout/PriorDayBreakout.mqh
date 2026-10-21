//+------------------------------------------------------------------+
//|                                                 PriorDayBreakout.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Prior Day Breakout MT4: the previous-day high/low breakout.      |
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
//| MT4: orders (OrderSend/OrderClose), server time from GMT + a     |
//| learnt offset. Automation, not a strategy with an edge: no       |
//| profit is promised.                                              |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property strict
#include "DbPanel.mqh"
#include "DbPresets.mqh"

#define DB_NAME "Prior Day Breakout MT4"

input double InpTargetR  = 2.0;     // Target, x the stop distance (R); the preset's own value
input int    InpMagic    = 26101801;// Magic number
input int    InpSlippage = 30;      // Maximum slippage, points
input bool   InpPanel    = true;    // Show the panel
input bool   InpLevels   = true;    // Draw the previous-day high and low
input bool   InpDebug    = false;   // Log every signal and trade (Experts tab)

#define DB_FROM_SEC  3600              // bars opening from 01:00 server time
#define DB_TO_SEC    (20*3600)         // no entry from 20:00
#define DB_FLAT_SEC  (23*3600)         // flat at 23:00
#define DB_MIN_SPREADS 8.0             // skip a trade whose stop is under 8 x the entry spread
#define DB_MAX_STOP_PCT 50.0           // never open a trade whose stop would lose more than this % of equity

int      g_trd_ticket=0;                // debug: the open trade, for its TRD line once closed
double   g_trd_sl=0;
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
//--- server time: TimeCurrent() in the tester; live, MQL4 has no TimeTradeServer and TimeCurrent stops between ticks
//--- (all weekend), so GMT + the server's offset, learnt from a fresh tick (a whole half hour, -12 h .. +14 h)
datetime NowSrv(void)
  {
   static long off=LONG_MIN;
   if(IsTesting())
      return(TimeCurrent());
   long d=(long)TimeCurrent()-(long)TimeGMT();
   long r=(long)MathRound(d/1800.0)*1800;
   if(MathAbs(d-r)<=120 && r>=-12*3600 && r<=14*3600)
      off=r;
   return(off==LONG_MIN ? TimeCurrent() : (datetime)((long)TimeGMT()+off));
  }
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
   for(uint s=0; SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)dt.day_of_week,s,from,to); s++)
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
   double ts=MarketInfo(_Symbol,MODE_TICKSIZE);
   if(ts>0)
      return(NormalizeDouble(MathRound(p/ts)*ts,_Digits));
   return(NormalizeDouble(p,_Digits));
  }

//--- the money one tick moves one lot, in the account currency. MT4 gives 0 for some CFD symbols (gold, crypto) in the
//--- Strategy Tester: then tick size x contract size, in the profit currency, converted with its cross rate
double TickValue(void)
  {
   double tv=MarketInfo(_Symbol,MODE_TICKVALUE);
   if(tv>0)
      return(tv);
   double v=MarketInfo(_Symbol,MODE_TICKSIZE)*MarketInfo(_Symbol,MODE_LOTSIZE);
   string pc=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT),ac=AccountCurrency();
   if(v<=0 || pc=="")
      return(0);
   if(pc==ac)
      return(v);
   double r=MarketInfo(pc+ac,MODE_BID);
   if(r>0)
      return(v*r);
   r=MarketInfo(ac+pc,MODE_BID);
   return(r>0 ? v/r : 0);
  }

//--- money lost from `price` to `sl` by one lot (MQL4 has no OrderCalcProfit: ticks x tick value)
double LossPerLot(const double price,const double sl)
  {
   double tick=MarketInfo(_Symbol,MODE_TICKSIZE);
   return(tick>0 ? MathAbs(price-sl)/tick*TickValue() : 0);
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
   double mr=MarketInfo(_Symbol,MODE_MARGINREQUIRED);   // 0 when MT4 cannot price it (the tester offline): the broker decides
   if(mr>0 && lots*mr>AccountFreeMargin()*0.95)
     { why="not enough free margin"; return(0); }
   return(lots);
  }

//--- this EA's open position on the symbol: ticket (0 = none, else it stays selected), direction +1/-1
int FindPos(int &dir)
  {
   dir=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES) || OrderType()>OP_SELL || OrderSymbol()!=_Symbol || OrderMagicNumber()!=InpMagic)
         continue;
      dir=(OrderType()==OP_BUY ? 1 : -1);
      return(OrderTicket());
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
   if(!IsTesting() && !IsTradeAllowed())
      return("AutoTrading is off");
   if(!MarketOpen())
      return("market closed");
   if(!g_validated && !IsTesting())
      return("not a validated preset");
   return("");
  }


bool OpenTrade(const int side,const double sl_level)
  {
   RefreshRates();
   double ask=MarketInfo(_Symbol,MODE_ASK),bid=MarketInfo(_Symbol,MODE_BID);
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
   int t=OrderSend(_Symbol,buy ? OP_BUY : OP_SELL,lots,buy ? ask : bid,InpSlippage,sl,tp,DB_NAME,InpMagic,0,clrNONE);
   if(t<0)
     {
      int err=GetLastError();
      Say("refused, error "+IntegerToString(err),"order refused (error "+IntegerToString(err)+")");
      return(false);
     }
   g_trd_ticket=t;
   g_trd_sl=sl;
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
   int t=FindPos(dir);
   if(t==0)
      return;
   datetime now=NowSrv();
   datetime po=OrderOpenTime();
   datetime exit_t=(datetime)((po/86400)*86400+DB_FLAT_SEC);
   if(now>=exit_t)
     {
      if(!MarketOpen())
         return;                                         // retry on the next tick once the market is open
      RefreshRates();
      if(OrderClose(t,OrderLots(),dir>0 ? MarketInfo(_Symbol,MODE_BID) : MarketInfo(_Symbol,MODE_ASK),InpSlippage,clrNONE))
         Say("closed: 23:00","position closed: flat at 23:00");
     }
  }



//+------------------------------------------------------------------+
//| Chart: previous-day high and low (closed values, drawn once a day)|
//+------------------------------------------------------------------+
void DrawLevels(void)
  {
   if(!InpLevels || (IsTesting() && !IsVisualMode()))
      return;
   if(!g_lvl || (g_hi==0 && g_lo==0))
      return;
   datetime d0=(datetime)(g_day*86400);
   if(g_lvl_drawn==d0)
      return;
   g_lvl_drawn=d0;
   string n[2]={"DBK_PDH","DBK_PDL"};
   double v[2];                                     // MQL4: no initialiser from variables
   v[0]=g_hi;
   v[1]=g_lo;
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
   int t=FindPos(dir);
   if(t!=0)
     {
      y=Row("p_side",y,"Side",dir>0 ? "BUY" : "SELL",dir>0 ? UiPos() : UiNeg());
      y=Row("p_vol",y,"Volume",DoubleToString(OrderLots(),LotDigits()),UiText());
      y=Row("p_sl",y,"Stop loss",DoubleToString(OrderStopLoss(),_Digits),UiText());
      double pl=OrderProfit()+OrderSwap();
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
   g_validated=DbPresetValidated(_Symbol,(ENUM_TIMEFRAMES)_Period,InpTargetR);
   g_bar0=iTime(_Symbol,_Period,0);
   ReplayToday();
   PrintFormat("%s: previous-day breakout, target %s R on %s %s, %s",DB_NAME,Num(InpTargetR),_Symbol,
               TfName((ENUM_TIMEFRAMES)_Period),g_validated ? "validated preset" : "NOT a validated preset");
   if(!g_validated && !IsTesting())
      Alert(DB_NAME+": "+_Symbol+" "+TfName((ENUM_TIMEFRAMES)_Period)+" with these settings is not a validated preset. No orders will be sent.");
   if(InpPanel && (!IsTesting() || IsVisualMode()))
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
   TradeLine();
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
   if(InpPanel && (!IsTesting() || IsVisualMode()))
      Draw();
  }

//--- debug: one line per closed trade (entry and exit time, side, prices, stop at entry) for the parity check. MQL4 has
//--- no OnTradeTransaction: the trade this EA opened is looked up in the history once it has closed
void TradeLine(void)
  {
   if(g_trd_ticket<=0 || !OrderSelect(g_trd_ticket,SELECT_BY_TICKET) || OrderCloseTime()==0)
      return;
   if(InpDebug)
      PrintFormat("TRD %s %s %s %s %s %s %s %.2f %.2f",TimeToString(OrderOpenTime(),TIME_DATE|TIME_SECONDS),   // MQL4: no %.*f
                  TimeToString(OrderCloseTime(),TIME_DATE|TIME_SECONDS),OrderType()==OP_BUY ? "BUY" : "SELL",
                  DoubleToString(OrderLots(),2),DoubleToString(OrderOpenPrice(),_Digits),DoubleToString(OrderClosePrice(),_Digits),
                  DoubleToString(g_trd_sl,_Digits),OrderProfit(),OrderSwap());
   g_trd_ticket=0;
  }
//+------------------------------------------------------------------+
