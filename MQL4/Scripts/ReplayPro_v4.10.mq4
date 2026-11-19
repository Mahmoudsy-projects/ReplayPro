//+------------------------------------------------------------------+
//| ReplayPro.mq4 - Candle-by-candle replay on an offline chart      |
//| - Future candles do NOT exist on the chart (no scale leak)       |
//| - Builds M1,M5,M15,M30,H1,H4 files (open them via Open Offline)  |
//| - Risk-% sizing, structure SL via draggable line                 |
//| - Trade management: BE, tighten/loosen, set SL/TP, trailing      |
//| - Session stats: totals, R, drawdown, per-day results            |
//| - Jump to any date                                               |
//| - ReplayTF: M1 (precise, ~3 weeks) or M5 (coarser, ~3.5 months) |
//| Run as SCRIPT on the symbol chart (e.g. XAUUSD@). NO DLL needed (v4.00).|
//+------------------------------------------------------------------+
#property strict
#property show_inputs

// v4.10: new on-chart panel in the Risk Manager "Mono Gray" look (header, Trade/Tools tabs, status / info / message boxes).
//        Trading logic is unchanged from v4.00 (same buttons, same execution method).
// v4.00 (NO DLL): the two DLL imports are gone.
//  - chart refresh: ChartSetSymbolPeriod() on every open offline window (tested on RPTEST: smooth at 2 bars/s, drawings survive)
//  - dashboard: the script only writes MQL4\\Files\\RP_data.txt; open RP_Dashboard.html in Chrome yourself (bookmark) and press F5.

input string          StartTime    = "2026.10.08 10:00"; // Replay start (SERVER time)
input ENUM_TIMEFRAMES DisplayTF    = PERIOD_M5;          // Timeframe you expect to open first
input ENUM_TIMEFRAMES ReplayTF     = PERIOD_M5;         // Replay data: M1 (precise) or M5 (goes further back)
input int             PreloadBars  = 3000;               // History bars per timeframe
input double          StartBalance = 10000.0;            // Virtual account balance
input double          RiskPercent  = 0.5;                // Risk per trade (% of balance)
input double          TP_R         = 2.0;                // TP in R multiples (0 = no TP)
input int             ServerUtcOffsetMin = 180;          // Broker server offset in US-DST/SUMMER (min): 180 = UTC+3, winter = -60 auto (Key Time)
input double          SpreadPrice  = 0.30;              // Spread in price units ($)
input double          ContractSize = 100.0;              // XAU: 1 lot = 100 oz
input double          LotStep      = 0.01;
input double          MinLot       = 0.01;
input double          MaxLot       = 50.0;
input double          InitSLDist   = 3.0;                // Where the SL line starts ($ from price)
input double          StepDollar   = 1.0;                // Default step for Tight/Loose ($)
input double          TrailDollar  = 3.0;                // Default trailing distance ($)
input int             PlayDelayMs  = 300;                // Delay per 1-min step in Play
input string          BatchName    = "";                 // Batch name. EMPTY = use the last one. New name = new batch
input int             BatchTarget  = 100;                // Trades you want in this batch (shown as 37/100)
input string          StrategyFile = "RM_StrategySetups.txt"; // Strategy/setup list (MQL4\Files). Created with defaults if missing
input string          ChartTemplate = "";                // Optional: name of a saved MT4 template. Empty = off
input bool            UseLook      = true;               // Apply the chart look below to every replay window
input bool            ShowGrid     = false;              // Grid on/off
input bool            UseCandles   = true;               // true = candlesticks, false = bars
input color           ColBack      = clrBlack;           // Chart background
input color           ColFore      = clrSilver;          // Axis / text color
input color           ColBull      = C'38,166,154';      // Up candle color
input color           ColBear      = C'239,83,80';       // Down candle color

#define MAXT 50
#define NTF  6
#define HMAX 1000
#define NSTAT 60
#define NG    200
#define MAXCAT 12
#define MAXSET 20

int      TFS[NTF] = {1, 5, 15, 30, 60, 240};

string   src, offSym;
int      digitsV, delayMs;
int      hF[NTF], fOff[NTF];
datetime fS[NTF];
double   fO[NTF], fH[NTF], fL[NTF], fC[NTF], fV[NTF];
long     cid = 0;
int      rTF = PERIOD_M1;   // replay source timeframe (1 or 5)
datetime lastT = 0, startT = 0;
int      idx = -1;          // shift of the NEXT M1 bar to replay
double   lastBid = 0;

int      tN = 0, nextId = 1, selId = 0;
int      tId[MAXT], tType[MAXT];
datetime tTime[MAXT];
double   tEntry[MAXT], tLots[MAXT], tSL[MAXT], tTP[MAXT], tRisk[MAXT], tTrail[MAXT];
string   tCat[MAXT], tStp[MAXT];      // strategy tag of each open trade (category / setup)
double   closedPL = 0, sumR = 0;
int      nWin = 0, nLoss = 0;
string   lastMsg = "";
string   bName = "", fLog = "", fSum = "", fState = "";
string   sRisk = "", sTpr = "", sStep = "", sTrl = "";   // panel values remembered per batch
uint     rstTick = 0;
bool     pOn = false, pFilled = false;   // pending line exists / just filled
string   pTxt = "";
string   tplName = "";
long     thId[20];
int      nTh = 0;
int      stepCnt = 0;

// closed-trade history (for stats)
int      hN = 0;
datetime hT[HMAX];
double   hR[HMAX], hP[HMAX];
string   hCat[HMAX], hStp[HMAX];

// strategy / setup list (loaded from StrategyFile)
int      nCat = 0, curCat = 0, curSet = 0;
string   gCat[MAXCAT];
string   gSetup[MAXCAT][MAXSET];
int      gSetN[MAXCAT];
string   sTagC = "", sTagS = "";      // last selection remembered per batch
string   pCat = "", pStp = "";        // tag captured when the pending line was added

//--------------------------------------------------------------------
// STRATEGY LIST
// File format, one strategy per line:   STRATEGY_NAME: SETUP_1, SETUP_2, SETUP_3
string CleanStr(string s)
{
   string o = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      int ch = StringGetChar(s, i);
      if(ch < 32 || ch > 126 || ch == ';') continue;     // drops BOM / odd bytes / CSV separator
      o = o + CharToStr((uchar)ch);
   }
   StringTrimLeft(o);
   StringTrimRight(o);
   return(o);
}
void AddCat(string name, string list)
{
   if(nCat >= MAXCAT) return;
   name = CleanStr(name);
   if(name == "") return;
   string parts[];
   int n = StringSplit(list, ',', parts);
   int c = nCat;
   gCat[c] = name;
   gSetN[c] = 0;
   for(int i = 0; i < n && gSetN[c] < MAXSET; i++)
   {
      string s = CleanStr(parts[i]);
      if(s == "") continue;
      gSetup[c][gSetN[c]] = s;
      gSetN[c]++;
   }
   if(gSetN[c] == 0) { gSetup[c][0] = "GENERAL"; gSetN[c] = 1; }
   nCat++;
}
bool ReadStrategyFile(int extra)
{
   int f = FileOpen(StrategyFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | extra);
   if(f < 0) return(false);
   nCat = 0;
   while(!FileIsEnding(f))
   {
      string ln = FileReadString(f);
      int p = StringFind(ln, ":");
      if(p <= 0) continue;
      AddCat(StringSubstr(ln, 0, p), StringSubstr(ln, p + 1));
   }
   FileClose(f);
   return(nCat > 0);
}
void LoadStrategies()
{
   if(ReadStrategyFile(0) || ReadStrategyFile(FILE_COMMON)) return;
   // no file found: use the built-in list and write it out so it can be edited
   nCat = 0;
   AddCat("CYCLE_MATURITY",  "REJECTION_CANDLE, MTR_PB, MTR_LINE_BREAK, MTR_BREAKEVEN_RETEST, TR-BREAKOUT");
   AddCat("SPIKE_TRADING",   "BREAKOUT_CANDLE, SP2L_FIRST_PB_CANDLE, SP2L_50, BTB");
   AddCat("CHANNEL_TRADING", "TREND_LINE_TOUCH, PREVIOUS_LEG_50, REJECTION_CANDLE");
   AddCat("RANGE_TRADING",   "EDGE_LIMIT, REJECTION_CANDLE");
   int f = FileOpen(StrategyFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(f >= 0)
   {
      for(int c = 0; c < nCat; c++)
      {
         string l = gCat[c] + ": ";
         for(int s = 0; s < gSetN[c]; s++) l = l + (s > 0 ? ", " : "") + gSetup[c][s];
         FileWrite(f, l);
      }
      FileClose(f);
   }
}
string TagC() { return(nCat > 0 ? gCat[curCat] : "UNTAGGED"); }
string TagS() { return(nCat > 0 ? gSetup[curCat][curSet] : ""); }
string TagFull(string c, string s) { return(s == "" ? c : c + "/" + s); }
void RestoreTag()
{
   curCat = 0; curSet = 0;
   for(int c = 0; c < nCat; c++)
      if(gCat[c] == sTagC)
      {
         curCat = c;
         for(int s = 0; s < gSetN[c]; s++) if(gSetup[c][s] == sTagS) { curSet = s; break; }
         break;
      }
}

//--------------------------------------------------------------------
datetime BarStart(int k, datetime t)
{
   int  secs = TFS[k] * 60;
   long x = (long)t - fOff[k];
   long r = x % secs;
   if(r < 0) r += secs;
   return (datetime)((long)t - r);
}
int KOf(int tf)
{
   for(int k = 0; k < NTF; k++) if(TFS[k] == tf) return k;
   return 2;
}
datetime DayKey(datetime t) { return (datetime)((long)t - (long)t % 86400); }
//--------------------------------------------------------------------
void WriteHeader(int h, int tf)
{
   FileWriteInteger(h, 400, LONG_VALUE);
   FileWriteString(h, "Replay", 64);
   FileWriteString(h, offSym, 12);
   FileWriteInteger(h, tf, LONG_VALUE);
   FileWriteInteger(h, digitsV, LONG_VALUE);
   FileWriteInteger(h, 0, LONG_VALUE);
   FileWriteInteger(h, 0, LONG_VALUE);
   for(int i = 0; i < 13; i++) FileWriteInteger(h, 0, LONG_VALUE);
}
void WriteBar(int h, datetime t, double o, double hi, double lo, double c, double v)
{
   FileWriteInteger(h, (int)t, LONG_VALUE);
   FileWriteDouble(h, o);
   FileWriteDouble(h, lo);
   FileWriteDouble(h, hi);
   FileWriteDouble(h, c);
   FileWriteDouble(h, v);
}
string HstName(int k) { return offSym + IntegerToString(TFS[k]) + ".hst"; }
//--------------------------------------------------------------------
bool OpenFiles()
{
   for(int k = 0; k < NTF; k++)
   {
      if(TFS[k] < rTF) continue;
      hF[k] = FileOpenHistory(HstName(k), FILE_BIN | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(hF[k] < 0)
      {
         lastMsg = "Cannot open history file M" + IntegerToString(TFS[k]) + " err " + IntegerToString(GetLastError());
         return false;
      }
      FileSeek(hF[k], 0, SEEK_END);
   }
   return true;
}
void CloseFiles()
{
   for(int k = 0; k < NTF; k++)
      if(hF[k] >= 0) { FileClose(hF[k]); hF[k] = -1; }
}
//--------------------------------------------------------------------
// Writes fresh history files for every timeframe, ending right before t0.
// Leaves all files CLOSED. Returns false (nothing touched) if data is missing.
// checks that replay data exists near t0 (does NOT touch anything); returns the shift of the first bar to replay
bool CheckData(datetime t0, int &s)
{
   string tfn = (rTF == PERIOD_M5) ? "M5" : "M1";
   s = iBarShift(src, rTF, t0, false);
   if(s < 0) { lastMsg = "No " + tfn + " data for that date. Load more history."; return false; }
   if(iTime(src, rTF, s) < t0) s--;
   if(s < 0) { lastMsg = "No " + tfn + " data after that date."; return false; }
   if(s + 2 > iBars(src, rTF) - 1) { lastMsg = "Not enough " + tfn + " history before that date."; return false; }

   datetime tFirst = iTime(src, rTF, s);
   // v3.74: the requested time may sit INSIDE a data hole that ends less than 3 days after it. Then the first replayed bar is
   // fine, but the bar before it (the "last bar" that gets drawn) is weeks older -> the chart would silently start before the hole.
   datetime tPrev = iTime(src, rTF, s + 1);
   if(tFirst - t0 <= 3 * 86400 && t0 - tPrev > 3 * 86400)
   {
      string hint0 = (rTF == PERIOD_M1) ? " Try ReplayTF=M5." : " Load more history.";
      lastMsg = tfn + " data hole: " + TimeToString(tPrev, TIME_DATE | TIME_MINUTES) + " -> " +
                TimeToString(tFirst, TIME_DATE | TIME_MINUTES) + "." + hint0;
      return false;
   }
   if(tFirst - t0 > 3 * 86400)
   {
      string hint = (rTF == PERIOD_M1) ? " Try ReplayTF=M5." : " Load more history.";
      if(s + 1 < iBars(src, rTF))      // older bar exists -> there is a HOLE in the data: show both edges
         lastMsg = tfn + " data hole: " + TimeToString(iTime(src, rTF, s + 1), TIME_DATE | TIME_MINUTES) + " -> " +
                   TimeToString(tFirst, TIME_DATE | TIME_MINUTES) + "." + hint;
      else
         lastMsg = tfn + " data starts only at " + TimeToString(tFirst, TIME_DATE | TIME_MINUTES) + "." + hint;
      return false;
   }
   return true;
}
bool BuildAll(datetime t0)
{
   int s;
   if(!CheckData(t0, s)) return false;
   datetime tFirst = iTime(src, rTF, s);

   for(int k = 0; k < NTF; k++)
   {
      int tf = TFS[k];
      int h = FileOpenHistory(HstName(k), FILE_BIN | FILE_WRITE | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h < 0) { lastMsg = "Cannot write history file M" + IntegerToString(tf) + " err " + IntegerToString(GetLastError()); return false; }
      WriteHeader(h, tf);
      if(tf < rTF)
      {
         // timeframe finer than the replay data: leave the file EMPTY (no stale/future bars)
         fS[k] = 0;
         FileFlush(h);
         FileClose(h);
         continue;
      }

      datetime bs0 = BarStart(k, tFirst);

      // 1) completed native bars strictly before the bar that contains the start
      int e = iBarShift(src, tf, bs0 - 1, false);
      if(e >= 0)
      {
         if(iTime(src, tf, e) >= bs0) e++;
         int last = MathMin(e + PreloadBars - 1, iBars(src, tf) - 1);
         for(int j = last; j >= e; j--)
            WriteBar(h, iTime(src, tf, j), iOpen(src, tf, j), iHigh(src, tf, j),
                     iLow(src, tf, j), iClose(src, tf, j), (double)iVolume(src, tf, j));
      }

      // 2) partial bar containing the start, built from M1 up to the start
      bool have = false;
      int m = iBarShift(src, rTF, bs0, false);
      if(m >= 0 && iTime(src, rTF, m) < bs0) m--;
      for(int q = m; q > s; q--)
      {
         double o = iOpen(src, rTF, q), hi = iHigh(src, rTF, q);
         double lo = iLow(src, rTF, q), c = iClose(src, rTF, q);
         double v = (double)iVolume(src, rTF, q);
         if(!have) { fS[k] = bs0; fO[k] = o; fH[k] = hi; fL[k] = lo; fC[k] = c; fV[k] = v; have = true; }
         else
         {
            if(hi > fH[k]) fH[k] = hi;
            if(lo < fL[k]) fL[k] = lo;
            fC[k] = c; fV[k] += v;
         }
      }
      if(have) WriteBar(h, fS[k], fO[k], fH[k], fL[k], fC[k], fV[k]);
      else fS[k] = 0;

      FileFlush(h);
      FileClose(h);
   }

   idx = s;
   lastBid = iClose(src, rTF, s + 1);
   lastT = iTime(src, rTF, s + 1);
   return true;
}
//--------------------------------------------------------------------
void Refresh()
{
   // v4.00: no DLL. Re-load the .hst of every open offline window of this symbol.
   long c = ChartFirst();
   while(c >= 0)
   {
      if(ChartSymbol(c) == offSym)
         ChartSetSymbolPeriod(c, offSym, ChartPeriod(c));
      c = ChartNext(c);
   }
}
//--------------------------------------------------------------------
// UI helpers  (panel is docked to the RIGHT edge, vertical)
#define PW  220      // panel width (v4.10: wider, Risk-Manager look)
#define PM  4        // margin from the chart's right edge
#define PIN 6        // inner padding   -> inner width 208
// Mono Gray palette (same as Risk Manager)
#define MG_BG     C'228,228,228'
#define MG_BORDER C'176,176,176'
#define MG_FACE   C'242,242,242'
#define MG_DARK   C'122,122,122'
#define MG_TEXT   C'43,43,43'
#define MG_CAP    C'105,105,105'
#define MG_HEAD   C'74,74,74'
#define MG_STATUS C'212,212,212'
#define MG_INFO   C'220,220,220'
#define MG_ACTIVE C'14,124,134'
#define MG_DANGER C'160,40,40'
// registry of panel objects per tab (tab 0 = always visible)
string rgN[160];
int    rgT[160];
int    rgX[160];
int    rgCnt = 0;
int    gTab = 0;          // tab that objects created right now belong to
int    curTab = 1;
int    tgPrev[4];
int Xr(int x, int w) { return PM + PIN + (PW - 2 * PIN) - x; }   // distance: chart right edge -> object LEFT edge
void Reg(string n)
{
   if(rgCnt >= 160) return;
   rgN[rgCnt] = n;
   rgT[rgCnt] = gTab;
   rgX[rgCnt] = (int)ObjectGetInteger(cid, n, OBJPROP_XDISTANCE);
   rgCnt++;
}
void StyleBtn(string n, bool on)
{
   if(ObjectFind(cid, n) < 0) return;
   ObjectSetInteger(cid, n, OBJPROP_BGCOLOR, on ? MG_ACTIVE : MG_FACE);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, on ? clrWhite : MG_TEXT);
}
void SetTab(int t)
{
   curTab = t;
   for(int i = 0; i < rgCnt; i++)
   {
      if(rgT[i] == 0) continue;
      ObjectSetInteger(cid, rgN[i], OBJPROP_XDISTANCE, (rgT[i] == t) ? rgX[i] : rgX[i] + 6000);   // parked far off-screen
   }
   for(int k = 1; k <= 3; k++) StyleBtn("RP_tab" + IntegerToString(k), k == t);
   ChartRedraw(cid);
}
void ApplyToggles()
{
   string tn[4] = {"RP_play", "RP_pd", "RP_wm", "RP_kt"};
   for(int i = 0; i < 4; i++)
   {
      int st = (ObjectGetInteger(cid, tn[i], OBJPROP_STATE) != 0) ? 1 : 0;
      if(st != tgPrev[i]) { tgPrev[i] = st; StyleBtn(tn[i], st == 1); }
   }
}
// kind: 0 normal, 1 toggle, 2 danger text, 3 big (BUY/SELL)
void Btn(string n, string txt, int x, int y, int w, int kind = 0, int h = 24)
{
   ObjectCreate(cid, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, Xr(x, w));
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(cid, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(cid, n, OBJPROP_BGCOLOR, MG_FACE);
   ObjectSetInteger(cid, n, OBJPROP_BORDER_COLOR, MG_DARK);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, (kind == 2) ? MG_DANGER : MG_TEXT);
   ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, (kind == 3) ? 9 : 8);
   ObjectSetInteger(cid, n, OBJPROP_STATE, false);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
   Reg(n);
}
void Rect(string n, int x, int y, int w, int h, color bg, color bd)
{
   ObjectCreate(cid, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, Xr(x, w));
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(cid, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(cid, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(cid, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, bd);
   ObjectSetInteger(cid, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(cid, n, OBJPROP_HIDDEN, true);
   Reg(n);
}
void Lbl(string n, string txt, int x, int y, color clr)
{
   ObjectCreate(cid, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(cid, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, PM + PIN + (PW - 2 * PIN) - x);
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, 8);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
   Reg(n);
}
void Edt(string n, string txt, int x, int y, int w)
{
   ObjectCreate(cid, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, Xr(x, w));
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(cid, n, OBJPROP_YSIZE, 22);
   ObjectSetInteger(cid, n, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(cid, n, OBJPROP_BORDER_COLOR, MG_BORDER);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, MG_TEXT);
   ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, 8);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
   Reg(n);
}
void SetLbl(string n, string txt)
{
   if(ObjectFind(cid, n) >= 0) ObjectSetString(cid, n, OBJPROP_TEXT, txt);
}
// text split over up to 3 labels (prefix1..prefix3), ~30 chars each
void SetWrap(string prefix, string txt)
{
   int w = 32;
   for(int i = 1; i <= 3; i++)
   {
      string part = "";
      if(StringLen(txt) > 0)
      {
         int cut = w;
         if(StringLen(txt) > w)
         {
            cut = -1;
            for(int k = w; k > w / 2; k--)          // break at the last space inside the line
               if(StringGetCharacter(txt, k) == ' ') { cut = k; break; }
            if(cut < 0) cut = w;
         }
         part = StringSubstr(txt, 0, cut);
         txt = StringSubstr(txt, cut);
         if(StringGetCharacter(txt, 0) == ' ') txt = StringSubstr(txt, 1);
      }
      SetLbl(prefix + IntegerToString(i), part);
   }
}
bool Pressed(string n)
{
   if(ObjectGetInteger(cid, n, OBJPROP_STATE) != 0)
   {
      ObjectSetInteger(cid, n, OBJPROP_STATE, false);
      return true;
   }
   return false;
}
double ReadEdit(string n) { return StringToDouble(ObjectGetString(cid, n, OBJPROP_TEXT)); }

void DrawLine(string n, double p, color clr, int style, bool selectable, int width)
{
   ObjectCreate(cid, n, OBJ_HLINE, 0, 0, p);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(cid, n, OBJPROP_STYLE, style);
   ObjectSetInteger(cid, n, OBJPROP_WIDTH, width);
   ObjectSetInteger(cid, n, OBJPROP_SELECTABLE, selectable);
}

void UpdateTagButtons()
{
   if(ObjectFind(cid, "RP_strat") >= 0) ObjectSetString(cid, "RP_strat", OBJPROP_TEXT, TagC());
   if(ObjectFind(cid, "RP_setup") >= 0) ObjectSetString(cid, "RP_setup", OBJPROP_TEXT, TagS());
}
void CycleCat()
{
   if(nCat == 0) return;
   curCat = (curCat + 1) % nCat;
   curSet = 0;
   UpdateTagButtons();
   lastMsg = "Tag: " + TagFull(TagC(), TagS());
}
void CycleSetup()
{
   if(nCat == 0) return;
   curSet = (curSet + 1) % gSetN[curCat];
   UpdateTagButtons();
   lastMsg = "Tag: " + TagFull(TagC(), TagS());
}

void BuildUI()
{
   rgCnt = 0; gTab = 0;
   ArrayInitialize(tgPrev, -1);
   // outer panel (created first so it stays behind everything)
   ObjectCreate(cid, "RP_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_XDISTANCE, PM + PW);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_YDISTANCE, 2);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_XSIZE, PW);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_YSIZE, 580);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_BGCOLOR, MG_BG);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_COLOR, MG_BORDER);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(cid, "RP_bg", OBJPROP_HIDDEN, true);

   // ---- always visible: header, tabs, status box, info box, message box
   Rect("RP_hd", 0, 6, 208, 24, MG_HEAD, MG_HEAD);
   Lbl("RP_ttl", "REPLAY PRO  v4.10", 10, 12, clrWhite);
   Btn("RP_tab1", "Trade",  0,   36, 102);
   Btn("RP_tab3", "Tools",  106, 36, 102);
   Rect("RP_stbox", 0, 66, 208, 68, MG_STATUS, MG_BORDER);
   Rect("RP_ifbox", 0, 432, 208, 84, MG_INFO, MG_BORDER);
   Rect("RP_mgbox", 0, 522, 208, 50, MG_INFO, MG_BORDER);
   for(int i = 1; i <= 4; i++) Lbl("RP_i" + IntegerToString(i), "", 8, 71 + (i - 1) * 15, MG_TEXT);
   for(int i = 1; i <= 5; i++) Lbl("RP_s" + IntegerToString(i), "", 8, 437 + (i - 1) * 15, MG_TEXT);
   for(int i = 1; i <= 3; i++) Lbl("RP_mg" + IntegerToString(i), "", 8, 528 + (i - 1) * 14, MG_CAP);

   // ---- tab 1: TRADE (replay control + execution)
   gTab = 1;
   Lbl("RP_c1", "REPLAY", 0, 141, MG_CAP);
   Btn("RP_next", "Next Bar", 0,   156, 102);
   Btn("RP_play", "Play",     106, 156, 102, 1);
   Btn("RP_m1",   "+1m",      0,   184, 49);
   Btn("RP_m5",   "+5m",      53,  184, 49);
   Btn("RP_m15",  "+15m",     106, 184, 49);
   Btn("RP_h1",   "+1h",      159, 184, 49);
   Btn("RP_slow", "Slow",     0,   212, 66);
   Btn("RP_fast", "Fast",     70,  212, 67);
   Btn("RP_exit", "Exit",     141, 212, 67, 2);
   Lbl("RP_c2", "EXECUTION", 0, 242, MG_CAP);
   Btn("RP_buy",   "BUY",        0,   258, 102, 3, 26);
   Btn("RP_sell",  "SELL",       106, 258, 102, 3, 26);
   Btn("RP_cl1",   "Close Last", 0,   288, 102);
   Btn("RP_clall", "Close All",  106, 288, 102);
   Lbl("RP_l1", "Risk%", 0,   323, MG_CAP);
   Edt("RP_risk", DoubleToString(RiskPercent, 2), 42,  319, 56);
   Lbl("RP_l2", "TP(R)", 110, 323, MG_CAP);
   Edt("RP_tpr",  DoubleToString(TP_R, 1),        152, 319, 56);
   // strategy tag: click to cycle. "Tag" re-tags the selected trade (and the pending line, if any)
   Btn("RP_strat", "", 0,   346, 208);
   Btn("RP_setup", "", 0,   372, 158);
   Btn("RP_tag",   "Tag", 162, 372, 46);
   UpdateTagButtons();
   Btn("RP_padd", "ADD PEND LINE", 0,   400, 102);
   Btn("RP_pcan", "CANCEL PEND",   106, 400, 102);

   // ---- tab 3: TOOLS (levels, jump, selected-trade stops, reports)
   gTab = 3;
   Lbl("RP_c7", "LEVELS", 0, 141, MG_CAP);
   Btn("RP_pd", "Prev Day", 0,   156, 66, 1);
   Btn("RP_wm", "Week Map", 70,  156, 67, 1);
   Btn("RP_kt", "Key Time", 141, 156, 67, 1);
   Lbl("RP_c6", "JUMP TO DATE", 0, 188, MG_CAP);
   Edt("RP_date", TimeToString(startT, TIME_DATE | TIME_MINUTES), 0, 204, 112);
   Btn("RP_cal",  "Cal", 116, 203, 44);
   Btn("RP_go",   "Go",  164, 203, 44);
   Lbl("RP_c3", "SELECTED TRADE", 0, 236, MG_CAP);
   Lbl("RP_l6", "Price", 0, 260, MG_CAP);
   Edt("RP_px", "", 44, 256, 164);
   Btn("RP_setsl", "Set SL", 0,   282, 102);
   Btn("RP_settp", "Set TP", 106, 282, 102);
   Lbl("RP_l4", "Step$", 0, 316, MG_CAP);
   Edt("RP_step", DoubleToString(StepDollar, 2), 44, 312, 56);
   Lbl("RP_l5", "Dist$", 110, 316, MG_CAP);
   Edt("RP_trl", DoubleToString(TrailDollar, 2), 152, 312, 56);
   Btn("RP_trail", "Trail", 0, 338, 208);
   Lbl("RP_c8", "REPORTS", 0, 370, MG_CAP);
   Btn("RP_dash",  "Dashboard", 0,   386, 66);
   Btn("RP_save",  "Save",      70,  386, 67);
   Btn("RP_reset", "Reset",     141, 386, 67, 2);

   // draggable planning SL line (structure stop). DOUBLE-click it, then drag.
   DrawLine("RP_SLLINE", lastBid - InitSLDist, clrYellow, STYLE_SOLID, true, 2);
   ObjectSetInteger(cid, "RP_SLLINE", OBJPROP_SELECTED, true);
   gTab = 0;
   SetTab(1);
   ApplyToggles();
}
//--------------------------------------------------------------------
double TradeFloatD(int i)
{
   double d = (tType[i] == 0) ? (lastBid - tEntry[i]) : (tEntry[i] - (lastBid + SpreadPrice));
   return d * tLots[i] * ContractSize;
}
double Floating()
{
   double f = 0;
   for(int i = 0; i < tN; i++) f += TradeFloatD(i);
   return f;
}
double FloatR(int i) { return (tRisk[i] > 0) ? TradeFloatD(i) / tRisk[i] : 0; }

double DayR(datetime t)
{
   datetime key = DayKey(t);
   double s = 0;
   for(int i = 0; i < hN; i++) if(DayKey(hT[i]) == key) s += hR[i];
   return s;
}
int SelIdx()
{
   for(int i = 0; i < tN; i++) if(tId[i] == selId) return i;
   return tN - 1;      // none selected -> last opened (or -1)
}
void ApplySel()
{
   int si = SelIdx();
   for(int i = 0; i < tN; i++)
   {
      int w = (i == si) ? 3 : 1;
      string k = IntegerToString(tId[i]);
      ObjectSetInteger(cid, "RP_E" + k, OBJPROP_WIDTH, w);
      ObjectSetInteger(cid, "RP_S" + k, OBJPROP_WIDTH, w);
      ObjectSetInteger(cid, "RP_T" + k, OBJPROP_WIDTH, w);
   }
}
void UpdateSelInfo()
{
   int i = SelIdx();
   string a = "", b = "", c = "", d = "", e = "";
   if(i >= 0)
   {
      a = StringFormat("Sel #%d %s %.2f lots  %+.2fR", tId[i], (tType[i] == 0 ? "BUY" : "SELL"), tLots[i], FloatR(i));
      b = "Entry " + DoubleToString(tEntry[i], digitsV) + "  SL " + DoubleToString(tSL[i], digitsV);
      c = "TP " + (tTP[i] > 0 ? DoubleToString(tTP[i], digitsV) : "-") + "  Trail " +
          (tTrail[i] > 0 ? DoubleToString(tTrail[i], 2) : "off");
      d = tCat[i];
      e = tStp[i];
   }
   SetLbl("RP_s1", a);
   SetLbl("RP_s2", b);
   SetLbl("RP_s3", c);
   SetLbl("RP_s4", d);
   SetLbl("RP_s5", e);
}
void UpdateSession()
{
   long dn = (long)lastT / 86400;
   datetime w0 = (datetime)((((dn + 3) / 7) * 7 - 3) * 86400);
   double wk = 0;
   for(int i = 0; i < hN; i++) if(hT[i] >= w0 && hT[i] < w0 + 7 * 86400) wk += hR[i];
   double wr = (hN > 0) ? 100.0 * nWin / hN : 0;
   SetLbl("RP_r1", StringFormat("Trades %d   W:%d  L:%d", hN, nWin, nLoss));
   SetLbl("RP_r2", StringFormat("Win rate %.0f%%   Total %+.1fR", wr, sumR));
   SetLbl("RP_r3", StringFormat("Today %+.1fR   Week %+.1fR", DayR(lastT), wk));
   SetLbl("RP_r4", StringFormat("Closed P/L %+.1f$", closedPL));
}
void UpdateInfo()
{
   SetLbl("RP_i1", TimeToString(lastT, TIME_DATE | TIME_MINUTES) + (rTF == PERIOD_M5 ? "  [M5]" : "") + "  " + IntegerToString(delayMs) + "ms");
   SetLbl("RP_i2", StringFormat("Bal %.0f   Float %+.1f$", StartBalance + closedPL, Floating()));
   SetLbl("RP_i3", StringFormat("%s %d/%d   %+.1fR", bName, hN, BatchTarget, sumR));
   SetLbl("RP_i4", StringFormat("Day %+.1fR  W:%d L:%d  Open:%d", DayR(lastT), nWin, nLoss, tN));
   SetWrap("RP_mg", lastMsg);
   UpdateSelInfo();
   UpdateSession();
   ChartRedraw(cid);
}
void DelLines(int id)
{
   string k = IntegerToString(id);
   ObjectDelete(cid, "RP_E" + k);
   ObjectDelete(cid, "RP_S" + k);
   ObjectDelete(cid, "RP_T" + k);
}
//--------------------------------------------------------------------
// Grouping of closed trades by close day (mode 0) or by week starting Monday (mode 1)
int GroupStats(int mode, datetime &gK[], int &gN[], int &gW[], double &gR[], double &gP[], double &gGW[], double &gGL[])
{
   ArrayInitialize(gK, 0);
   ArrayInitialize(gN, 0);
   ArrayInitialize(gW, 0);
   ArrayInitialize(gR, 0.0);
   ArrayInitialize(gP, 0.0);
   ArrayInitialize(gGW, 0.0);
   ArrayInitialize(gGL, 0.0);
   int ng = 0;
   for(int i = 0; i < hN; i++)
   {
      long dn = (long)hT[i] / 86400;
      datetime key = (mode == 0) ? (datetime)(dn * 86400) : (datetime)((((dn + 3) / 7) * 7 - 3) * 86400);
      int j = -1;
      for(int q = 0; q < ng; q++) if(gK[q] == key) { j = q; break; }
      if(j < 0)
      {
         if(ng >= NG) continue;
         j = ng; ng++;
         gK[j] = key;
      }
      gN[j]++; gR[j] += hR[i]; gP[j] += hP[i];
      if(hR[i] > 0) { gW[j]++; gGW[j] += hR[i]; } else gGL[j] += hR[i];
   }
   for(int a = 0; a < ng - 1; a++)
      for(int b = 0; b < ng - 1 - a; b++)
         if(gK[b] > gK[b + 1])
         {
            datetime tk = gK[b]; gK[b] = gK[b + 1]; gK[b + 1] = tk;
            int tn = gN[b]; gN[b] = gN[b + 1]; gN[b + 1] = tn;
            int tw = gW[b]; gW[b] = gW[b + 1]; gW[b + 1] = tw;
            double t1 = gR[b];  gR[b]  = gR[b + 1];  gR[b + 1]  = t1;
            double t2 = gP[b];  gP[b]  = gP[b + 1];  gP[b + 1]  = t2;
            double t3 = gGW[b]; gGW[b] = gGW[b + 1]; gGW[b + 1] = t3;
            double t4 = gGL[b]; gGL[b] = gGL[b + 1]; gGL[b + 1] = t4;
         }
   return(ng);
}
// Grouping of closed trades by strategy (mode 0) or strategy/setup (mode 1)
int TagGroup(int mode, string &gK[], int &gN[], int &gW[], double &gR[], double &gP[], double &gGW[], double &gGL[])
{
   ArrayInitialize(gN, 0);
   ArrayInitialize(gW, 0);
   ArrayInitialize(gR, 0.0);
   ArrayInitialize(gP, 0.0);
   ArrayInitialize(gGW, 0.0);
   ArrayInitialize(gGL, 0.0);
   int ng = 0;
   for(int i = 0; i < hN; i++)
   {
      string key = (mode == 0) ? hCat[i] : TagFull(hCat[i], hStp[i]);
      int j = -1;
      for(int q = 0; q < ng; q++) if(gK[q] == key) { j = q; break; }
      if(j < 0)
      {
         if(ng >= NG) continue;
         j = ng; ng++;
         gK[j] = key;
      }
      gN[j]++; gR[j] += hR[i]; gP[j] += hP[i];
      if(hR[i] > 0) { gW[j]++; gGW[j] += hR[i]; } else gGL[j] += hR[i];
   }
   return(ng);
}
string PFText(double gw, double gl) { return((gl < 0) ? DoubleToString(gw / (-gl), 2) : "-"); }
void WriteSumRow(int f, string scope, string period, int n, int w, double r, double p, double gw, double gl, string dd)
{
   FileWrite(f, scope, period, IntegerToString(n), IntegerToString(w),
             DoubleToString(n > 0 ? 100.0 * w / n : 0, 1), PFText(gw, gl),
             DoubleToString(r, 2), DoubleToString(p, 2), DoubleToString(n > 0 ? r / n : 0, 2), dd);
}
// Session summary (per day, per week, total) -> MQL4\Files\ReplaySummary.csv
void SaveSummary()
{
   if(hN == 0) return;
   int f = FileOpen(fSum, FILE_CSV | FILE_WRITE | FILE_SHARE_READ, ';');
   if(f < 0) { lastMsg = "Cannot write " + fSum; return; }
   FileWrite(f, "Scope", "Period", "Trades", "Wins", "WinRate%", "ProfitFactor", "TotalR", "Profit$", "AvgR", "MaxDD_R");

   datetime gK[NG]; int gN[NG]; int gW[NG]; double gR[NG]; double gP[NG]; double gGW[NG]; double gGL[NG];
   for(int mode = 0; mode < 2; mode++)
   {
      int ng = GroupStats(mode, gK, gN, gW, gR, gP, gGW, gGL);
      for(int g = 0; g < ng; g++)
         WriteSumRow(f, (mode == 0 ? "Day" : "Week(Mon)"), TimeToString(gK[g], TIME_DATE), gN[g], gW[g], gR[g], gP[g], gGW[g], gGL[g], "");
   }
   string tK[NG];
   for(int mode = 0; mode < 2; mode++)
   {
      int ng = TagGroup(mode, tK, gN, gW, gR, gP, gGW, gGL);
      for(int g = 0; g < ng; g++)
         WriteSumRow(f, (mode == 0 ? "Strategy" : "Setup"), tK[g], gN[g], gW[g], gR[g], gP[g], gGW[g], gGL[g], "");
   }
   double cum = 0, peak = 0, dd = 0, sr = 0, sp = 0, gw = 0, gl = 0;
   int w = 0;
   for(int i = 0; i < hN; i++)
   {
      cum += hR[i];
      if(cum > peak) peak = cum;
      if(peak - cum > dd) dd = peak - cum;
      sr += hR[i]; sp += hP[i];
      if(hR[i] > 0) { w++; gw += hR[i]; } else gl += hR[i];
   }
   WriteSumRow(f, "TOTAL", "session", hN, w, sr, sp, gw, gl, DoubleToString(dd, 2));
   FileClose(f);
   lastMsg = "Summary saved: " + fSum;
}
//--------------------------------------------------------------------
// Stats panel (top-left of the control chart)
void SetStatLine(int i, string txt, color clr)
{
   string n = "RP_st" + IntegerToString(i);
   if(ObjectFind(cid, n) < 0)
   {
      ObjectCreate(cid, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(cid, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, 20 + i * 16);
      ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, 9);
      ObjectSetString(cid, n, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(cid, n, OBJPROP_COLOR, clr);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
}
void ClearStats()
{
   for(int i = 0; i < NSTAT; i++) ObjectDelete(cid, "RP_st" + IntegerToString(i));
}
void UpdateStats()
{
   string L[NSTAT];
   color  C[NSTAT];
   int nl = 0;

   L[nl] = "---- SESSION STATS ----"; C[nl] = clrGold; nl++;
   if(hN == 0)
   {
      L[nl] = "no closed trades yet"; C[nl] = clrSilver; nl++;
   }
   else
   {
      double cum = 0, peak = 0, dd = 0, sw = 0, sl2 = 0, best = -1000, worst = 1000, sp = 0;
      int w = 0;
      for(int i = 0; i < hN; i++)
      {
         double r = hR[i];
         cum += r;
         if(cum > peak) peak = cum;
         if(peak - cum > dd) dd = peak - cum;
         if(r > 0) { w++; sw += r; } else sl2 += r;
         if(r > best) best = r;
         if(r < worst) worst = r;
         sp += hP[i];
      }
      string pf = (sl2 < 0) ? DoubleToString(sw / (-sl2), 2) : "-";
      L[nl] = StringFormat("Trades %d   Win %.0f%%   PF %s", hN, 100.0 * w / hN, pf); C[nl] = clrWhite; nl++;
      L[nl] = StringFormat("Total %+.2fR   %+.1f$", cum, sp); C[nl] = (cum >= 0 ? clrLime : clrTomato); nl++;
      L[nl] = StringFormat("Avg %+.2fR  Best %+.2fR  Worst %+.2fR", cum / hN, best, worst); C[nl] = clrWhite; nl++;
      L[nl] = StringFormat("Max drawdown %.2fR", dd); C[nl] = clrWhite; nl++;
      L[nl] = " "; C[nl] = clrWhite; nl++;

      // per strategy and per setup
      string qK[NG]; int qN[NG]; int qW[NG]; double qR[NG]; double qP[NG]; double qGW[NG]; double qGL[NG];
      for(int qm = 0; qm < 2; qm++)
      {
         int nq = TagGroup(qm, qK, qN, qW, qR, qP, qGW, qGL);
         if(nl < NSTAT) { L[nl] = (qm == 0 ? "Per strategy:" : "Per setup:"); C[nl] = clrGold; nl++; }
         for(int g = 0; g < nq && nl < NSTAT; g++)
         {
            L[nl] = StringFormat("%s  %dtr  %.0f%%  %+.2fR  PF %s", qK[g], qN[g], 100.0 * qW[g] / qN[g], qR[g], PFText(qGW[g], qGL[g]));
            C[nl] = (qR[g] >= 0 ? clrLime : clrTomato);
            nl++;
         }
         if(nl < NSTAT) { L[nl] = " "; C[nl] = clrWhite; nl++; }
      }
      L[nl] = "Per day (by close date):"; C[nl] = clrGold; nl++;

      // group by day
      datetime dK[60]; int dN[60]; double dR[60]; double dP[60];
      ArrayInitialize(dK, 0);
      ArrayInitialize(dN, 0);
      ArrayInitialize(dR, 0.0);
      ArrayInitialize(dP, 0.0);
      int nd = 0;
      for(int i = 0; i < hN; i++)
      {
         datetime key = DayKey(hT[i]);
         int j = -1;
         for(int q = 0; q < nd; q++) if(dK[q] == key) { j = q; break; }
         if(j < 0)
         {
            if(nd >= 60) continue;
            j = nd; nd++;
            dK[j] = key; dN[j] = 0; dR[j] = 0; dP[j] = 0;
         }
         dN[j]++; dR[j] += hR[i]; dP[j] += hP[i];
      }
      // sort ascending by date
      for(int a = 0; a < nd - 1; a++)
         for(int b = 0; b < nd - 1 - a; b++)
            if(dK[b] > dK[b + 1])
            {
               datetime tk = dK[b]; dK[b] = dK[b + 1]; dK[b + 1] = tk;
               int tn = dN[b]; dN[b] = dN[b + 1]; dN[b + 1] = tn;
               double tr = dR[b]; dR[b] = dR[b + 1]; dR[b + 1] = tr;
               double tp = dP[b]; dP[b] = dP[b + 1]; dP[b + 1] = tp;
            }
      int from = MathMax(0, nd - 7);
      for(int d = from; d < nd && nl < NSTAT; d++)
      {
         L[nl] = StringFormat("%s  %2d tr  %+6.2fR  %+8.1f$", TimeToString(dK[d], TIME_DATE), dN[d], dR[d], dP[d]);
         C[nl] = (dR[d] >= 0 ? clrLime : clrTomato);
         nl++;
      }

      // per week (week starts Monday, by close date)
      datetime wK[NG]; int wN[NG]; int wW[NG]; double wR[NG]; double wP[NG]; double wGW[NG]; double wGL[NG];
      int nwk = GroupStats(1, wK, wN, wW, wR, wP, wGW, wGL);
      if(nl < NSTAT) { L[nl] = " "; C[nl] = clrWhite; nl++; }
      if(nl < NSTAT) { L[nl] = "Per week (Mon start):"; C[nl] = clrGold; nl++; }
      int wFrom = MathMax(0, nwk - 4);
      for(int g = wFrom; g < nwk && nl < NSTAT; g++)
      {
         L[nl] = StringFormat("%s  %2d tr  %+6.2fR  %+8.1f$", TimeToString(wK[g], TIME_DATE), wN[g], wR[g], wP[g]);
         C[nl] = (wR[g] >= 0 ? clrLime : clrTomato);
         nl++;
      }
   }
   for(int i = 0; i < nl; i++) SetStatLine(i, L[i], C[i]);
   for(int i = nl; i < NSTAT; i++) ObjectDelete(cid, "RP_st" + IntegerToString(i));
}
//--------------------------------------------------------------------
string SafeName(string n)
{
   string o = "";
   for(int i = 0; i < StringLen(n); i++)
   {
      int ch = StringGetChar(n, i);
      bool ok = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '-' || ch == '_';
      o = o + (ok ? CharToStr((uchar)ch) : "_");
   }
   if(o == "") o = "Batch";
   return(o);
}
// remember where the replay is (so the batch can be continued later)
void SaveState()
{
   if(fState == "" || lastT <= 0) return;
   int f = FileOpen(fState, FILE_CSV | FILE_WRITE, ';');
   if(f < 0) return;
   string a = sRisk, b = sTpr, c = sStep, d = sTrl;
   if(cid != 0 && ObjectFind(cid, "RP_risk") >= 0)
   {
      a = ObjectGetString(cid, "RP_risk", OBJPROP_TEXT);
      b = ObjectGetString(cid, "RP_tpr",  OBJPROP_TEXT);
      c = ObjectGetString(cid, "RP_step", OBJPROP_TEXT);
      d = ObjectGetString(cid, "RP_trl",  OBJPROP_TEXT);
   }
   FileWrite(f, TimeToString(lastT, TIME_DATE | TIME_MINUTES), IntegerToString(hN), a, b, c, d, TagC(), TagS());
   FileClose(f);
}
// rebuild stats from the batch log; returns the saved replay time (0 = new batch)
datetime LoadBatch()
{
   hN = 0; closedPL = 0; sumR = 0; nWin = 0; nLoss = 0;
   datetime rt = 0;
   int f = FileOpen(fLog, FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_SHARE_WRITE, ';');
   if(f >= 0)
   {
      while(!FileIsEnding(f) && hN < HMAX)
      {
         // read one whole line (old logs have 9 columns, new ones 11: ..., Strategy, Setup)
         string cc[12];
         for(int z = 0; z < 12; z++) cc[z] = "";
         int nc = 0;
         while(!FileIsEnding(f) && nc < 12)
         {
            cc[nc] = FileReadString(f);
            nc++;
            if(FileIsLineEnding(f)) break;
         }
         if(cc[0] == "" || cc[0] == "Open") continue;
         datetime tc = StringToTime(cc[1]);
         double pl = StringToDouble(cc[7]), r = StringToDouble(cc[8]);
         hT[hN] = tc; hR[hN] = r; hP[hN] = pl;
         hCat[hN] = (cc[9] == "" ? "UNTAGGED" : cc[9]);
         hStp[hN] = cc[10];
         hN++;
         closedPL += pl; sumR += r;
         if(pl >= 0) nWin++; else nLoss++;
      }
      FileClose(f);
   }
   int g = FileOpen(fState, FILE_CSV | FILE_READ | FILE_SHARE_READ, ';');
   if(g >= 0)
   {
      string ts = FileReadString(g);
      string sn = FileReadString(g);
      sRisk = FileReadString(g);
      sTpr  = FileReadString(g);
      sStep = FileReadString(g);
      sTrl  = FileReadString(g);
      sTagC = FileReadString(g);
      sTagS = FileReadString(g);
      FileClose(g);
      rt = StringToTime(ts);
   }
   return(rt);
}
void LogTrade(int i, double fill, double pl, double r)
{
   int f = FileOpen(fLog, FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_SHARE_WRITE, ';');
   if(f < 0) return;
   FileSeek(f, 0, SEEK_END);
   if(FileTell(f) == 0)
      FileWrite(f, "Open", "Close", "Side", "Lots", "Entry", "Fill", "Risk$", "Profit$", "R", "Strategy", "Setup");
   FileWrite(f, TimeToString(tTime[i], TIME_DATE | TIME_MINUTES), TimeToString(lastT, TIME_DATE | TIME_MINUTES),
             (tType[i] == 0 ? "BUY" : "SELL"), DoubleToString(tLots[i], 2),
             DoubleToString(tEntry[i], digitsV), DoubleToString(fill, digitsV),
             DoubleToString(tRisk[i], 2), DoubleToString(pl, 2), DoubleToString(r, 2),
             tCat[i], tStp[i]);
   FileClose(f);
   SaveState();
}
//--------------------------------------------------------------------
// DASHBOARD: writes MQL4\Files\RP_data.txt (all closed trades of this batch) and opens
// MQL4\Files\RP_Dashboard.html in the default browser.
//--------------------------------------------------------------------
// DATE PICKER: click "Cal" next to the date box -> month grid + time spinner -> "Go to date".
// No typing needed. The popup opens to the LEFT of the panel (all object names start with RP_CAL_).
#define CW   226                       // popup width
#define CLD  (PM + PW + 4 + CW)        // distance chart right edge -> popup LEFT edge
bool calOn = false;
int  calY = 0, calM = 0, calD = 0, calH = 0, calN = 0, calOff = 0;

int DaysIn(int y, int m)
{
   int d[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
   if(m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return(29);
   return(d[m - 1]);
}
// tolerant date text: accepts 2026.10.2716:05, 2026-10-27 16:05, 2026/10/27  16:05
string NormDate(string s)
{
   StringReplace(s, "-", ".");
   StringReplace(s, "/", ".");
   StringReplace(s, "T", " ");
   StringTrimLeft(s);
   StringTrimRight(s);
   while(StringReplace(s, "  ", " ") > 0) { }
   if(StringFind(s, " ") < 0 && StringLen(s) >= 15) s = StringSubstr(s, 0, 10) + " " + StringSubstr(s, 10);
   return(s);
}
void CBtn(string n, string txt, int x, int y, int w, int h, color bg, color fg)
{
   if(ObjectFind(cid, n) < 0)
   {
      ObjectCreate(cid, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(cid, n, OBJPROP_STATE, false);
   }
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, CLD - x);
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(cid, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(cid, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(cid, n, OBJPROP_BORDER_COLOR, (bg == MG_BG) ? MG_BG : MG_DARK);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, fg);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
}
void CLbl(string n, string txt, int x, int y, color clr)
{
   if(ObjectFind(cid, n) < 0)
   {
      ObjectCreate(cid, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(cid, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(cid, n, OBJPROP_FONTSIZE, 8);
   }
   ObjectSetInteger(cid, n, OBJPROP_XDISTANCE, CLD - x);
   ObjectSetInteger(cid, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(cid, n, OBJPROP_COLOR, clr);
   ObjectSetString(cid, n, OBJPROP_TEXT, txt);
}
void DrawCal()
{
   string mon[12] = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};
   string wd[7] = {"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"};
   color bgc = MG_BG;
   if(ObjectFind(cid, "RP_CAL_bg") < 0)
   {
      ObjectCreate(cid, "RP_CAL_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_XDISTANCE, CLD);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_YDISTANCE, 150);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_XSIZE, CW);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_YSIZE, 272);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_BGCOLOR, bgc);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_COLOR, MG_BORDER);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, "RP_CAL_bg", OBJPROP_HIDDEN, true);
   }
   int dim = DaysIn(calY, calM);
   if(calD > dim) calD = dim;
   datetime first = StringToTime(StringFormat("%04d.%02d.01 00:00", calY, calM));
   calOff = (TimeDayOfWeek(first) + 6) % 7;            // Monday = 0

   CBtn("RP_CAL_prev", "<", 8, 156, 30, 24, MG_FACE, MG_TEXT);
   CBtn("RP_CAL_next", ">", 188, 156, 30, 24, MG_FACE, MG_TEXT);
   CLbl("RP_CAL_title", StringFormat("%s %d", mon[calM - 1], calY), 66, 161, MG_TEXT);
   for(int i = 0; i < 7; i++)
      CLbl("RP_CAL_w" + IntegerToString(i), wd[i], 14 + i * 30, 186, MG_CAP);
   for(int q = 0; q < 42; q++)
   {
      int dd = q - calOff + 1;
      int r = q / 7, c = q % 7;
      string n = "RP_CAL_d" + IntegerToString(q);
      if(dd < 1 || dd > dim) { CBtn(n, "", 8 + c * 30, 204 + r * 24, 28, 22, bgc, bgc); continue; }
      color b = (c >= 5) ? C'232,232,232' : MG_FACE;           // weekends dimmer
      if(dd == calD) b = MG_ACTIVE;
      CBtn(n, IntegerToString(dd), 8 + c * 30, 204 + r * 24, 28, 22, b, (dd == calD) ? clrWhite : MG_TEXT);
   }
   CBtn("RP_CAL_hm", "-", 8, 354, 28, 22, MG_FACE, MG_TEXT);
   CLbl("RP_CAL_hv", StringFormat("%02d h", calH), 42, 358, MG_TEXT);
   CBtn("RP_CAL_hp", "+", 80, 354, 28, 22, MG_FACE, MG_TEXT);
   CBtn("RP_CAL_mm", "-", 118, 354, 28, 22, MG_FACE, MG_TEXT);
   CLbl("RP_CAL_mv", StringFormat("%02d min", calN), 152, 358, MG_TEXT);
   CBtn("RP_CAL_mp", "+", 190, 354, 28, 22, MG_FACE, MG_TEXT);
   CBtn("RP_CAL_ok", StringFormat("Go: %04d.%02d.%02d %02d:%02d", calY, calM, calD, calH, calN), 8, 384, 156, 28, MG_ACTIVE, clrWhite);
   CBtn("RP_CAL_x", "Close", 168, 384, 50, 28, MG_FACE, MG_DANGER);
   ChartRedraw(cid);
}
void CalOpen()
{
   datetime t = (lastT > 0) ? lastT : startT;
   calY = TimeYear(t); calM = TimeMonth(t); calD = TimeDay(t); calH = TimeHour(t);
   calN = (TimeMinute(t) / 5) * 5;
   calOn = true;
   DrawCal();
}
void CalClose()
{
   ObjectsDeleteAll(cid, "RP_CAL_");
   calOn = false;
   ChartRedraw(cid);
}
// handles the popup buttons; returns true when "Go to date" was pressed (the date box is filled in)
bool CalHandle()
{
   bool redraw = false;
   if(Pressed("RP_CAL_prev")) { calM--; if(calM < 1) { calM = 12; calY--; } redraw = true; }
   if(Pressed("RP_CAL_next")) { calM++; if(calM > 12) { calM = 1; calY++; } redraw = true; }
   if(Pressed("RP_CAL_hm")) { calH = (calH + 23) % 24; redraw = true; }
   if(Pressed("RP_CAL_hp")) { calH = (calH + 1) % 24; redraw = true; }
   if(Pressed("RP_CAL_mm")) { calN = (calN + 55) % 60; redraw = true; }
   if(Pressed("RP_CAL_mp")) { calN = (calN + 5) % 60; redraw = true; }
   for(int q = 0; q < 42; q++)
      if(Pressed("RP_CAL_d" + IntegerToString(q)))
      {
         int dd = q - calOff + 1;
         if(dd >= 1 && dd <= DaysIn(calY, calM)) { calD = dd; redraw = true; }
      }
   if(Pressed("RP_CAL_x")) { CalClose(); return(false); }
   if(Pressed("RP_CAL_ok"))
   {
      ObjectSetString(cid, "RP_date", OBJPROP_TEXT, StringFormat("%04d.%02d.%02d %02d:%02d", calY, calM, calD, calH, calN));
      CalClose();
      return(true);
   }
   if(redraw) DrawCal();
   return(false);
}
//--------------------------------------------------------------------
string JQ(string s)
{
   StringReplace(s, "\\", "/");
   StringReplace(s, "\"", "'");
   return("\"" + s + "\"");
}
string JN(string s) { return(s == "" ? "0" : DoubleToString(StringToDouble(s), 4)); }
void OpenDashboard()
{
   if(!FileIsExist("RP_Dashboard.html"))
   {
      lastMsg = "RP_Dashboard.html not found in MQL4\\Files. Copy it there first.";
      return;
   }
   // SHARE flags: the browser may still have the old file open, which would block a plain write
   ResetLastError();
   int o = FileOpen("RP_data.txt", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(o < 0)
   {
      lastMsg = "Cannot write RP_data.txt, err " + IntegerToString(GetLastError()) + ". Close the dashboard tab and try again.";
      return;
   }
   FileWrite(o, "window.RP_DATA = {batch:" + JQ(bName) + ", target:" + IntegerToString(BatchTarget) +
                ", startBalance:" + DoubleToString(StartBalance, 2) +
                ", replayTime:" + JQ(TimeToString(lastT, TIME_DATE | TIME_MINUTES)) +
                ", open:" + IntegerToString(tN) + ", floating:" + DoubleToString(Floating(), 2) + ",");
   FileWrite(o, "trades:[");
   int f = FileOpen(fLog, FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_SHARE_WRITE, ';');
   if(f >= 0)
   {
      while(!FileIsEnding(f))
      {
         string cc[12];
         for(int z = 0; z < 12; z++) cc[z] = "";
         int nc = 0;
         while(!FileIsEnding(f) && nc < 12)
         {
            cc[nc] = FileReadString(f);
            nc++;
            if(FileIsLineEnding(f)) break;
         }
         if(cc[0] == "" || cc[0] == "Open") continue;
         FileWrite(o, "[" + JQ(cc[0]) + "," + JQ(cc[1]) + "," + JQ(cc[2]) + "," + JN(cc[3]) + "," + JN(cc[4]) + "," +
                      JN(cc[5]) + "," + JN(cc[6]) + "," + JN(cc[7]) + "," + JN(cc[8]) + "," + JQ(cc[9]) + "," + JQ(cc[10]) + "],");
      }
      FileClose(f);
   }
   FileWrite(o, "]};");
   FileClose(o);

   string path = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\RP_Dashboard.html";
   // v4.00: a script cannot start the browser without a DLL. Open the file yourself (Chrome bookmark), then press F5.
   lastMsg = "Dashboard data updated. Open RP_Dashboard.html in Chrome (MQL4\\Files) and press F5.";
}
//--------------------------------------------------------------------
bool OpenTradeAt(int type, double e, double slp, string cat, string stp)
{
   if(tN >= MAXT) { lastMsg = "Too many open trades."; return(false); }
   double riskPct = ReadEdit("RP_risk"), tpr = ReadEdit("RP_tpr");
   if(riskPct <= 0) { lastMsg = "Risk% invalid."; return(false); }

   double dist = MathAbs(e - slp);
   double riskD = (StartBalance + closedPL) * riskPct / 100.0;
   double lots = riskD / (dist * ContractSize);
   lots = MathFloor(lots / LotStep + 0.000000001) * LotStep;
   if(lots < MinLot) { lastMsg = "SL too far for this risk: lot would be below minimum."; return(false); }
   if(lots > MaxLot) lots = MaxLot;
   lots = NormalizeDouble(lots, 2);

   double sl = NormalizeDouble(slp, digitsV), tp = 0;
   if(tpr > 0) tp = NormalizeDouble((type == 0) ? e + tpr * dist : e - tpr * dist, digitsV);
   e = NormalizeDouble(e, digitsV);

   int id = nextId++;
   tId[tN] = id; tType[tN] = type; tEntry[tN] = e; tLots[tN] = lots;
   tSL[tN] = sl; tTP[tN] = tp; tTime[tN] = lastT; tRisk[tN] = lots * dist * ContractSize; tTrail[tN] = 0;
   tCat[tN] = cat; tStp[tN] = stp;
   tN++;
   selId = id;

   string k = IntegerToString(id);
   DrawLine("RP_E" + k, e, (type == 0 ? clrDodgerBlue : clrOrangeRed), STYLE_SOLID, false, 1);
   DrawLine("RP_S" + k, sl, clrRed, STYLE_DOT, true, 1);
   if(tp > 0) DrawLine("RP_T" + k, tp, clrLime, STYLE_DOT, true, 1);
   ApplySel();
   lastMsg = StringFormat("Opened #%d %s %.2f lots @ %s | risk %.1f$ | %s", id, (type == 0 ? "BUY" : "SELL"),
                          lots, DoubleToString(e, digitsV), tRisk[tN - 1], TagFull(cat, stp));
   return(true);
}
void OpenTrade(int type)
{
   if(ObjectFind(cid, "RP_SLLINE") < 0) { lastMsg = "SL line is missing."; return; }
   double slp = ObjectGetDouble(cid, "RP_SLLINE", OBJPROP_PRICE);
   double e = (type == 0) ? lastBid + SpreadPrice : lastBid;
   if(type == 0 && slp >= e) { lastMsg = "BUY: drag the yellow SL line BELOW price."; return; }
   if(type == 1 && slp <= e) { lastMsg = "SELL: drag the yellow SL line ABOVE price."; return; }
   OpenTradeAt(type, e, slp, TagC(), TagS());
}
// re-tag the selected trade (and the pending line, if one exists) with the current selection
void RetagSel()
{
   string m = "";
   int i = SelIdx();
   if(i >= 0) { tCat[i] = TagC(); tStp[i] = TagS(); m = StringFormat("#%d", tId[i]); }
   if(pOn) { pCat = TagC(); pStp = TagS(); m = m + (m == "" ? "pending" : " + pending"); }
   lastMsg = (m == "") ? "No open trade / pending to tag." : m + " tagged " + TagFull(TagC(), TagS());
}
//--------------------------------------------------------------------
// Pending line: blue line = entry price, yellow SL line decides the side
//   SL below the pending line = BUY, above = SELL
//   BUY : line below ask = Buy Limit, above = Buy Stop
//   SELL: line above bid = Sell Limit, below = Sell Stop
int PendSide(double pp, double slp)
{
   if(slp <= 0) return(0);
   if(slp < pp) return(1);
   if(slp > pp) return(-1);
   return(0);
}
string PendName(double pp, double slp)
{
   int sd = PendSide(pp, slp);
   if(sd == 0) return("PENDING (set SL line)");
   if(sd > 0) return((pp < lastBid + SpreadPrice) ? "PENDING BUY LIMIT" : "PENDING BUY STOP");
   return((pp > lastBid) ? "PENDING SELL LIMIT" : "PENDING SELL STOP");
}
void UpdatePendLabel()
{
   if(!pOn) return;
   if(ObjectFind(cid, "RP_PEND") < 0) { pOn = false; return; }
   double pp = ObjectGetDouble(cid, "RP_PEND", OBJPROP_PRICE);
   double slp = (ObjectFind(cid, "RP_SLLINE") >= 0) ? ObjectGetDouble(cid, "RP_SLLINE", OBJPROP_PRICE) : 0;
   string t = PendName(pp, slp);
   if(t != pTxt) { pTxt = t; ObjectSetString(cid, "RP_PEND", OBJPROP_TEXT, t); }
}
void AddPend()
{
   if(pOn && ObjectFind(cid, "RP_PEND") >= 0) { lastMsg = "Pending line already exists: drag it, or press CANCEL PEND."; return; }
   DrawLine("RP_PEND", lastBid, C'30,144,255', STYLE_SOLID, true, 2);
   ObjectSetInteger(cid, "RP_PEND", OBJPROP_SELECTED, true);
   pOn = true;
   pCat = TagC(); pStp = TagS();
   pTxt = "";
   UpdatePendLabel();
   lastMsg = "Pending line added. Double-click and drag it to the entry price; yellow SL line below it = BUY, above = SELL.";
}
void CancelPend()
{
   if(ObjectFind(cid, "RP_PEND") >= 0) ObjectDelete(cid, "RP_PEND");
   if(pOn) lastMsg = "Pending cancelled.";
   pOn = false;
}
void CheckPending(double hi, double lo)
{
   if(!pOn) return;
   if(ObjectFind(cid, "RP_PEND") < 0 || ObjectFind(cid, "RP_SLLINE") < 0) { pOn = false; return; }
   double pp = ObjectGetDouble(cid, "RP_PEND", OBJPROP_PRICE);
   double slp = ObjectGetDouble(cid, "RP_SLLINE", OBJPROP_PRICE);
   int sd = PendSide(pp, slp);
   if(sd == 0) return;
   bool hit = false;
   if(sd > 0)
   {
      if(pp < lastBid + SpreadPrice) hit = (lo + SpreadPrice <= pp);    // buy limit
      else                           hit = (hi + SpreadPrice >= pp);    // buy stop
   }
   else
   {
      if(pp > lastBid) hit = (hi >= pp);                                // sell limit
      else             hit = (lo <= pp);                                // sell stop
   }
   if(!hit) return;
   string nm = PendName(pp, slp);
   bool ok = OpenTradeAt((sd > 0) ? 0 : 1, NormalizeDouble(pp, digitsV), slp, pCat, pStp);
   if(ok) lastMsg = "FILLED " + nm + " @ " + DoubleToString(pp, digitsV) + ". " + lastMsg;
   else   lastMsg = "Pending cancelled: " + lastMsg;
   ObjectDelete(cid, "RP_PEND");
   pOn = false;
   pFilled = true;
}
void CloseTrade(int i, double fill)
{
   double pl = ((tType[i] == 0) ? (fill - tEntry[i]) : (tEntry[i] - fill)) * tLots[i] * ContractSize;
   double r = (tRisk[i] > 0) ? pl / tRisk[i] : 0;
   closedPL += pl;
   sumR += r;
   if(pl >= 0) nWin++; else nLoss++;
   if(hN < HMAX) { hT[hN] = lastT; hR[hN] = r; hP[hN] = pl; hCat[hN] = tCat[i]; hStp[hN] = tStp[i]; hN++; }
   LogTrade(i, fill, pl, r);
   lastMsg = StringFormat("Closed #%d %s  %+.2fR  (%.1f$)", tId[i], (tType[i] == 0 ? "BUY" : "SELL"), r, pl);
   if(tId[i] == selId) selId = 0;
   DelLines(tId[i]);
   for(int j = i; j < tN - 1; j++)
   {
      tId[j] = tId[j+1]; tType[j] = tType[j+1]; tEntry[j] = tEntry[j+1]; tLots[j] = tLots[j+1];
      tSL[j] = tSL[j+1]; tTP[j] = tTP[j+1]; tTime[j] = tTime[j+1]; tRisk[j] = tRisk[j+1]; tTrail[j] = tTrail[j+1];
      tCat[j] = tCat[j+1]; tStp[j] = tStp[j+1];
   }
   tN--;
}
double MarketFill(int i) { return (tType[i] == 0) ? lastBid : lastBid + SpreadPrice; }
void CloseAll()
{
   for(int i = tN - 1; i >= 0; i--) CloseTrade(i, MarketFill(i));
   ApplySel();
}
void CloseLast()
{
   if(tN > 0) CloseTrade(tN - 1, MarketFill(tN - 1));
   ApplySel();
}
//--------------------------------------------------------------------
// Trade management on the selected trade
void SetSL(int i, double p)
{
   p = NormalizeDouble(p, digitsV);
   tSL[i] = p;
   string n = "RP_S" + IntegerToString(tId[i]);
   if(ObjectFind(cid, n) < 0) DrawLine(n, p, clrRed, STYLE_DOT, true, 1);
   else ObjectSetDouble(cid, n, OBJPROP_PRICE, p);
}
void SetTP(int i, double p)
{
   p = NormalizeDouble(p, digitsV);
   tTP[i] = p;
   string n = "RP_T" + IntegerToString(tId[i]);
   if(ObjectFind(cid, n) < 0) DrawLine(n, p, clrLime, STYLE_DOT, true, 1);
   else ObjectSetDouble(cid, n, OBJPROP_PRICE, p);
}
void NextSel()
{
   if(tN == 0) { lastMsg = "No open trade."; return; }
   int i = SelIdx();
   i = (i + 1) % tN;
   selId = tId[i];
   ApplySel();
   lastMsg = StringFormat("Selected #%d", selId);
}
void MoveBE()
{
   int i = SelIdx();
   if(i < 0) { lastMsg = "No open trade."; return; }
   bool ok = (tType[i] == 0) ? (tEntry[i] < lastBid) : (tEntry[i] > lastBid + SpreadPrice);
   if(!ok) { lastMsg = "BE: price is not beyond entry yet."; return; }
   double fr = FloatR(i);
   SetSL(i, tEntry[i]);
   lastMsg = "SL moved to entry.";
   if(fr < 1.0) lastMsg += StringFormat("  (floating only %+.2fR - below +1R)", fr);
}
// dir = +1 tighten (toward price), -1 loosen (away from price)
void MoveSL(int dir)
{
   int i = SelIdx();
   if(i < 0) { lastMsg = "No open trade."; return; }
   double st = ReadEdit("RP_step");
   if(st <= 0) { lastMsg = "Step$ invalid."; return; }
   double pt = MathPow(10, -digitsV);
   double p;
   if(tType[i] == 0)
   {
      p = tSL[i] + dir * st;
      if(p > lastBid - pt) p = lastBid - pt;
   }
   else
   {
      p = tSL[i] - dir * st;
      if(p < lastBid + SpreadPrice + pt) p = lastBid + SpreadPrice + pt;
   }
   SetSL(i, p);
   lastMsg = StringFormat("#%d SL -> %s", tId[i], DoubleToString(tSL[i], digitsV));
}
void ToggleTrail()
{
   int i = SelIdx();
   if(i < 0) { lastMsg = "No open trade."; return; }
   if(tTrail[i] > 0) { tTrail[i] = 0; lastMsg = StringFormat("#%d trailing OFF", tId[i]); return; }
   double d = ReadEdit("RP_trl");
   if(d <= 0) { lastMsg = "Dist$ invalid."; return; }
   tTrail[i] = d;
   lastMsg = StringFormat("#%d trailing ON  (%.2f$ behind price)", tId[i], d);
}
void SetPrice(bool isTP)
{
   int i = SelIdx();
   if(i < 0) { lastMsg = "No open trade."; return; }
   double px = ReadEdit("RP_px");
   if(px <= 0) { lastMsg = "Type a price first."; return; }
   if(!isTP)
   {
      if(tType[i] == 0 && px >= lastBid) { lastMsg = "BUY: SL must be below price."; return; }
      if(tType[i] == 1 && px <= lastBid + SpreadPrice) { lastMsg = "SELL: SL must be above price."; return; }
      SetSL(i, px);
      lastMsg = StringFormat("#%d SL -> %s", tId[i], DoubleToString(tSL[i], digitsV));
   }
   else
   {
      if(tType[i] == 0 && px <= lastBid) { lastMsg = "BUY: TP must be above price."; return; }
      if(tType[i] == 1 && px >= lastBid) { lastMsg = "SELL: TP must be below price."; return; }
      SetTP(i, px);
      lastMsg = StringFormat("#%d TP -> %s", tId[i], DoubleToString(tTP[i], digitsV));
   }
}
void ResetStats()
{
   if(rstTick == 0 || GetTickCount() - rstTick > 6000)
   {
      rstTick = GetTickCount();
      lastMsg = "Press Reset again within 6 s to archive batch '" + bName + "' and start it from zero.";
      return;
   }
   rstTick = 0;
   string st = TimeToString(TimeLocal(), TIME_DATE | TIME_MINUTES);
   StringReplace(st, ".", "");
   StringReplace(st, ":", "");
   StringReplace(st, " ", "_");
   FileMove(fLog,   0, "RP_" + bName + "_log_old_" + st + ".csv", FILE_REWRITE);
   FileMove(fSum,   0, "RP_" + bName + "_summary_old_" + st + ".csv", FILE_REWRITE);
   FileMove(fState, 0, "RP_" + bName + "_state_old_" + st + ".csv", FILE_REWRITE);
   hN = 0; closedPL = 0; sumR = 0; nWin = 0; nLoss = 0;
   SaveState();
   lastMsg = "Batch '" + bName + "' archived (old files kept as _old_" + st + "). Counting from zero.";
}
// SL/TP lines of open trades are draggable: read their prices back
void SyncLines()
{
   for(int i = 0; i < tN; i++)
   {
      string k = IntegerToString(tId[i]);
      if(tSL[i] > 0)
      {
         if(ObjectFind(cid, "RP_S" + k) >= 0) tSL[i] = ObjectGetDouble(cid, "RP_S" + k, OBJPROP_PRICE);
         else tSL[i] = 0;
      }
      if(tTP[i] > 0)
      {
         if(ObjectFind(cid, "RP_T" + k) >= 0) tTP[i] = ObjectGetDouble(cid, "RP_T" + k, OBJPROP_PRICE);
         else tTP[i] = 0;
      }
   }
}
void CheckTrades(double hi, double lo)
{
   for(int i = tN - 1; i >= 0; i--)
   {
      if(tType[i] == 0)
      {
         if(tSL[i] > 0 && lo <= tSL[i])      CloseTrade(i, tSL[i]);
         else if(tTP[i] > 0 && hi >= tTP[i]) CloseTrade(i, tTP[i]);
      }
      else
      {
         if(tSL[i] > 0 && hi + SpreadPrice >= tSL[i])      CloseTrade(i, tSL[i]);
         else if(tTP[i] > 0 && lo + SpreadPrice <= tTP[i]) CloseTrade(i, tTP[i]);
      }
   }
}
// trailing: SL only ever moves toward price, based on completed M1 extremes
void ApplyTrailing(double hi, double lo)
{
   for(int i = 0; i < tN; i++)
   {
      if(tTrail[i] <= 0 || tSL[i] <= 0) continue;
      if(tType[i] == 0)
      {
         double n = hi - tTrail[i];
         if(n > tSL[i]) SetSL(i, n);
      }
      else
      {
         double n = lo + tTrail[i];
         if(n < tSL[i]) SetSL(i, n);
      }
   }
}
//--------------------------------------------------------------------
// Replay one M1 bar into the forming bar of EVERY timeframe
void StepM1()
{
   if(idx < 0) return;
   datetime t = iTime(src, rTF, idx);
   double o = iOpen(src, rTF, idx), hi = iHigh(src, rTF, idx);
   double lo = iLow(src, rTF, idx), c = iClose(src, rTF, idx);
   double v = (double)iVolume(src, rTF, idx);

   for(int k = 0; k < NTF; k++)
   {
      if(TFS[k] < rTF) continue;
      datetime bs = BarStart(k, t);
      if(bs != fS[k])
      {
         fS[k] = bs; fO[k] = o; fH[k] = hi; fL[k] = lo; fC[k] = c; fV[k] = v;
         FileSeek(hF[k], 0, SEEK_END);
      }
      else
      {
         if(hi > fH[k]) fH[k] = hi;
         if(lo < fL[k]) fL[k] = lo;
         fC[k] = c; fV[k] += v;
         FileSeek(hF[k], -44, SEEK_END);
      }
      WriteBar(hF[k], fS[k], fO[k], fH[k], fL[k], fC[k], fV[k]);
      FileFlush(hF[k]);
   }

   lastT = t;
   CheckTrades(hi, lo);
   ApplyTrailing(hi, lo);
   CheckPending(hi, lo);      // a pending order filled on this bar is first checked against SL/TP on the NEXT bar
   lastBid = c;
   idx--;
}
// Advance until the next bar of timeframe index k is complete
void StepBar(int k)
{
   if(idx < 0) return;
   if(TFS[k] < rTF) k = KOf(rTF);      // cannot step finer than the replay data
   datetime t = iTime(src, rTF, idx);
   datetime ns = BarStart(k, t);
   while(idx >= 0)
   {
      datetime tt = iTime(src, rTF, idx);
      if(BarStart(k, tt) != ns) break;
      StepM1();
      if(pFilled) break;      // stop stepping when the pending order fills
   }
   ApplySel();
}
//--------------------------------------------------------------------
void JumpTo(datetime t)
{
   if(t <= 0) { lastMsg = "Date format: YYYY.MM.DD HH:MM (server time)"; return; }
   int s0;
   if(!CheckData(t, s0))
   {
      // nothing changes: trades stay open, replay stays where it is
      ObjectSetString(cid, "RP_date", OBJPROP_TEXT, TimeToString(lastT, TIME_DATE | TIME_MINUTES));
      lastMsg = "Jump cancelled. " + lastMsg;
      return;
   }
   CancelPend();
   CloseAll();
   CloseFiles();
   if(BuildAll(t))
   {
      startT = t;
      lastMsg = "Jumped to " + TimeToString(lastT, TIME_DATE | TIME_MINUTES);
   }
   if(!OpenFiles()) lastMsg = lastMsg + "  (reopen failed - run the script again)";
   if(ObjectFind(cid, "RP_SLLINE") >= 0) ObjectSetDouble(cid, "RP_SLLINE", OBJPROP_PRICE, lastBid - InitSLDist);
   Refresh();
}
//--------------------------------------------------------------------
// Price levels: Previous-day H/L/C and Weekly Map (same maths as Executive Hub)
// Only COMPLETED daily/weekly bars before the replay time are used -> no future leak.
#define MAXLV 80
bool     pdOn = false, wmOn = false;
double   lvP[MAXLV];
string   lvT[MAXLV];
color    lvC[MAXLV];
int      lvS[MAXLV];
int      lvDay = -1;
double   wmHi = 0, wmLo = 0;     // outermost Weekly-Map levels drawn (redraw only if price passes them)
bool     lvForce = true;
int      lvN = 0, lvDrawn = 0;
double   pvP[MAXLV];
string   pvT[MAXLV];
int      pvN = -1;

void AddLv(double p, string t, color c, int st)
{
   if(lvN >= MAXLV || p <= 0) return;
   lvP[lvN] = p; lvT[lvN] = t; lvC[lvN] = c; lvS[lvN] = st; lvN++;
}
color LvContrast(color forDark, color forLight)
{
   long bg = ChartGetInteger(cid, CHART_COLOR_BACKGROUND, 0);
   int r = (int)(bg & 0xFF), g = (int)((bg >> 8) & 0xFF), b = (int)((bg >> 16) & 0xFF);
   return((0.299 * r + 0.587 * g + 0.114 * b < 140) ? forDark : forLight);
}
void PDLevels()
{
   int ds = iBarShift(src, PERIOD_D1, lastT, false);
   if(ds < 0) return;
   int pv = ds + 1;                                   // previous completed (server) day
   if(pv >= iBars(src, PERIOD_D1)) return;
   color cHL = LvContrast(C'214,158,60', C'150,100,20');
   color cC  = LvContrast(C'160,125,70', C'120,85,30');
   AddLv(iHigh(src, PERIOD_D1, pv),  "PDH", cHL, STYLE_DASH);
   AddLv(iLow(src, PERIOD_D1, pv),   "PDL", cHL, STYLE_DASH);
   AddLv(iClose(src, PERIOD_D1, pv), "PDC", cC,  STYLE_DOT);
}
void WMLevels()
{
   int ws = iBarShift(src, PERIOD_W1, lastT, false);
   if(ws < 0) return;
   int pv = ws + 1;                                   // previous completed week
   if(pv >= iBars(src, PERIOD_W1)) return;
   double wh = iHigh(src, PERIOD_W1, pv), wl = iLow(src, PERIOD_W1, pv);
   double range = wh - wl;
   if(range <= 0 || wh <= 0 || wl <= 0) return;
   double step = range * 0.25;

   // extremes of the CURRENT week, from replayed data only (up to the last replayed bar)
   double pMax = lastBid, pMin = lastBid;
   datetime wst = iTime(src, PERIOD_W1, ws);
   int a = iBarShift(src, rTF, wst, false);
   if(a >= 0 && iTime(src, rTF, a) < wst) a--;
   int cnt = a - idx;
   if(a >= 0 && cnt > 0)
   {
      int hs = iHighest(src, rTF, MODE_HIGH, cnt, idx + 1);
      int ls = iLowest(src, rTF, MODE_LOW, cnt, idx + 1);
      if(hs >= 0 && iHigh(src, rTF, hs) > pMax) pMax = iHigh(src, rTF, hs);
      if(ls >= 0 && iLow(src, rTF, ls) < pMin)  pMin = iLow(src, rTF, ls);
   }
   int kUp = 1, kDown = 1;
   if(pMax > wh) kUp   = (int)MathMax(1.0, MathFloor((pMax - wh) / step) + 1.0);
   if(pMin < wl) kDown = (int)MathMax(1.0, MathFloor((wl - pMin) / step) + 1.0);
   if(kUp > 40) kUp = 40;
   if(kDown > 40) kDown = 40;

   color cEx  = LvContrast(clrSilver, clrDimGray);
   color cIn  = LvContrast(clrDimGray, clrGray);
   color cExt = LvContrast(clrGainsboro, C'40,40,40');
   AddLv(wh,                "WH",     cEx,  STYLE_DASH);
   AddLv(wl,                "WL",     cEx,  STYLE_DASH);
   AddLv(wl + range * 0.25, "25%",    cIn,  STYLE_DASH);
   AddLv(wl + range * 0.50, "50%",    cIn,  STYLE_DASH);
   AddLv(wl + range * 0.75, "75%",    cIn,  STYLE_DASH);
   for(int u = 1; u <= kUp; u++)
      AddLv(wh + range * 0.25 * u, "WH+" + IntegerToString(25 * u) + "%", cExt, STYLE_DASH);
   for(int d = 1; d <= kDown; d++)
      AddLv(wl - range * 0.25 * d, "WL-" + IntegerToString(25 * d) + "%", cExt, STYLE_DASH);
   wmHi = wh + range * 0.25 * kUp;
   wmLo = wl - range * 0.25 * kDown;
}
void DrawLevels()
{
   lvN = 0;
   wmHi = 0; wmLo = 0;
   if(pdOn) PDLevels();
   if(wmOn) WMLevels();
   if((pdOn || wmOn) && lvN == 0) lastMsg = "Level data not available for this date (load D1/W1 history).";

   // nothing changed since the last draw -> do not touch any object
   bool same = (lvN == pvN);
   if(same)
      for(int q = 0; q < lvN; q++)
         if(lvP[q] != pvP[q] || lvT[q] != pvT[q]) { same = false; break; }
   if(same) return;
   pvN = lvN;
   for(int q = 0; q < lvN; q++) { pvP[q] = lvP[q]; pvT[q] = lvT[q]; }

   for(int i = 0; i < lvN; i++)
   {
      string ln = "RP_LV" + IntegerToString(i);
      if(ObjectFind(cid, ln) < 0)
      {
         ObjectCreate(cid, ln, OBJ_HLINE, 0, 0, lvP[i]);
         ObjectSetInteger(cid, ln, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(cid, ln, OBJPROP_HIDDEN, true);
         ObjectSetInteger(cid, ln, OBJPROP_WIDTH, 1);
         ObjectSetInteger(cid, ln, OBJPROP_BACK, false);
      }
      else ObjectSetDouble(cid, ln, OBJPROP_PRICE, lvP[i]);
      ObjectSetInteger(cid, ln, OBJPROP_STYLE, lvS[i]);
      ObjectSetInteger(cid, ln, OBJPROP_COLOR, lvC[i]);
      ObjectSetString(cid, ln, OBJPROP_TEXT, lvT[i]);      // tag is the object description (no refresh needed)
   }
   for(int j = lvN; j < lvDrawn; j++)
      ObjectDelete(cid, "RP_LV" + IntegerToString(j));
   lvDrawn = lvN;
}
//--------------------------------------------------------------------
// KEY TIME: the same 16 lines as the Risk Manager EA v107 (FEAT-060, market-anchored DST).
// Every line is anchored to the LOCAL clock of its own market (New York / Tokyo / Frankfurt / London /
// Sydney), each with its own DST rule, evaluated per day. The broker server follows US DST:
// UTC+3 in US-DST, UTC+2 otherwise. So Tokyo lines move by 1h when the US changes clocks, London/Frankfurt
// lines move in the weeks where US and EU DST differ, and NY lines never move. Works on the offline
// chart (no tick/clock calibration, depends only on the date).
#define KM_NY      0
#define KM_LONDON  1
#define KM_BERLIN  2
#define KM_TOKYO   3
#define KM_SYDNEY  4
#define KT_SYDNEY_FINAL_HOUR 16     // local hour of the Sydney sub line (same constant as the EA)
bool   ktOn = false;
int    ktDay = -1;                // broker day currently drawn (-1 = nothing)
//                   main:  M1  M2  M3  M4  M5  M6  M7  M8     sub:  S1  S2                   S3  S4  S5  S6  S7  S8
int    ktH[16]   = {        17,  9, 10,  8,  8,  9, 11, 13,        13, KT_SYDNEY_FINAL_HOUR,  19,  8, 14, 16, 17, 18 };
int    ktM[16]   = {         0,  0,  0,  0,  0, 30,  0,  0,         0,  0,                     0, 30,  0,  0,  0,  0 };
int    ktMkt[16] = { KM_NY, KM_TOKYO, KM_TOKYO, KM_BERLIN, KM_LONDON, KM_NY, KM_NY, KM_NY,
                     KM_TOKYO, KM_SYDNEY, KM_TOKYO, KM_NY, KM_NY, KM_NY, KM_LONDON, KM_TOKYO };

int KtFirstSunday(int y, int month)
{
   datetime f = StringToTime(StringFormat("%04d.%02d.01 00:00", y, month));
   int dow = TimeDayOfWeek(f);
   return((dow == 0) ? 1 : (8 - dow));
}
int KtLastSunday31(int y, int month)       // only for 31-day months (March / October)
{
   datetime l = StringToTime(StringFormat("%04d.%02d.31 00:00", y, month));
   return(31 - TimeDayOfWeek(l));
}
// US: 2nd Sunday of March 07:00 UTC -> 1st Sunday of November 06:00 UTC
bool KtIsUSDST(datetime utc)
{
   int y = TimeYear(utc);
   datetime s = StringToTime(StringFormat("%04d.03.%02d 07:00", y, KtFirstSunday(y, 3) + 7));
   datetime e = StringToTime(StringFormat("%04d.11.%02d 06:00", y, KtFirstSunday(y, 11)));
   return(utc >= s && utc < e);
}
// EU: last Sunday of March 01:00 UTC -> last Sunday of October 01:00 UTC
bool KtIsEUDST(datetime utc)
{
   int y = TimeYear(utc);
   datetime s = StringToTime(StringFormat("%04d.03.%02d 01:00", y, KtLastSunday31(y, 3)));
   datetime e = StringToTime(StringFormat("%04d.10.%02d 01:00", y, KtLastSunday31(y, 10)));
   return(utc >= s && utc < e);
}
// AU (southern): DST from 1st Sunday of October to 1st Sunday of April (switch = Saturday 16:00 UTC)
bool KtIsAUDST(datetime utc)
{
   int y = TimeYear(utc);
   datetime e = StringToTime(StringFormat("%04d.04.%02d 00:00", y, KtFirstSunday(y, 4)))  - 8 * 3600;
   datetime s = StringToTime(StringFormat("%04d.10.%02d 00:00", y, KtFirstSunday(y, 10))) - 8 * 3600;
   return(utc < e || utc >= s);
}
int KtMarketStdSec(int mkt)
{
   switch(mkt)
   {
      case KM_NY:     return(-5 * 3600);
      case KM_LONDON: return(0);
      case KM_BERLIN: return(1 * 3600);
      case KM_TOKYO:  return(9 * 3600);
      case KM_SYDNEY: return(10 * 3600);
   }
   return(0);
}
int KtMarketOffsetSec(int mkt, datetime utc)     // local = utc + offset
{
   int off = KtMarketStdSec(mkt);
   bool dst = false;
   if(mkt == KM_NY)                              dst = KtIsUSDST(utc);
   else if(mkt == KM_LONDON || mkt == KM_BERLIN) dst = KtIsEUDST(utc);
   else if(mkt == KM_SYDNEY)                     dst = KtIsAUDST(utc);
   return(dst ? off + 3600 : off);
}
datetime KtLocalToUtc(int mkt, datetime localRaw)
{
   datetime guess = localRaw - KtMarketStdSec(mkt);
   return(localRaw - KtMarketOffsetSec(mkt, guess));
}
// broker server offset at a UTC instant: input = US-summer offset, winter = minus 1h
int KtServerOffsetSec(datetime utc)
{
   int summer = ServerUtcOffsetMin * 60;
   return(KtIsUSDST(utc) ? summer : summer - 3600);
}
// server time of key line i on broker-calendar day d (d = days since 1970)
datetime KtLineTime(int i, int d)
{
   long base = (long)d * 86400;
   if(i == 0) base -= 86400;                     // M1 = NY 17:00 of the PREVIOUS calendar day
   datetime localRaw = (datetime)(base + ktH[i] * 3600 + ktM[i] * 60);
   datetime utc = KtLocalToUtc(ktMkt[i], localRaw);
   return(utc + KtServerOffsetSec(utc));
}
color KtColor(bool isMain)
{
   long bg = ChartGetInteger(cid, CHART_COLOR_BACKGROUND, 0);
   int bR = (int)(bg & 0xFF), bG = (int)((bg >> 8) & 0xFF), bB = (int)((bg >> 16) & 0xFF);
   int rf = (0.299 * bR + 0.587 * bG + 0.114 * bB > 140) ? 0 : 255;
   int pct = isMain ? 17 : 10;
   int r = bR + (int)((rf - bR) * pct / 100.0);
   int g = bG + (int)((rf - bG) * pct / 100.0);
   int b = bB + (int)((rf - bB) * pct / 100.0);
   return((color)(r | (g << 8) | (b << 16)));
}
// Draws the 16 lines of the CURRENT broker day once (at the first candle of the day).
// Nothing is refreshed afterwards until the next day starts, the button is toggled or Go is used.
void KeyTimeSync()
{
   ObjectsDeleteAll(cid, "RP_KT_");
   ktDay = -1;
   if(!ktOn) return;
   int d = (int)((long)lastT / 86400);
   ktDay = d;
   color cMain = KtColor(true), cSub = KtColor(false);
   for(int i = 0; i < 16; i++)
   {
      datetime t = KtLineTime(i, d);
      string ln = "RP_KT_L" + IntegerToString(i);
      ObjectCreate(cid, ln, OBJ_VLINE, 0, t, 0);
      ObjectSetInteger(cid, ln, OBJPROP_COLOR, (i < 8) ? cMain : cSub);
      ObjectSetInteger(cid, ln, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(cid, ln, OBJPROP_WIDTH, 1);
      ObjectSetInteger(cid, ln, OBJPROP_BACK, true);
      ObjectSetInteger(cid, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(cid, ln, OBJPROP_HIDDEN, true);
      ObjectSetString(cid, ln, OBJPROP_TEXT, TimeToString(t, TIME_MINUTES));      // broker (server) time of the line
   }
}
//--------------------------------------------------------------------
// chart look from the Inputs (grid, candle mode, colors)
void ApplyLook(long c)
{
   if(!UseLook) return;
   ChartSetInteger(c, CHART_MODE, UseCandles ? CHART_CANDLES : CHART_BARS);
   ChartSetInteger(c, CHART_SHOW_GRID, ShowGrid ? 1 : 0);
   ChartSetInteger(c, CHART_COLOR_BACKGROUND, ColBack);
   ChartSetInteger(c, CHART_COLOR_FOREGROUND, ColFore);
   ChartSetInteger(c, CHART_COLOR_CHART_UP, ColBull);
   ChartSetInteger(c, CHART_COLOR_CHART_DOWN, ColBear);
   ChartSetInteger(c, CHART_COLOR_CANDLE_BULL, ColBull);
   ChartSetInteger(c, CHART_COLOR_CANDLE_BEAR, ColBear);
   ChartSetInteger(c, CHART_COLOR_CHART_LINE, ColFore);
   ChartRedraw(c);
}
// apply the look (and template, if any) to every other offline window you open by hand
void ThemeOthers()
{
   if(tplName == "" && !UseLook) return;
   long c = ChartFirst();
   while(c >= 0)
   {
      if(c != cid && ChartSymbol(c) == offSym)
      {
         bool done = false;
         for(int i = 0; i < nTh; i++) if(thId[i] == c) { done = true; break; }
         if(!done && nTh < 20)
         {
            thId[nTh] = c; nTh++;
            if(tplName != "") { ChartApplyTemplate(c, tplName); ObjectsDeleteAll(c, "RP_"); }
            ApplyLook(c);
         }
      }
      c = ChartNext(c);
   }
}
//--------------------------------------------------------------------
void OnStart()
{
   src = Symbol();
   offSym = src + "_R";
   if(StringLen(offSym) > 12) offSym = StringSubstr(src, 0, 10) + "_R";
   digitsV = (int)MarketInfo(src, MODE_DIGITS);
   delayMs = PlayDelayMs;
   rTF = (ReplayTF == PERIOD_M5) ? PERIOD_M5 : PERIOD_M1;
   for(int k = 0; k < NTF; k++)
   {
      hF[k] = -1;
      fS[k] = 0;
      fOff[k] = (int)((long)iTime(src, TFS[k], 0) % (TFS[k] * 60));
   }

   datetime t0 = StringToTime(StartTime);
   if(t0 <= 0) { Alert("StartTime format must be: YYYY.MM.DD HH:MM"); return; }

   string want = BatchName;
   StringTrimLeft(want);
   StringTrimRight(want);
   if(want == "")
   {
      int lf = FileOpen("RP_last.csv", FILE_CSV | FILE_READ | FILE_SHARE_READ, ';');
      if(lf >= 0) { want = FileReadString(lf); FileClose(lf); }
      if(want == "") want = "Batch1";
   }
   bName  = SafeName(want);
   int lw = FileOpen("RP_last.csv", FILE_CSV | FILE_WRITE, ';');
   if(lw >= 0) { FileWrite(lw, bName); FileClose(lw); }
   fLog   = "RP_" + bName + "_log.csv";
   fSum   = "RP_" + bName + "_summary.csv";
   fState = "RP_" + bName + "_state.csv";
   datetime rt = LoadBatch();
   bool resumed = (rt > 0);
   if(resumed) t0 = rt;
   LoadStrategies();
   RestoreTag();

   // close old replay charts
   long c = ChartFirst();
   while(c >= 0)
   {
      long nx = ChartNext(c);
      if(ChartSymbol(c) == offSym) ChartClose(c);
      c = nx;
   }
   Sleep(500);

   if(!BuildAll(t0))
   {
      Alert(lastMsg, "  (Open a ", (rTF == PERIOD_M5 ? "M5" : "M1"), " chart of ", src, ", press Home to load history, raise 'Max bars in chart'.)");
      return;
   }
   startT = t0;

   cid = ChartOpen(offSym, (int)DisplayTF);
   if(cid == 0)
   {
      // ChartOpen cannot open offline symbols on some brokers: wait for manual open
      Alert("Now open the chart manually: File > Open Offline > ", offSym, ",M", (int)DisplayTF,
            " > Open.  (Script waits 3 minutes. Do NOT stop the script.)");
      Comment("ReplayPro: waiting for you to open offline chart ", offSym);
      for(int w = 0; w < 1800 && !IsStopped(); w++)
      {
         long cc = ChartFirst();
         while(cc >= 0)
         {
            if(ChartSymbol(cc) == offSym) { cid = cc; break; }
            cc = ChartNext(cc);
         }
         if(cid != 0) break;
         Sleep(100);
      }
      Comment("");
      if(cid == 0)
      {
         Alert("Offline chart was not opened in time. Run the script again.");
         return;
      }
   }
   Sleep(1500);

   if(!OpenFiles()) { Alert(lastMsg); CloseFiles(); return; }

   string tplMsg = "";
   tplName = ChartTemplate;
   StringTrimLeft(tplName);
   StringTrimRight(tplName);
   if(tplName != "")
   {
      if(StringFind(tplName, ".tpl") < 0) tplName = tplName + ".tpl";
      if(ChartApplyTemplate(cid, tplName)) { Sleep(600); ObjectsDeleteAll(cid, "RP_"); }
      else { tplMsg = " Template '" + tplName + "' not found (save it first: right-click chart > Template > Save Template)."; tplName = ""; }
   }
   ApplyLook(cid);
   ChartSetInteger(cid, CHART_AUTOSCROLL, true);
   ChartSetInteger(cid, CHART_SHIFT, true);
   ChartSetDouble(cid, CHART_SHIFT_SIZE, 25.0);     // free space on the right for the panel
   ChartSetInteger(cid, CHART_SHOW_OBJECT_DESCR, true);   // level / Key Time tags are object descriptions
   BuildUI();
   if(sRisk != "") ObjectSetString(cid, "RP_risk", OBJPROP_TEXT, sRisk);
   if(sTpr  != "") ObjectSetString(cid, "RP_tpr",  OBJPROP_TEXT, sTpr);
   if(sStep != "") ObjectSetString(cid, "RP_step", OBJPROP_TEXT, sStep);
   if(sTrl  != "") ObjectSetString(cid, "RP_trl",  OBJPROP_TEXT, sTrl);
   Refresh();
   lastMsg = "Ready. Drag the yellow line = your stop, then BUY/SELL.";
   if(resumed) lastMsg = StringFormat("Batch '%s' continued: %d trades, %+.1fR.", bName, hN, sumR);
   else        lastMsg = "New batch '" + bName + "'. " + lastMsg;
   lastMsg = lastMsg + tplMsg;
   if(rTF == PERIOD_M5) lastMsg = "M5 mode: smallest step = 5 min. " + lastMsg;
   UpdateInfo();

   // main loop
   int miss = 0;
   bool statsPrev = false;
   int  tgTick = 0, thTick = 0;
   while(!IsStopped())
   {
      if(ObjectFind(cid, "RP_exit") < 0)
      {
         miss++;
         if(miss > 100) break;          // chart really closed
         Sleep(30);
         continue;
      }
      miss = 0;
      if(Pressed("RP_exit")) break;
      if(Pressed("RP_tab1")) SetTab(1);
      if(Pressed("RP_tab3")) SetTab(3);

      SyncLines();

      bool moved = false;
      if(Pressed("RP_next")) { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); StepBar(KOf(ChartPeriod(cid))); moved = true; }
      if(Pressed("RP_m1"))   { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); StepBar(0); moved = true; }
      if(Pressed("RP_m5"))   { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); StepBar(1); moved = true; }
      if(Pressed("RP_m15"))  { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); StepBar(2); moved = true; }
      if(Pressed("RP_h1"))   { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); StepBar(4); moved = true; }
      if(Pressed("RP_slow")) { delayMs = MathMin(delayMs * 2, 5000); moved = true; }
      if(Pressed("RP_fast")) { delayMs = MathMax(delayMs / 2, 5); moved = true; }

      if(Pressed("RP_buy"))   { OpenTrade(0); moved = true; }
      if(Pressed("RP_sell"))  { OpenTrade(1); moved = true; }
      if(Pressed("RP_dash"))  { OpenDashboard(); moved = true; }
      if(Pressed("RP_cal"))   { if(calOn) CalClose(); else CalOpen(); }
      if(calOn && CalHandle()) ObjectSetInteger(cid, "RP_go", OBJPROP_STATE, true);      // picked a date -> same path as the Go button
      if(Pressed("RP_strat")) { CycleCat(); moved = true; }
      if(Pressed("RP_setup")) { CycleSetup(); moved = true; }
      if(Pressed("RP_tag"))   { RetagSel(); moved = true; }
      if(Pressed("RP_cl1"))   { CloseLast(); moved = true; }
      if(Pressed("RP_clall")) { CloseAll(); moved = true; }
      if(Pressed("RP_reset")) { ResetStats(); moved = true; }
      if(Pressed("RP_save"))  { SaveSummary(); lastMsg = "Summary saved (RP_" + bName + "_summary.csv)."; moved = true; }

      if(Pressed("RP_padd"))  { AddPend(); moved = true; }
      if(Pressed("RP_pcan"))  { CancelPend(); moved = true; }
      if(pFilled) { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); pFilled = false; moved = true; }
      if(Pressed("RP_sel"))   { NextSel(); moved = true; }
      if(Pressed("RP_be"))    { MoveBE(); moved = true; }
      if(Pressed("RP_tight")) { MoveSL(+1); moved = true; }
      if(Pressed("RP_loose")) { MoveSL(-1); moved = true; }
      if(Pressed("RP_trail")) { ToggleTrail(); moved = true; }
      if(Pressed("RP_setsl")) { SetPrice(false); moved = true; }
      if(Pressed("RP_settp")) { SetPrice(true); moved = true; }

      if(Pressed("RP_go"))
      {
         ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false);
         JumpTo(StringToTime(NormDate(ObjectGetString(cid, "RP_date", OBJPROP_TEXT))));
         SaveState();
         lvForce = true;
         if(ktOn) KeyTimeSync();
         moved = true;
      }

      bool playing = (ObjectGetInteger(cid, "RP_play", OBJPROP_STATE) != 0);
      if(playing)
      {
         if(idx >= 0) { StepM1(); moved = true; }
         else { ObjectSetInteger(cid, "RP_play", OBJPROP_STATE, false); lastMsg = "End of data."; moved = true; }
      }

      bool statsOn = false;      // v4.10: Stats overlay removed (use the Dashboard)
      if(statsOn != statsPrev)
      {
         statsPrev = statsOn;
         if(!statsOn) ClearStats();
         else SaveSummary();
         moved = true;
      }

      if(++tgTick >= 4)          // level toggles are polled every few loops (saves cross-thread calls)
      {
         tgTick = 0;
         ApplyToggles();
         if(pOn) UpdatePendLabel();
         bool pdNow = (ObjectGetInteger(cid, "RP_pd", OBJPROP_STATE) != 0);
         bool wmNow = (ObjectGetInteger(cid, "RP_wm", OBJPROP_STATE) != 0);
         bool ktNow = (ObjectGetInteger(cid, "RP_kt", OBJPROP_STATE) != 0);
         if(pdNow != pdOn || wmNow != wmOn) { pdOn = pdNow; wmOn = wmNow; lvForce = true; moved = true; }
         if(ktNow != ktOn) { ktOn = ktNow; KeyTimeSync(); moved = true; }
         if(++thTick >= 10) { thTick = 0; ThemeOthers(); }
      }

      if(moved)
      {
         if(++stepCnt >= 200) { stepCnt = 0; SaveState(); }
         if(pOn) UpdatePendLabel();
         int dNowL = (int)((long)lastT / 86400);
         if(pdOn || wmOn || lvDrawn > 0)
         {
            // levels only change when a new day starts, after a toggle/jump, or when price runs past the outermost Weekly-Map line
            bool need = lvForce || dNowL != lvDay || (wmOn && wmHi > 0 && (lastBid > wmHi || lastBid < wmLo));
            if(need) { DrawLevels(); lvDay = dNowL; lvForce = false; }
         }
         if(ktOn && dNowL != ktDay) KeyTimeSync();
         Refresh();
         UpdateInfo();
         if(statsOn) UpdateStats();
      }
      Sleep(playing ? delayMs : 30);
   }

   CloseAll();          // trades still open are closed at market and logged
   SaveSummary();
   SaveState();
   CloseFiles();
   if(cid != 0 && ObjectFind(cid, "RP_exit") >= 0)
   {
      ObjectsDeleteAll(cid, "RP_");     // remove the (now dead) panel and lines
      ChartRedraw(cid);
      ChartClose(cid);                  // close the control chart; other offline windows can be closed by hand
   }
   Print("ReplayPro finished. Closed P/L: ", DoubleToString(closedPL, 2), "  Total R: ", DoubleToString(sumR, 2));
}
//+------------------------------------------------------------------+
