//+------------------------------------------------------------------+
//|              XAUUSD_Adaptive_MultiStrategy_v4_13.mq5             |
//| Multi-Trade Fixed Execution Engine for Gold                      |
//| v4.11: risk-based sizing + real daily-loss/drawdown/margin/spread|
//|        /ATR gating + total-lot overflow fix                     |
//| v4.12: automatic profit-taking - breakeven lock, partial close   |
//|        at profit milestones, daily profit target auto-close     |
//| v4.13: no more simultaneous buy+sell - locked to one direction  |
//|        at a time until flat                                     |
//+------------------------------------------------------------------+
#property copyright "Custom Professional Trading Systems"
#property version   "4.13"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_MARKET_REGIME
  {
   REGIME_STRONG_BULL_TREND=0,
   REGIME_STRONG_BEAR_TREND=1,
   REGIME_RANGING=2,
   REGIME_HIGH_VOLATILITY=3,
   REGIME_LOW_VOLATILITY=4,
   REGIME_BREAKOUT=5,
   REGIME_CONSOLIDATION=6,
   REGIME_CHOPPY=7,
   REGIME_POTENTIAL_REVERSAL=8
  };

enum ENUM_ACTIVE_STRATEGY
  {
   STRAT_GRID=0,
   STRAT_MOMENTUM=1,
   STRAT_TREND=2,
   STRAT_BREAKOUT=3,
   STRAT_WAIT=4
  };

input group "=== XAUUSD / Safety ==="
input bool   InpXAUUSDOnly=true;
input int    InpMagicNumber=990022;
input double InpRiskPerTradePct=0.50;
input double InpBaseLot=0.01;          // fallback lot if risk-based sizing can't be computed
input double InpMaxLot=0.50;
input double InpMaxTotalLots=2.00;
input int    InpMaxOpenPositions=4;
input double InpMinTradeSpacingPoints=150.0;
input double InpMaxDailyLossPct=5.0;
input double InpMaxDrawdownPct=10.0;
input double InpMinMarginLevelPct=200.0;
input double InpMaxSpreadPrice=2.50;
input double InpMaxATRPrice=15.0;

input group "=== Strategy Selection ==="
input bool   InpEnableGrid=true;
input bool   InpEnableMomentum=true;
input bool   InpEnableTrend=true;
input bool   InpEnableBreakout=true;
input double InpMinStrategyConfidence=60.0;
input int    InpStrategySwitchCooldownMin=0;

input group "=== Technical Indicators ==="
input ENUM_TIMEFRAMES InpRegimeTF=PERIOD_M5;
input int    InpADXPeriod=14;
input int    InpFastEMAPeriod=20;
input int    InpSlowEMAPeriod=50;
input int    InpATRPeriod=14;
input int    InpStructureLookback=20;

input group "=== Stops & Targets ==="
input double InpStopLossATR=2.0;
input double InpTakeProfitATR=3.5;
input bool   InpUseTrailing=true;
input double InpTrailStartATR=1.5;
input double InpTrailStepATR=0.8;

input group "=== Profit Taking ==="
input bool   InpUseBreakeven=true;
input double InpBreakevenATR=1.0;        // profit (in ATR multiples) that triggers moving SL to breakeven
input double InpBreakevenBufferPoints=20.0; // SL placed this many points beyond entry, to cover costs
input bool   InpUsePartialClose=true;
input double InpPartialCloseATR=1.5;     // profit (in ATR multiples) that triggers the partial close
input double InpPartialClosePct=50.0;    // percent of position volume to close at that milestone
input bool   InpUseDailyProfitTarget=true;
input double InpMaxDailyProfitPct=3.0;   // close everything and stop for the day once equity gain hits this %

int g_adx=INVALID_HANDLE, g_fast=INVALID_HANDLE, g_slow=INVALID_HANDLE, g_atr=INVALID_HANDLE;
double g_dayStartEquity=0.0, g_peakEquity=0.0;
int g_day=-1;
ENUM_MARKET_REGIME g_regime=REGIME_CHOPPY;
ENUM_ACTIVE_STRATEGY g_strategy=STRAT_WAIT;
string g_blockReason="";   // why new entries are currently gated, shown on HUD
bool g_dailyProfitLocked=false;   // true once the daily profit target has closed everything for today
ulong g_partialClosedTickets[];   // tickets that have already had their partial close taken

struct MarketState
  {
   ENUM_MARKET_REGIME regime;
   double adx, atr, fastEMA, slowEMA;
   double momentum, tickBias, spread, roc;
   double breakoutUp, breakoutDown;
  };

struct StrategyScore
  {
   double grid, momentum, trend, breakout;
   double selected;
   ENUM_ACTIVE_STRATEGY best;
  };

bool IsXAU()
  {
   if(!InpXAUUSDOnly) return true;
   string s=_Symbol; StringToUpper(s);
   return StringFind(s,"XAUUSD")>=0;
  }

void ResetDay()
  {
   MqlDateTime d; TimeToStruct(TimeCurrent(),d);
   if(d.day_of_year!=g_day)
     {
      g_day=d.day_of_year;
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      // peak resets to the new day's starting equity too, so drawdown is
      // measured from a sane baseline rather than an old stale high
      g_peakEquity=g_dayStartEquity;
      g_dailyProfitLocked=false; // new day - allow trading again even if yesterday hit its profit target
     }
   double e=AccountInfoDouble(ACCOUNT_EQUITY);
   if(e>g_peakEquity) g_peakEquity=e;
  }

double CopyOne(int handle, int buffer, int shift)
  {
   double x[1];
   if(handle==INVALID_HANDLE || CopyBuffer(handle,buffer,shift,1,x)<1) return 0.0;
   return x[0];
  }

double SpreadPrice()
  {
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return DBL_MAX;
   return t.ask-t.bid;
  }

double TotalLots()
  {
   double x=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         x+=PositionGetDouble(POSITION_VOLUME);
     }
   return x;
  }

int PositionCount()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) n++;
     }
   return n;
  }

double NormalizeLot(double lot)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),InpMaxLot);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=minLot;
   lot=MathMin(maxLot,MathMax(minLot,lot));
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(lot,2);
  }

//+------------------------------------------------------------------+
//| Risk-based lot sizing.                                           |
//| lot = (equity * risk%) / (stopDistance_in_ticks * tickValue)     |
//| Falls back to InpBaseLot if tick value/size aren't available or  |
//| the SL distance is degenerate (avoids div-by-zero / garbage lot).|
//+------------------------------------------------------------------+
double RiskBasedLot(double slDistancePrice)
  {
   if(slDistancePrice<=0) return NormalizeLot(InpBaseLot);

   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0 || tickSize<=0) return NormalizeLot(InpBaseLot);

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount=equity*(InpRiskPerTradePct/100.0);

   double valuePerLot=(slDistancePrice/tickSize)*tickValue; // $ risk per 1.0 lot at this SL distance
   if(valuePerLot<=0) return NormalizeLot(InpBaseLot);

   double lot=riskAmount/valuePerLot;
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Partial-close tracking: a ticket only gets its scale-out once.   |
//+------------------------------------------------------------------+
bool AlreadyPartialClosed(ulong ticket)
  {
   int n=ArraySize(g_partialClosedTickets);
   for(int i=0;i<n;i++) if(g_partialClosedTickets[i]==ticket) return true;
   return false;
  }

void MarkPartialClosed(ulong ticket)
  {
   int n=ArraySize(g_partialClosedTickets);
   ArrayResize(g_partialClosedTickets,n+1);
   g_partialClosedTickets[n]=ticket;
  }

// Drop tickets from the tracking array once the position is no longer open,
// so the array doesn't grow forever over a long-running session.
void CleanupPartialClosedTickets()
  {
   int n=ArraySize(g_partialClosedTickets);
   ulong keep[]; ArrayResize(keep,n);
   int kept=0;
   for(int i=0;i<n;i++)
      if(PositionSelectByTicket(g_partialClosedTickets[i])){ keep[kept]=g_partialClosedTickets[i]; kept++; }
   ArrayResize(g_partialClosedTickets,kept);
   for(int i=0;i<kept;i++) g_partialClosedTickets[i]=keep[i];
  }

void CloseAllPositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         trade.PositionClose(ticket);
     }
  }

// Checks whether today's equity gain has hit the profit target; if so,
// closes every open position from this EA and locks out new entries
// until the next trading day.
void CheckDailyProfitTarget()
  {
   if(!InpUseDailyProfitTarget || g_dailyProfitLocked || g_dayStartEquity<=0) return;
   double dayPnLPct=(AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartEquity)/g_dayStartEquity*100.0;
   if(dayPnLPct>=InpMaxDailyProfitPct)
     {
      CloseAllPositions();
      g_dailyProfitLocked=true;
     }
  }

bool IsFarEnough(double targetPrice)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         if(MathAbs(targetPrice-openPrice)<(InpMinTradeSpacingPoints*_Point))
            return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Returns the direction of currently open positions from this EA. |
//| -1 = none open, otherwise POSITION_TYPE_BUY or POSITION_TYPE_SELL|
//| Used to stop the EA from opening a hedge against its own trades. |
//+------------------------------------------------------------------+
int GetOpenDirection()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return (int)PositionGetInteger(POSITION_TYPE);
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Master gate for opening NEW positions. Does not touch existing   |
//| positions (trailing/management keeps running regardless).        |
//+------------------------------------------------------------------+
bool CanTrade(const MarketState &m)
  {
   g_blockReason="";

   if(g_dailyProfitLocked){ g_blockReason="Daily profit target already reached today"; return false; }
   if(PositionCount()>=InpMaxOpenPositions){ g_blockReason="Max open positions reached"; return false; }
   if(TotalLots()>=InpMaxTotalLots){ g_blockReason="Max total lots reached"; return false; }

   // Daily loss limit
   if(g_dayStartEquity>0)
     {
      double dayPnLPct=(AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartEquity)/g_dayStartEquity*100.0;
      if(dayPnLPct<=-InpMaxDailyLossPct){ g_blockReason="Daily loss limit hit ("+DoubleToString(dayPnLPct,2)+"%)"; return false; }
     }

   // Max drawdown from peak equity
   if(g_peakEquity>0)
     {
      double ddPct=(g_peakEquity-AccountInfoDouble(ACCOUNT_EQUITY))/g_peakEquity*100.0;
      if(ddPct>=InpMaxDrawdownPct){ g_blockReason="Max drawdown hit ("+DoubleToString(ddPct,2)+"%)"; return false; }
     }

   // Margin level (only meaningful once margin is actually in use)
   double marginUsed=AccountInfoDouble(ACCOUNT_MARGIN);
   if(marginUsed>0)
     {
      double marginLevel=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(marginLevel>0 && marginLevel<InpMinMarginLevelPct){ g_blockReason="Margin level too low ("+DoubleToString(marginLevel,1)+"%)"; return false; }
     }

   // Spread filter
   if(m.spread>InpMaxSpreadPrice){ g_blockReason="Spread too wide ("+DoubleToString(m.spread,2)+")"; return false; }

   // Volatility filter
   if(m.atr>InpMaxATRPrice){ g_blockReason="ATR too high ("+DoubleToString(m.atr,2)+")"; return false; }

   return true;
  }

MarketState AnalyseMarket()
  {
   MarketState m;
   m.adx=CopyOne(g_adx,0,1);
   m.atr=CopyOne(g_atr,0,1);
   m.fastEMA=CopyOne(g_fast,0,1);
   m.slowEMA=CopyOne(g_slow,0,1);
   m.spread=SpreadPrice();

   MqlRates r[]; ArraySetAsSeries(r,true);
   m.breakoutUp=0; m.breakoutDown=0;
   if(CopyRates(_Symbol,InpRegimeTF,1,InpStructureLookback+2,r)>=InpStructureLookback+2)
     {
      double hh=-DBL_MAX, ll=DBL_MAX;
      for(int i=1;i<=InpStructureLookback;i++){hh=MathMax(hh,r[i].high); ll=MathMin(ll,r[i].low);}
      if(r[0].close>hh) m.breakoutUp=1.0;
      if(r[0].close<ll) m.breakoutDown=1.0;
     }

   if(m.breakoutUp>0 || m.breakoutDown>0) m.regime=REGIME_BREAKOUT;
   else if(m.adx>=22.0 && m.fastEMA>m.slowEMA) m.regime=REGIME_STRONG_BULL_TREND;
   else if(m.adx>=22.0 && m.fastEMA<m.slowEMA) m.regime=REGIME_STRONG_BEAR_TREND;
   else m.regime=REGIME_RANGING;

   return m;
  }

StrategyScore ScoreStrategies(const MarketState &m)
  {
   StrategyScore s;
   s.grid=0; s.momentum=0; s.trend=0; s.breakout=0;

   if(m.regime==REGIME_BREAKOUT) s.breakout=85.0;
   if(m.regime==REGIME_STRONG_BULL_TREND || m.regime==REGIME_STRONG_BEAR_TREND) s.trend=80.0;
   if(m.regime==REGIME_RANGING) s.grid=75.0;
   s.momentum=70.0;

   double best=0;
   s.best=STRAT_WAIT;

   if(InpEnableBreakout && s.breakout>best){best=s.breakout; s.best=STRAT_BREAKOUT;}
   if(InpEnableTrend && s.trend>best){best=s.trend; s.best=STRAT_TREND;}
   if(InpEnableMomentum && s.momentum>best){best=s.momentum; s.best=STRAT_MOMENTUM;}
   if(InpEnableGrid && s.grid>best){best=s.grid; s.best=STRAT_GRID;}

   s.selected=best;
   return s;
  }

void ExecuteDirectOrder(ENUM_ACTIVE_STRATEGY strat, const MarketState &m)
  {
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;

   ENUM_POSITION_TYPE dir=POSITION_TYPE_BUY;
   if(strat==STRAT_BREAKOUT)
      dir=(m.breakoutUp>0)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   else if(strat==STRAT_TREND || strat==STRAT_MOMENTUM)
      dir=(m.fastEMA>m.slowEMA)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   else
      dir=(t.ask<m.fastEMA)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;

   double entryPrice=(dir==POSITION_TYPE_BUY)?t.ask:t.bid;
   if(!IsFarEnough(entryPrice)) return;

   // Don't hedge against ourselves: once a direction is open, only allow
   // more trades on that same side until it's flat again.
   int openDir=GetOpenDirection();
   if(openDir!=-1 && openDir!=(int)dir) return;

   double slDistance=MathMax(m.atr*InpStopLossATR, 200*_Point);
   double tpDistance=MathMax(m.atr*InpTakeProfitATR, 300*_Point);
   double sl=(dir==POSITION_TYPE_BUY)?entryPrice-slDistance:entryPrice+slDistance;
   double tp=(dir==POSITION_TYPE_BUY)?entryPrice+tpDistance:entryPrice-tpDistance;

   double lot=RiskBasedLot(slDistance);

   // Re-check the total-lot cap AFTER computing the intended lot, not before,
   // so a trade can't push total volume past InpMaxTotalLots.
   if(TotalLots()+lot>InpMaxTotalLots)
     {
      lot=NormalizeLot(InpMaxTotalLots-TotalLots());
      if(lot<=0) return;
     }

   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(lot<minLot) return; // computed risk lot rounds to nothing tradeable - skip rather than over-risk with a forced min lot

   if(dir==POSITION_TYPE_BUY)
      trade.Buy(lot,_Symbol,entryPrice,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),"Adaptive_Buy");
   else
      trade.Sell(lot,_Symbol,entryPrice,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),"Adaptive_Sell");
  }

void ManagePositions(const MarketState &m)
  {
   CleanupPartialClosedTickets();
   if(m.atr<=0) return;

   double beDist=m.atr*InpBreakevenATR;
   double pcDist=m.atr*InpPartialCloseATR;
   double startDist=m.atr*InpTrailStartATR;
   double stepDist=m.atr*InpTrailStepATR;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL=PositionGetDouble(POSITION_SL);
         double currentTP=PositionGetDouble(POSITION_TP);
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double profitDist=(type==POSITION_TYPE_BUY)?(bid-openPrice):(openPrice-ask);

         // --- 1) Breakeven lock: once far enough in profit, SL moves to
         //     entry + a small buffer so this trade can no longer lose money.
         if(InpUseBreakeven && profitDist>=beDist)
           {
            double beSL=(type==POSITION_TYPE_BUY)
                        ? NormalizeDouble(openPrice+InpBreakevenBufferPoints*_Point,_Digits)
                        : NormalizeDouble(openPrice-InpBreakevenBufferPoints*_Point,_Digits);
            bool improves=(type==POSITION_TYPE_BUY)?(currentSL==0.0 || beSL>currentSL):(currentSL==0.0 || beSL<currentSL);
            if(improves && trade.PositionModify(ticket,beSL,currentTP))
               currentSL=beSL; // keep local state in sync for the trailing check below, same tick
           }

         // --- 2) Partial close: lock in real money at a profit milestone,
         //     once per position, and let the remainder keep running.
         if(InpUsePartialClose && !AlreadyPartialClosed(ticket) && profitDist>=pcDist)
           {
            double vol=PositionGetDouble(POSITION_VOLUME);
            double closeVol=NormalizeLot(vol*(InpPartialClosePct/100.0));
            double remaining=NormalizeLot(vol-closeVol);
            if(closeVol>=minLot && remaining>=minLot)
              {
               if(trade.PositionClosePartial(ticket,closeVol))
                  MarkPartialClosed(ticket);
              }
            else
              {
               // Position too small to split without leaving a sub-minimum
               // remainder - skip the split but don't keep re-checking it every tick.
               MarkPartialClosed(ticket);
              }
           }

         // --- 3) Trailing stop (unchanged logic, now starting from
         //     whatever SL the breakeven step above may have just set).
         if(InpUseTrailing)
           {
            if(type==POSITION_TYPE_BUY)
              {
               if(bid-openPrice>=startDist)
                 {
                  double newSL=NormalizeDouble(bid-stepDist,_Digits);
                  if(currentSL==0.0 || newSL>currentSL+(_Point*10)) trade.PositionModify(ticket,newSL,currentTP);
                 }
              }
            else if(type==POSITION_TYPE_SELL)
              {
               if(openPrice-ask>=startDist)
                 {
                  double newSL=NormalizeDouble(ask+stepDist,_Digits);
                  if(currentSL==0.0 || newSL<currentSL-(_Point*10)) trade.PositionModify(ticket,newSL,currentTP);
                 }
              }
           }
        }
     }
  }

int OnInit()
  {
   if(!IsXAU()){Print("ERROR: Run on XAUUSD chart only."); return INIT_FAILED;}

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);

   uint filling=(uint)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC)!=0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((filling & SYMBOL_FILLING_FOK)!=0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_adx=iADX(_Symbol,InpRegimeTF,InpADXPeriod);
   g_fast=iMA(_Symbol,InpRegimeTF,InpFastEMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_slow=iMA(_Symbol,InpRegimeTF,InpSlowEMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_atr=iATR(_Symbol,InpRegimeTF,InpATRPeriod);

   if(g_adx==INVALID_HANDLE || g_fast==INVALID_HANDLE || g_slow==INVALID_HANDLE || g_atr==INVALID_HANDLE)
      return INIT_FAILED;

   // Initialize equity baselines immediately so the first tick's risk
   // checks aren't comparing against zero.
   g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity=g_dayStartEquity;
   g_dailyProfitLocked=false;
   ArrayFree(g_partialClosedTickets);
   MqlDateTime d; TimeToStruct(TimeCurrent(),d);
   g_day=d.day_of_year;

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(g_adx);
   IndicatorRelease(g_fast);
   IndicatorRelease(g_slow);
   IndicatorRelease(g_atr);
   Comment("");
  }

void OnTick()
  {
   if(!IsXAU()) return;
   ResetDay();

   MarketState m=AnalyseMarket();
   g_regime=m.regime;

   StrategyScore scores=ScoreStrategies(m);
   g_strategy=scores.best;

   CheckDailyProfitTarget();
   ManagePositions(m);

   bool allowed=CanTrade(m);
   if(allowed && g_strategy!=STRAT_WAIT && scores.selected>=InpMinStrategyConfidence)
     {
      ExecuteDirectOrder(g_strategy,m);
     }

   string hud="=== XAUUSD ADAPTIVE MULTI-STRATEGY v4.13 ===\n";
   hud+="Regime: "+EnumToString(g_regime)+"\n";
   hud+="Active Strategy: "+EnumToString(g_strategy)+" (Confidence: "+DoubleToString(scores.selected,1)+"%)\n";
   int openDirHud=GetOpenDirection();
   hud+="Locked Direction: "+(openDirHud==-1?"none (flat)":(openDirHud==POSITION_TYPE_BUY?"BUY":"SELL"))+"\n";
   hud+="Open Positions: "+IntegerToString(PositionCount())+" / "+IntegerToString(InpMaxOpenPositions)+"\n";
   hud+="Total Volume: "+DoubleToString(TotalLots(),2)+" / "+DoubleToString(InpMaxTotalLots,2)+" Lots\n";
   hud+="Spread: "+DoubleToString(m.spread,2)+" | ATR: "+DoubleToString(m.atr,2)+"\n";
   double dayPnLPct=(g_dayStartEquity>0)?((AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartEquity)/g_dayStartEquity*100.0):0.0;
   hud+="Day Equity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+" (start "+DoubleToString(g_dayStartEquity,2)+", peak "+DoubleToString(g_peakEquity,2)+", "+DoubleToString(dayPnLPct,2)+"%)\n";
   hud+="Daily Profit Target: "+DoubleToString(InpMaxDailyProfitPct,2)+"% "+(g_dailyProfitLocked?"[HIT - locked for today]":"")+"\n";
   hud+= allowed ? "New Entries: ALLOWED" : ("New Entries: BLOCKED - "+g_blockReason);
   Comment(hud);
  }
//+------------------------------------------------------------------+
