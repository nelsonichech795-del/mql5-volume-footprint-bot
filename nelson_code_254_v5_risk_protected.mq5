//+------------------------------------------------------------------+
//| Volume Footprint EA - Risk-Protected v5.0                        |
//| Multi-timeframe with loss prevention and signal validation       |
//+------------------------------------------------------------------+
#property copyright "Volume Footprint Bot - Risk Protected"
#property link      "https://github.com/nelsonichech795-del/mql5-volume-footprint-bot"
#property version   "5.0"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters - CRITICAL RISK MANAGEMENT
input double BaseLotSize = 0.01;                 // REDUCED: Start small for safety
input double TakeProfit = 100;                   // INCREASED: Wider profit targets
input double StopLoss = 40;                      // TIGHTER: Controlled losses
input int MagicNumber = 25402;                   // Magic number (Nelson Code 254 v5)
input double VolumeMultiplier = 2.0;             // STRICTER: Need 2x volume
input int LookbackBars = 20;                     // EXTENDED: Better average
input double MinVolumeThreshold = 500;           // HIGHER: Filter weak signals
input bool AutoAdapt = true;                     // Auto-adapt to currency type

//--- Risk Management Settings
input double MaxRiskPercent = 1.0;               // Risk max 1% of account per trade
input double DailyLossLimit = 5.0;               // Stop trading if loss > 5% daily
input int MaxPositionsPerDay = 5;                // Max 5 trades per day
input double MinSignalStrength = 0.75;           // STRICT: 75% minimum signal strength
input bool UseTrailingStop = true;               // Trailing stop for profit protection
input int TrailingStopPoints = 15;               // Trail by 15 points once profit > 20

//--- Timeframe Settings
input ENUM_TIMEFRAMES PrimaryTimeframe = PERIOD_M1;
input ENUM_TIMEFRAMES SecondaryTimeframe = PERIOD_M5;
input bool UseMultiTimeframe = true;
input bool CloseOnNewSignal = true;

//--- Global variables
CTrade trade;
datetime lastOrderTime = 0;
int pointValue = 1;
string currencyType = "";
double volatilityFactor = 1.0;
double tpMultiplier = 1.0;
double slMultiplier = 1.0;
double lotMultiplier = 1.0;
double volumeThreshold = 2.0;

int tradesTodayCount = 0;
double dailyLoss = 0.0;
datetime lastTradeDatetime = 0;
ulong lastPositionTicket = 0;
string lastSignalType = "";
datetime lastSignalTime = 0;

//--- Historical tracking
struct TradeResult
{
    datetime time;
    string type;
    double profit;
    double lot;
};

TradeResult tradeHistory[100];
int historyIndex = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(PrimaryTimeframe != PERIOD_M1 && PrimaryTimeframe != PERIOD_M5 && PrimaryTimeframe != PERIOD_M15)
    {
        Alert("Primary timeframe must be M1, M5, or M15!");
        return INIT_FAILED;
    }
    
    // Set point value
    if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 || SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3)
        pointValue = 10;
    else
        pointValue = 1;
    
    trade.SetExpertMagicNumber(MagicNumber);
    
    // Detect currency and adapt
    if(AutoAdapt)
    {
        DetectCurrencyType();
        AdaptToMarketConditions();
    }
    
    // Initialize daily counters
    lastTradeDatetime = TimeCurrent();
    tradesTodayCount = 0;
    dailyLoss = 0.0;
    
    Print("=== VOLUME FOOTPRINT EA v5.0 - RISK PROTECTED ===");
    Print("Symbol: ", _Symbol, " | Currency: ", currencyType);
    Print("Risk per Trade: ", MaxRiskPercent, "% | Daily Loss Limit: ", DailyLossLimit, "%");
    Print("Max Trades/Day: ", MaxPositionsPerDay);
    Print("Min Signal Strength: ", MinSignalStrength * 100, "%");
    Print("Volume Multiplier: ", VolumeMultiplier, "x (STRICT FILTER)");
    Print("Base Lot: ", BaseLotSize, " | TP: ", TakeProfit, " pips | SL: ", StopLoss, " pips");
    Print("Trailing Stop: ", UseTrailingStop ? "ENABLED" : "DISABLED");
    Print("===================================================");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("Volume Footprint EA v5.0 Stopped - Final Status Report");
    PrintTradeHistory();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Update daily counters if new day
    if(TimeCurrent() - lastTradeDatetime > 86400)  // 24 hours
    {
        ResetDailyCounters();
    }
    
    // Check daily loss limit
    if(dailyLoss >= (AccountInfoDouble(ACCOUNT_BALANCE) * DailyLossLimit / 100.0))
    {
        UpdateComment();
        return;  // Stop trading for the day
    }
    
    // Check max trades per day
    if(tradesTodayCount >= MaxPositionsPerDay)
    {
        UpdateComment();
        return;  // Max trades reached
    }
    
    // Analyze timeframes
    AnalyzeTimeframe(PrimaryTimeframe, "PRIMARY");
    
    if(UseMultiTimeframe)
    {
        AnalyzeTimeframe(SecondaryTimeframe, "SECONDARY");
    }
    
    // Manage positions with trailing stop
    ManagePositions();
    
    // Update display
    UpdateComment();
}

//+------------------------------------------------------------------+
//| Analyze Timeframe with Validation                                |
//+------------------------------------------------------------------+
void AnalyzeTimeframe(ENUM_TIMEFRAMES timeframe, string label)
{
    static datetime lastBarM1 = 0;
    static datetime lastBarM5 = 0;
    static datetime lastBarM15 = 0;
    
    datetime currentBar = iTime(_Symbol, timeframe, 0);
    bool isNewBar = false;
    
    if(timeframe == PERIOD_M1 && lastBarM1 != currentBar)
    {
        lastBarM1 = currentBar;
        isNewBar = true;
    }
    else if(timeframe == PERIOD_M5 && lastBarM5 != currentBar)
    {
        lastBarM5 = currentBar;
        isNewBar = true;
    }
    else if(timeframe == PERIOD_M15 && lastBarM15 != currentBar)
    {
        lastBarM15 = currentBar;
        isNewBar = true;
    }
    
    if(!isNewBar)
        return;
    
    // Get closed bar data
    double volume = (double)iVolume(_Symbol, timeframe, 1);
    double open = iOpen(_Symbol, timeframe, 1);
    double close = iClose(_Symbol, timeframe, 1);
    double high = iHigh(_Symbol, timeframe, 1);
    double low = iLow(_Symbol, timeframe, 1);
    
    // STEP 1: Volume Filter (STRICT)
    if(volume < MinVolumeThreshold)
    {
        return;  // Volume too low
    }
    
    // STEP 2: Average Volume Check
    double avgVolume = CalculateAverageVolume(timeframe);
    double volumeRatio = avgVolume > 0 ? volume / avgVolume : 0;
    
    if(volumeRatio < volumeThreshold)
    {
        return;  // Doesn't meet strict volume multiplier
    }
    
    // STEP 3: Candle Body Analysis
    double bodySize = MathAbs(close - open);
    double wickSize = (high - low) - bodySize;
    double bodyRatio = (high - low) > 0 ? bodySize / (high - low) : 0;
    
    // STEP 4: Signal Strength Calculation
    double signalStrength = (bodyRatio * 0.6) + (volumeRatio / 10.0 * 0.4);
    signalStrength = MathMin(signalStrength, 1.0);
    
    // STEP 5: STRICT Signal Validation
    if(signalStrength < MinSignalStrength)
    {
        return;  // Signal not strong enough
    }
    
    // STEP 6: Entry Logic
    if(close > open && bodyRatio >= 0.6)
    {
        // AGGRESSIVE BUYERS
        if(CanPlaceTrade())
        {
            PlaceBuyOrder(timeframe, label, signalStrength);
        }
    }
    else if(close < open && bodyRatio >= 0.6)
    {
        // AGGRESSIVE SELLERS
        if(CanPlaceTrade())
        {
            PlaceSellOrder(timeframe, label, signalStrength);
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate Average Volume                                         |
//+------------------------------------------------------------------+
double CalculateAverageVolume(ENUM_TIMEFRAMES timeframe)
{
    double sumVolume = 0;
    int count = 0;
    
    for(int i = 2; i < LookbackBars + 2; i++)
    {
        if(i < Bars(_Symbol, timeframe))
        {
            sumVolume += (double)iVolume(_Symbol, timeframe, i);
            count++;
        }
    }
    
    return count > 0 ? sumVolume / count : 1.0;
}

//+------------------------------------------------------------------+
//| Check if Can Place Trade                                         |
//+------------------------------------------------------------------+
bool CanPlaceTrade()
{
    // Check cooldown
    if((GetTickCount() - lastOrderTime) < 1000)
        return false;
    
    // Check max positions open
    int openPos = CountOpenPositions();
    if(openPos > 0)
        return false;  // One position at a time for safety
    
    return true;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size Based on Risk Management                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPoints)
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * (MaxRiskPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double pointValue_Local = tickValue / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    double calculatedLot = riskAmount / (stopLossPoints * pointValue_Local);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    calculatedLot = MathMax(minLot, MathMin(calculatedLot, maxLot));
    
    return NormalizeDouble(calculatedLot, 2);
}

//+------------------------------------------------------------------+
//| Place Buy Order                                                  |
//+------------------------------------------------------------------+
void PlaceBuyOrder(ENUM_TIMEFRAMES timeframe, string label, double strength)
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    double adaptedSL = StopLoss * slMultiplier;
    double adaptedTP = TakeProfit * tpMultiplier;
    double adaptedLot = CalculateLotSize(adaptedSL);
    
    double stopLoss = ask - (adaptedSL * point * pointValue);
    double takeProfit = ask + (adaptedTP * point * pointValue);
    
    // Validate
    if(takeProfit <= ask || stopLoss >= ask)
        return;
    
    string comment = "BUY-" + label + "-Str:" + DoubleToString(strength, 2);
    
    if(trade.Buy(adaptedLot, _Symbol, ask, stopLoss, takeProfit, comment))
    {
        lastPositionTicket = trade.ResultOrder();
        lastOrderTime = GetTickCount();
        lastSignalType = "BUY";
        lastSignalTime = TimeCurrent();
        tradesTodayCount++;
        
        Print("[BUY] Entry: ", ask, " | SL: ", stopLoss, " | TP: ", takeProfit, 
              " | Lot: ", adaptedLot, " | Strength: ", DoubleToString(strength, 2));
    }
    else
    {
        Print("[BUY FAILED] Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Place Sell Order                                                 |
//+------------------------------------------------------------------+
void PlaceSellOrder(ENUM_TIMEFRAMES timeframe, string label, double strength)
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    double adaptedSL = StopLoss * slMultiplier;
    double adaptedTP = TakeProfit * tpMultiplier;
    double adaptedLot = CalculateLotSize(adaptedSL);
    
    double stopLoss = bid + (adaptedSL * point * pointValue);
    double takeProfit = bid - (adaptedTP * point * pointValue);
    
    // Validate
    if(takeProfit >= bid || stopLoss <= bid)
        return;
    
    string comment = "SELL-" + label + "-Str:" + DoubleToString(strength, 2);
    
    if(trade.Sell(adaptedLot, _Symbol, bid, stopLoss, takeProfit, comment))
    {
        lastPositionTicket = trade.ResultOrder();
        lastOrderTime = GetTickCount();
        lastSignalType = "SELL";
        lastSignalTime = TimeCurrent();
        tradesTodayCount++;
        
        Print("[SELL] Entry: ", bid, " | SL: ", stopLoss, " | TP: ", takeProfit, 
              " | Lot: ", adaptedLot, " | Strength: ", DoubleToString(strength, 2));
    }
    else
    {
        Print("[SELL FAILED] Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Manage Positions with Trailing Stop                              |
//+------------------------------------------------------------------+
void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
                continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                continue;
            
            double profit = PositionGetDouble(POSITION_PROFIT);
            double commission = PositionGetDouble(POSITION_COMMISSION);
            double netProfit = profit + commission;
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
            double volume = PositionGetDouble(POSITION_VOLUME);
            double stopLoss = PositionGetDouble(POSITION_TP);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            // Track daily loss
            if(netProfit < 0)
            {
                dailyLoss += MathAbs(netProfit);
            }
            
            // Apply Trailing Stop
            if(UseTrailingStop && netProfit > (TrailingStopPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * pointValue * 20))
            {
                double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
                double newSL = 0;
                
                if(type == POSITION_TYPE_BUY)
                {
                    newSL = currentPrice - (TrailingStopPoints * point * pointValue);
                    if(newSL > stopLoss)
                    {
                        if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP)))
                        {
                            Print("[TRAILING STOP] Buy position SL updated to: ", newSL);
                        }
                    }
                }
                else if(type == POSITION_TYPE_SELL)
                {
                    newSL = currentPrice + (TrailingStopPoints * point * pointValue);
                    if(newSL < stopLoss)
                    {
                        if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP)))
                        {
                            Print("[TRAILING STOP] Sell position SL updated to: ", newSL);
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Count Open Positions                                             |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
               PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                count++;
            }
        }
    }
    
    return count;
}

//+------------------------------------------------------------------+
//| Reset Daily Counters                                             |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
    lastTradeDatetime = TimeCurrent();
    tradesTodayCount = 0;
    dailyLoss = 0.0;
    Print("[DAILY RESET] Counters reset at ", TimeToString(lastTradeDatetime));
}

//+------------------------------------------------------------------+
//| Detect Currency Type                                             |
//+------------------------------------------------------------------+
void DetectCurrencyType()
{
    string symbol = _Symbol;
    string base = StringSubstr(symbol, 0, 3);
    string quote = StringSubstr(symbol, 3, 3);
    
    bool isMajor = (base == "EUR" || base == "GBP" || base == "JPY" || base == "CHF" || 
                    base == "AUD" || base == "CAD" || base == "NZD") ||
                   (quote == "EUR" || quote == "GBP" || quote == "JPY" || quote == "CHF" || 
                    quote == "AUD" || quote == "CAD" || quote == "NZD");
    
    bool isMinor = (base == "EUR" || base == "GBP" || base == "JPY" || base == "CHF" || 
                    base == "AUD" || base == "CAD" || base == "NZD") &&
                   (quote == "EUR" || quote == "GBP" || quote == "JPY" || quote == "CHF" || 
                    quote == "AUD" || quote == "CAD" || quote == "NZD");
    
    bool isCommodity = (base == "XAU" || base == "XAG" || base == "XPD" || base == "XPT" ||
                        quote == "XAU" || quote == "XAG" || quote == "XPD" || quote == "XPT");
    
    if(isMajor && !isMinor)
    {
        currencyType = "MAJOR";
        lotMultiplier = 1.0;
        tpMultiplier = 1.0;
        slMultiplier = 1.0;
        volumeThreshold = 2.0;
    }
    else if(isMinor)
    {
        currencyType = "MINOR";
        lotMultiplier = 0.8;
        tpMultiplier = 1.2;
        slMultiplier = 1.2;
        volumeThreshold = 2.3;
    }
    else if(isCommodity)
    {
        currencyType = "COMMODITY";
        lotMultiplier = 0.6;
        tpMultiplier = 1.4;
        slMultiplier = 1.4;
        volumeThreshold = 2.5;
    }
    else
    {
        currencyType = "EXOTIC";
        lotMultiplier = 0.4;
        tpMultiplier = 1.6;
        slMultiplier = 1.6;
        volumeThreshold = 3.0;
    }
}

//+------------------------------------------------------------------+
//| Adapt to Market Conditions                                       |
//+------------------------------------------------------------------+
void AdaptToMarketConditions()
{
    // Additional logic can be added
}

//+------------------------------------------------------------------+
//| Print Trade History                                              |
//+------------------------------------------------------------------+
void PrintTradeHistory()
{
    Print("===== TRADE HISTORY =====");
    for(int i = 0; i < historyIndex; i++)
    {
        Print(i + 1, ". ", TimeToString(tradeHistory[i].time), " | ", 
              tradeHistory[i].type, " | P/L: ", DoubleToString(tradeHistory[i].profit, 2), 
              " | Lot: ", DoubleToString(tradeHistory[i].lot, 2));
    }
    Print("=========================");
}

//+------------------------------------------------------------------+
//| Update Chart Comment                                             |
//+------------------------------------------------------------------+
void UpdateComment()
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double dailyLossPercent = (dailyLoss / accountBalance) * 100.0;
    int openPos = CountOpenPositions();
    
    string comment = "=== VOLUME FOOTPRINT EA v5.0 - RISK PROTECTED ===\n";
    comment += "Symbol: " + _Symbol + " | Currency: " + currencyType + "\n";
    comment += "TF: " + TimeframeToString(PrimaryTimeframe) + " / " + TimeframeToString(SecondaryTimeframe) + "\n";
    comment += "\n--- RISK MANAGEMENT ---\n";
    comment += "Open Positions: " + IntegerToString(openPos) + "\n";
    comment += "Trades Today: " + IntegerToString(tradesTodayCount) + "/" + IntegerToString(MaxPositionsPerDay) + "\n";
    comment += "Daily Loss: " + DoubleToString(dailyLossPercent, 2) + "% / " + DoubleToString(DailyLossLimit, 2) + "% LIMIT\n";
    
    if(dailyLoss >= (accountBalance * DailyLossLimit / 100.0))
    {
        comment += "⛔ DAILY LOSS LIMIT REACHED - EA PAUSED\n";
    }
    
    if(tradesTodayCount >= MaxPositionsPerDay)
    {
        comment += "⛔ MAX TRADES TODAY REACHED - EA PAUSED\n";
    }
    
    comment += "\n--- TRADE PARAMETERS ---\n";
    comment += "Min Signal Strength: " + DoubleToString(MinSignalStrength * 100, 1) + "%\n";
    comment += "Volume Multiplier: " + DoubleToString(volumeThreshold, 2) + "x\n";
    comment += "Risk per Trade: " + DoubleToString(MaxRiskPercent, 2) + "%\n";
    comment += "Trailing Stop: " + (UseTrailingStop ? "ENABLED" : "DISABLED") + "\n";
    comment += "Last Signal: " + lastSignalType + " @ " + TimeToString(lastSignalTime) + "\n";
    comment += "==================================================\n";
    
    Comment(comment);
}

//+------------------------------------------------------------------+
//| Convert Timeframe to String                                      |
//+------------------------------------------------------------------+
string TimeframeToString(ENUM_TIMEFRAMES timeframe)
{
    switch(timeframe)
    {
        case PERIOD_M1:  return "M1";
        case PERIOD_M5:  return "M5";
        case PERIOD_M15: return "M15";
        default:         return "UNKNOWN";
    }
}

//+------------------------------------------------------------------+
