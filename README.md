# ReplayPro

Manual candle-by-candle replay / backtest script for **MetaTrader 4** (MQL4).
It builds an offline chart where future candles do not exist, so you can practise trades on past data (XAUUSD, M5 replay) with virtual balance, risk %, pending orders, strategy/setup tags, a trade log and a dashboard.

**Current version: v4.00 — no DLL needed** (keep "Allow DLL imports" OFF).

## Install
1. Copy `MQL4/Scripts/ReplayPro.mq4` to `MQL4\Scripts\` and compile it in MetaEditor.
2. Copy the files in `MQL4/Files/` to `MQL4\Files\` (`RM_StrategySetups.txt` = strategy/setup list shared with RiskManager EA, `RP_Dashboard.html` = dashboard page).
3. Run the script on a chart of the symbol (e.g. XAUUSD). It opens the offline `<symbol>_R` chart.

## Dashboard (no DLL)
The Dashboard button writes `MQL4\Files\RP_data.txt`. Open `MQL4\Files\RP_Dashboard.html` in Chrome (bookmark it) and press F5. A script cannot start the browser without a DLL.

## How v4.00 works without a DLL
The offline chart is refreshed with `ChartSetSymbolPeriod()` on every open `*_R` window (the old versions posted a window message through `user32.dll`). Tested: smooth at 2 bars/second, drawings on the chart survive.

## Repository layout
- `MQL4/Scripts/ReplayPro.mq4` — current script (v4.00)
- `MQL4/Files/` — files that go to `MQL4\Files`
- `docs/` — user guide (Persian PDF, written for v3.x), hand-off notes, changelog
- `archive/` — previous version with DLL imports (v3.75), kept for history

Notes: the guide PDF and hand-off still describe the DLL-based Dashboard button (v3.x). Not compiled in the cloud — every change is tested by the owner in MT4.

Related project: [RiskManager-EA](https://github.com/Mahmoudsy-projects/RiskManager-EA).
