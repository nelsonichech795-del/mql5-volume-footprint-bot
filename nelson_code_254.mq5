//+------------------------------------------------------------------+
//| Volume Footprint EA - M1 Automated Trading Bot v2.0              |
//| Detects aggressive sellers and buyers based on volume analysis   |
//+------------------------------------------------------------------+
#property copyright "Volume Footprint Bot"
#property link      "https://github.com/nelsonichech795-del/mql5-volume-footprint-bot"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double LotSize = 0.1;                      // Fixed lot size
input double TakeProfit = 50;                    // Take profit in pips
input double StopLoss = 30;                      // Stop loss in pips
input int MaxOpenPositions = 3;                  // Maximum open positions
input double VolumeMultiplier = 1.5;             // Volume spike multiplier
input int LookbackBars = 10;                     // Bars for average volume
input int MagicNumber = 12345;                   // Magic number
input int OrderCooldown = 2;                     // Seconds between orders
input double MinVolumeThreshold = 100;           // Minimum volume to consider

//--- Global variables
CTrade trade;
datetime lastOrderTime = 0;
int pointValue = 1;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Validate timeframe
    if(Period() != PERIOD_M1)
    {
        Alert("This EA works only on M1 timeframe!");
        return INIT_FAILED;
    }
    
    // Set point value for 5-digit brokers
    if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5)
        pointValue = 10;
    
    trade.SetExpertMagicNumber(MagicNumber);
    
    Print("=== Volume Footprint EA Started ===");
    Print("Symbol: ", _Symbol);
    Print("Lot Size: ", LotSize);
    Print("Take Profit: ", TakeProfit, " pips");
    Print("Stop Loss: ", StopLoss, " pips");
    Print("=====================================");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("Volume Footprint EA Stopped");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Only process on new M1 bar
    static datetime lastTime = 0;
    datetime currentTime = iTime(_Symbol, PERIOD_M1, 0);
    
    if(lastTime == currentTime)
        return;
    
    lastTime = currentTime;
    
    // Analyze volume footprint on the closed bar (bar 1)
    AnalyzeAndTrade();
    
    // Update chart comment
    UpdateComment();
}

//+------------------------------------------------------------------+
//| Analyze Volume and Place Trades                                  |
//+------------------------------------------------------------------+
void AnalyzeAndTrade()
{
    // Get current symbol info
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // Get the CLOSED bar (bar 1)
    double volume1 = (double)iVolume(_Symbol, PERIOD_M1, 1);
    double open1 = iOpen(_Symbol, PERIOD_M1, 1);
    double close1 = iClose(_Symbol, PERIOD_M1, 1);
    double high1 = iHigh(_Symbol, PERIOD_M1, 1);
    double low1 = iLow(_Symbol, PERIOD_M1, 1);
    
    // Check if volume is significant
    if(volume1 < MinVolumeThreshold)
        return;
    
    // Calculate average volume from previous bars
    double avgVolume = CalculateAverageVolume();
    double volumeRatio = volume1 / avgVolume;
    
    // Check cooldown
    if((TimeCurrent() - lastOrderTime) < OrderCooldown)
        return;
    
    // Check max positions
    if(CountOpenPositions() >= MaxOpenPositions)
        return;
    
    // AGGRESSIVE BUYERS - Strong bullish candle with high volume
    if(close1 > open1 && volumeRatio >= VolumeMultiplier)
    {
        double buyBodySize = close1 - open1;
        double buyWickSize = high1 - close1;
        
        // More body than wick = aggressive buying
        if(buyBodySize > buyWickSize * 0.5)
        {
            PlaceBuyOrder(ask, point);
            return;
        }
    }
    
    // AGGRESSIVE SELLERS - Strong bearish candle with high volume
    if(close1 < open1 && volumeRatio >= VolumeMultiplier)
    {
        double sellBodySize = open1 - close1;
        double sellWickSize = close1 - low1;
        
        // More body than wick = aggressive selling
        if(sellBodySize > sellWickSize * 0.5)
        {
            PlaceSellOrder(bid, point);
            return;
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate Average Volume                                         |
//+------------------------------------------------------------------+
double CalculateAverageVolume()
{
    double sumVolume = 0;
    int count = 0;
    
    for(int i = 2; i < LookbackBars + 2; i++)
    {
        if(i < Bars(_Symbol, PERIOD_M1))
        {
            sumVolume += (double)iVolume(_Symbol, PERIOD_M1, i);
            count++;
        }
    }
    
    if(count == 0)
        return 1.0;
    
    return sumVolume / count;
}

//+------------------------------------------------------------------+
//| Place Buy Order                                                  |
//+------------------------------------------------------------------+
void PlaceBuyOrder(double ask, double point)
{
    double stopLoss = ask - (StopLoss * point * pointValue);
    double takeProfit = ask + (TakeProfit * point * pointValue);
    
    // Validate TP and SL
    if(takeProfit <= ask || stopLoss >= ask)
        return;
    
    if(trade.Buy(LotSize, _Symbol, ask, stopLoss, takeProfit, "Aggressive Buyers"))
    {
        Print("[BUY] Executed at ", ask, " | SL: ", stopLoss, " | TP: ", takeProfit);
        lastOrderTime = TimeCurrent();
    }
    else
    {
        Print("[BUY] Failed - Error: ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| Place Sell Order                                                 |
//+------------------------------------------------------------------+
void PlaceSellOrder(double bid, double point)
{
    double stopLoss = bid + (StopLoss * point * pointValue);
    double takeProfit = bid - (TakeProfit * point * pointValue);
    
    // Validate TP and SL
    if(takeProfit >= bid || stopLoss <= bid)
        return;
    
    if(trade.Sell(LotSize, _Symbol, bid, stopLoss, takeProfit, "Aggressive Sellers"))
    {
        Print("[SELL] Executed at ", bid, " | SL: ", stopLoss, " | TP: ", takeProfit);
        lastOrderTime = TimeCurrent();
    }
    else
    {
        Print("[SELL] Failed - Error: ", trade.ResultRetcode());
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
//| Update Chart Comment                                             |
//+------------------------------------------------------------------+
void UpdateComment()
{
    string comment = "=== VOLUME FOOTPRINT EA ===\n";
    comment += "Symbol: " + _Symbol + "\n";
    comment += "Timeframe: M1\n";
    comment += "Open Positions: " + IntegerToString(CountOpenPositions()) + "/" + IntegerToString(MaxOpenPositions) + "\n";
    comment += "Lot Size: " + DoubleToString(LotSize, 2) + "\n";
    comment += "TP: " + IntegerToString(TakeProfit) + " pips | SL: " + IntegerToString(StopLoss) + " pips\n";
    comment += "Volume Multiplier: " + DoubleToString(VolumeMultiplier, 2) + "x\n";
    comment += "Last Order: " + TimeToString(lastOrderTime) + "\n";
    
    Comment(comment);
}

//+------------------------------------------------------------------+
