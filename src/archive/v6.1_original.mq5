//+------------------------------------------------------------------+
//|                                                 PairAB_CoolDown.mq5 |
//|                                     冷却期版 - 平仓后延时开仓     |
//|                                     增强版：智能平仓（先盈后亏） |
//|                                     新Z-Score算法：ln(P/SMA)差值  |
//+------------------------------------------------------------------+
#property copyright "配对交易冷却期版 - 新Z-Score算法"
#property version   "6.1"
#property description "配对交易EA，基于新Z-Score算法：ln(P/SMA)差值"
#property description "平仓后等待冷却期，避免频繁交易"
#property strict

//+------------------------------------------------------------------+
//| 输入参数（外部参数，可在MT5策略测试和运行面板中调节）            |
//+------------------------------------------------------------------+

//=== 基础交易品种 ===
input string   InpSymbol1 = "USTEC";          // 品种1（例如：纳指）
input string   InpSymbol2 = "US2000";         // 品种2（例如：罗素2000）
input ENUM_TIMEFRAMES InpTimeFrame = PERIOD_M15; // 分析时间周期

//=== 交易模式 ===
enum ENUM_TRADE_MODE
{
   MODE_BOTH = 0,     // 同时开仓品种1和品种2
   MODE_ONLY_S1 = 1,  // 只开仓品种1
   MODE_ONLY_S2 = 2   // 只开仓品种2
};
input ENUM_TRADE_MODE InpTradeMode = MODE_BOTH; // 交易模式

//=== 核心策略参数 ===
input int     InpLookBack = 20;                // Z-Score回看周期（建议20-30）
input double  InpZScoreOpen = 2.0;             // 开仓Z-Score阈值
input double  InpZScoreClose = 0.0;            // 平仓Z-Score阈值

//=== 资金与风险管理 ===
input double  InpLots = 0.1;                   // 基准手数（品种1）
input int     InpMagicNumber = 20260217;       // EA魔术号（用于识别订单）

//=== 手数配比参数 ===
input double  InpSymbol1LotSize = 1.0;         // 品种1每手单位数（指数CFD通常为1）
input double  InpSymbol2LotSize = 1.0;         // 品种2每手单位数（指数CFD通常为1）

//=== 冷却期参数 ===
input double  InpCoolDownMinutes = 60.0;       // 平仓后冷却期（分钟）

//=== 时间控制 ===
input int     InpEarliestHour = 1;             // 允许开仓的最早小时（GMT）
input int     InpLatestHour = 22;              // 允许开仓的最晚小时（GMT）
input int     InpCloseAtHour = 23;             // 日内清仓小时（GMT，仅总浮盈为正时执行）

//=== 订单执行参数 ===
input int     InpSlippage = 20;                // 滑点容忍度（点数）
input int     InpMaxRetries = 3;               // 平仓最大重试次数
input int     InpRetryDelay = 200;             // 平仓重试延迟（毫秒）

//=== 平仓增强选项 ===
input bool    InpEnableSmartClose = true;      // 启用智能平仓
input bool    InpCloseProfitFirst = true;      // true:先平盈利仓 false:先平亏损仓

//=== 日志控制 ===
input bool    InpDebugPrint = true;            // 启用调试日志输出

//+------------------------------------------------------------------+
//| 内部变量（由输入参数赋值）                                        |
//+------------------------------------------------------------------+
string   Symbol1;
string   Symbol2;
ENUM_TIMEFRAMES TimeFrame;
int      TradeMode;
int      LookBack_Period;
double   ZScore_Open;
double   ZScore_Close;
double   Lots;
int      Magic_Number;
double   Symbol1LotSize;
double   Symbol2LotSize;
double   CoolDownMinutes;
int      EarliestOpenHour;
int      LatestOpenHour;
int      CloseAtHour;
int      Slippage;
int      MaxCloseRetries;
int      CloseRetryDelay;
bool     EnableSmartClose;
bool     CloseProfitFirst;
bool     DebugPrint;

//=== 全局变量 ===
double price1, price2;
double logSpread;
double meanValue, stdValue, zscore;

double diffHistory[];
int histCount = 0;
datetime lastBarTime = 0;

datetime lastCloseTime = 0;
bool inCoolDown = false;

datetime lastTimeCheckLog = 0;

//+------------------------------------------------------------------+
//| 持仓信息结构体                                                   |
//+------------------------------------------------------------------+
struct PositionInfo
{
    ulong       ticket;
    string      symbol;
    ENUM_POSITION_TYPE type;
    double      volume;
    double      profit;
    double      openPrice;
    double      currentPrice;
    double      swap;
    double      commission;
    datetime    openTime;
    bool        isValid;
};

//+------------------------------------------------------------------+
//| 初始化函数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
    //=== 将输入参数赋值给内部变量 ===
    Symbol1 = InpSymbol1;
    Symbol2 = InpSymbol2;
    TimeFrame = InpTimeFrame;
    TradeMode = (int)InpTradeMode;
    LookBack_Period = InpLookBack;
    ZScore_Open = InpZScoreOpen;
    ZScore_Close = InpZScoreClose;
    Lots = InpLots;
    Magic_Number = InpMagicNumber;
    Symbol1LotSize = InpSymbol1LotSize;
    Symbol2LotSize = InpSymbol2LotSize;
    CoolDownMinutes = InpCoolDownMinutes;
    EarliestOpenHour = InpEarliestHour;
    LatestOpenHour = InpLatestHour;
    CloseAtHour = InpCloseAtHour;
    Slippage = InpSlippage;
    MaxCloseRetries = InpMaxRetries;
    CloseRetryDelay = InpRetryDelay;
    EnableSmartClose = InpEnableSmartClose;
    CloseProfitFirst = InpCloseProfitFirst;
    DebugPrint = InpDebugPrint;
    
    // 初始化动态数组
    ArrayResize(diffHistory, 0);
    histCount = 0;
    
    string timeFrameStr;
    switch(TimeFrame)
    {
        case PERIOD_M1: timeFrameStr = "1分钟"; break;
        case PERIOD_M5: timeFrameStr = "5分钟"; break;
        case PERIOD_M15: timeFrameStr = "15分钟"; break;
        case PERIOD_M30: timeFrameStr = "30分钟"; break;
        case PERIOD_H1: timeFrameStr = "1小时"; break;
        case PERIOD_H4: timeFrameStr = "4小时"; break;
        case PERIOD_D1: timeFrameStr = "日线"; break;
        case PERIOD_W1: timeFrameStr = "周线"; break;
        case PERIOD_MN1: timeFrameStr = "月线"; break;
        default: timeFrameStr = "自定义";
    }
    
    Print("=== 配对交易冷却期版（新Z-Score算法） ===");
    Print("策略: 价差 = ln(品种1/SMA1) - ln(品种2/SMA2)");
    Print("品种1: ", Symbol1);
    Print("品种2: ", Symbol2);
    Print("分析时间周期: ", timeFrameStr);
    Print("回看周期: ", LookBack_Period, "根K线");
    Print("开仓Z-Score阈值: ", ZScore_Open, "σ");
    Print("平仓Z-Score阈值: ", ZScore_Close, "σ");
    Print("基准手数: ", Lots);
    Print("冷却期: ", CoolDownMinutes, "分钟");
    Print("开仓时间(GMT): ", EarliestOpenHour, ":00 - ", LatestOpenHour, ":00");
    Print("日内清仓时间(GMT): ", CloseAtHour, ":00");
    Print("滑点容忍度: ", Slippage, " 点");
    Print("智能平仓: ", EnableSmartClose ? "启用" : "禁用");
    Print("平仓顺序: ", CloseProfitFirst ? "先平盈利仓" : "先平亏损仓");
    Print("交易模式: ", TradeMode, " (0=同时, 1=只品种1, 2=只品种2)");
    Print("调试日志: ", DebugPrint ? "开启" : "关闭");
    Print("==================================");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 主处理函数                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!GetPrices())
        return;
    
    UpdateHistory();
    
    if(histCount >= LookBack_Period)
    {
        CalculateZScore();
        UpdateCoolDownStatus();
        
        bool hasPairPosition = false;
        if(TradeMode == 0)
        {
            int positions1 = CountPositionsForSymbol(Symbol1);
            int positions2 = CountPositionsForSymbol(Symbol2);
            hasPairPosition = (positions1 > 0 && positions2 > 0);
        }
        else if(TradeMode == 1)
        {
            int positions1 = CountPositionsForSymbol(Symbol1);
            hasPairPosition = (positions1 > 0);
        }
        else if(TradeMode == 2)
        {
            int positions2 = CountPositionsForSymbol(Symbol2);
            hasPairPosition = (positions2 > 0);
        }
        
        if(!hasPairPosition)
        {
            if(!inCoolDown)
            {
                CheckOpenConditions();
            }
        }
        else
        {
            CheckCloseConditions();
        }
    }
    
    // 检查日内清仓
    bool hasAnyEAPosition = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic == Magic_Number)
            {
                hasAnyEAPosition = true;
                break;
            }
        }
    }
    if(hasAnyEAPosition)
    {
        CheckAndCloseAtEndOfDay();
    }
    
    DisplayInfo();
}

//+------------------------------------------------------------------+
//| 获取价格数据 - 新算法                                            |
//| 价差 = ln(品种1/SMA1) - ln(品种2/SMA2)                          |
//+------------------------------------------------------------------+
bool GetPrices()
{
    if(iBars(Symbol1, TimeFrame) < LookBack_Period + 1)
    {
        static bool symbol1WarningPrinted = false;
        if(!symbol1WarningPrinted)
        {
            Print("⚠️ 品种1数据不足，需要至少 ", LookBack_Period + 1, " 根K线");
            symbol1WarningPrinted = true;
        }
        return false;
    }
    if(iBars(Symbol2, TimeFrame) < LookBack_Period + 1)
    {
        static bool symbol2WarningPrinted = false;
        if(!symbol2WarningPrinted)
        {
            Print("⚠️ 品种2数据不足，需要至少 ", LookBack_Period + 1, " 根K线");
            symbol2WarningPrinted = true;
        }
        return false;
    }
    
    double close1[];
    double close2[];
    ArraySetAsSeries(close1, true);
    ArraySetAsSeries(close2, true);
    
    if(CopyClose(Symbol1, TimeFrame, 0, LookBack_Period + 1, close1) < LookBack_Period + 1) return false;
    if(CopyClose(Symbol2, TimeFrame, 0, LookBack_Period + 1, close2) < LookBack_Period + 1) return false;
    
    // 计算SMA
    double sum1 = 0, sum2 = 0;
    for(int i = 1; i <= LookBack_Period; i++)
    {
        sum1 += close1[i];
        sum2 += close2[i];
    }
    double sma1 = sum1 / LookBack_Period;
    double sma2 = sum2 / LookBack_Period;
    
    double currentPrice1 = close1[0];
    double currentPrice2 = close2[0];
    
    if(currentPrice1 <= 0 || sma1 <= 0 || currentPrice2 <= 0 || sma2 <= 0)
        return false;
    
    double ret1 = MathLog(currentPrice1 / sma1);
    double ret2 = MathLog(currentPrice2 / sma2);
    
    logSpread = ret1 - ret2;
    price1 = currentPrice1;
    price2 = currentPrice2;
    
    return true;
}

//+------------------------------------------------------------------+
//| 更新历史数据                                                     |
//+------------------------------------------------------------------+
void UpdateHistory()
{
    datetime currentBarTime = iTime(Symbol1, TimeFrame, 0);
    if(currentBarTime != lastBarTime && currentBarTime > 0)
    {
        int size = ArraySize(diffHistory);
        ArrayResize(diffHistory, size + 1);
        diffHistory[size] = logSpread;
        histCount = size + 1;
        lastBarTime = currentBarTime;
    }
}

//+------------------------------------------------------------------+
//| 计算Z-Score                                                      |
//+------------------------------------------------------------------+
void CalculateZScore()
{
    int startIndex = histCount - LookBack_Period;
    if(startIndex < 0) 
    {
        meanValue = 0; stdValue = 0; zscore = 0;
        return;
    }
    
    double sum = 0;
    for(int i = 0; i < LookBack_Period; i++)
        sum += diffHistory[startIndex + i];
    meanValue = sum / LookBack_Period;
    
    double variance = 0;
    for(int i = 0; i < LookBack_Period; i++)
    {
        double diff = diffHistory[startIndex + i] - meanValue;
        variance += diff * diff;
    }
    stdValue = MathSqrt(variance / LookBack_Period);
    
    if(stdValue > 0)
        zscore = (logSpread - meanValue) / stdValue;
    else
        zscore = 0;
    
    if(DebugPrint && lastBarTime != 0)
    {
        static datetime lastDebugPrint = 0;
        if(lastBarTime != lastDebugPrint && lastBarTime > 0)
        {
            Print("=== Z-Score ===");
            Print("价差: ", DoubleToString(logSpread, 6), " Z: ", DoubleToString(zscore, 2));
            Print("均值: ", DoubleToString(meanValue, 6), " 标准差: ", DoubleToString(stdValue, 6));
            lastDebugPrint = lastBarTime;
        }
    }
}

//+------------------------------------------------------------------+
//| 检查开仓条件                                                     |
//+------------------------------------------------------------------+
void CheckOpenConditions()
{
    if(!IsTradeTimeAllowed())
    {
        if(TimeCurrent() - lastTimeCheckLog >= 3600)
        {
            if(DebugPrint)
                Print("当前时间(GMT) ", TimeToString(TimeGMT(), TIME_MINUTES), " 不在开仓时间内");
            lastTimeCheckLog = TimeCurrent();
        }
        return;
    }
    
    if(zscore >= ZScore_Open && stdValue > 0)
    {
        Print("========================================");
        Print("🎯 开仓条件满足! Z-Score: ", DoubleToString(zscore, 2), " >= ", ZScore_Open);
        
        if(inCoolDown)
        {
            double minutesLeft = CoolDownMinutes - ((TimeCurrent() - lastCloseTime) / 60.0);
            Print("⏳ 冷却期中，剩余", DoubleToString(minutesLeft, 1), "分钟，跳过开仓");
            Print("========================================");
            return;
        }
        
        bool symbol1IsStronger = (logSpread > 0);
        
        if(TradeMode == 0)
        {
            if(symbol1IsStronger)
            {
                Print("交易方向: 卖品种1 + 买品种2");
                double symbol2Lots = CalculateSymbol2Lots(Lots);
                Print("品种1手数: ", Lots, " 品种2手数: ", symbol2Lots);
                
                bool success1 = OpenPosition(Symbol1, ORDER_TYPE_SELL, Lots);
                if(success1)
                {
                    Sleep(50);
                    bool success2 = OpenPosition(Symbol2, ORDER_TYPE_BUY, symbol2Lots);
                    if(success2)
                        Print("✅ 配对开仓成功！");
                    else
                    {
                        Print("❌ 品种2开仓失败，关闭品种1仓位");
                        CloseAllPositionsForSymbol(Symbol1);
                    }
                }
            }
            else
            {
                Print("交易方向: 买品种1 + 卖品种2");
                double symbol2Lots = CalculateSymbol2Lots(Lots);
                Print("品种1手数: ", Lots, " 品种2手数: ", symbol2Lots);
                
                bool success1 = OpenPosition(Symbol1, ORDER_TYPE_BUY, Lots);
                if(success1)
                {
                    Sleep(50);
                    bool success2 = OpenPosition(Symbol2, ORDER_TYPE_SELL, symbol2Lots);
                    if(success2)
                        Print("✅ 配对开仓成功！");
                    else
                    {
                        Print("❌ 品种2开仓失败，关闭品种1仓位");
                        CloseAllPositionsForSymbol(Symbol1);
                    }
                }
            }
        }
        else if(TradeMode == 1)
        {
            if(symbol1IsStronger)
            {
                Print("交易方向: 只开品种1（卖）");
                OpenPosition(Symbol1, ORDER_TYPE_SELL, Lots);
            }
            else
            {
                Print("交易方向: 只开品种1（买）");
                OpenPosition(Symbol1, ORDER_TYPE_BUY, Lots);
            }
        }
        else if(TradeMode == 2)
        {
            if(symbol1IsStronger)
            {
                Print("交易方向: 只开品种2（买）");
                OpenPosition(Symbol2, ORDER_TYPE_BUY, Lots);
            }
            else
            {
                Print("交易方向: 只开品种2（卖）");
                OpenPosition(Symbol2, ORDER_TYPE_SELL, Lots);
            }
        }
        Print("========================================");
    }
}

//+------------------------------------------------------------------+
//| 检查平仓条件                                                     |
//+------------------------------------------------------------------+
void CheckCloseConditions()
{
    if(TradeMode == 0)
    {
        if(zscore <= ZScore_Close && stdValue > 0)
        {
            Print("========================================");
            Print("📉 平仓条件满足! Z-Score: ", DoubleToString(zscore, 2), " <= ", ZScore_Close);
            if(EnableSmartClose)
            {
                if(CloseProfitFirst)
                    CloseAllPairPositionsSmartProfitFirst();
                else
                    CloseAllPairPositionsSmartLossFirst();
            }
            else
            {
                CloseAllPairPositions();
            }
            Print("========================================");
        }
    }
    else if(TradeMode == 1)
    {
        if(zscore <= ZScore_Close && stdValue > 0)
        {
            Print("📉 平仓品种1，Z-Score: ", DoubleToString(zscore, 2));
            CloseAllPositionsForSymbol(Symbol1);
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
        }
    }
    else if(TradeMode == 2)
    {
        if(zscore <= ZScore_Close && stdValue > 0)
        {
            Print("📉 平仓品种2，Z-Score: ", DoubleToString(zscore, 2));
            CloseAllPositionsForSymbol(Symbol2);
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
        }
    }
}

//+------------------------------------------------------------------+
//| 辅助函数（保持不变）                                              |
//+------------------------------------------------------------------+
bool IsTradeTimeAllowed()
{
    datetime currentGMT = TimeGMT();
    MqlDateTime dt;
    TimeToStruct(currentGMT, dt);
    int currentHour = dt.hour;
    return (currentHour >= EarliestOpenHour && currentHour <= LatestOpenHour);
}

void UpdateCoolDownStatus()
{
    if(lastCloseTime == 0) { inCoolDown = false; return; }
    double minutesSinceClose = (TimeCurrent() - lastCloseTime) / 60.0;
    inCoolDown = (minutesSinceClose < CoolDownMinutes);
}

double CalculateSymbol2Lots(double symbol1Lots)
{
    double symbol1Notional = symbol1Lots * Symbol1LotSize * price1;
    double symbol2NotionalPerLot = Symbol2LotSize * price2;
    if(symbol2NotionalPerLot <= 0) return 0;
    double rawLots = symbol1Notional / symbol2NotionalPerLot;
    double normalizedLots = NormalizeDouble(rawLots, 2);
    double minLot = SymbolInfoDouble(Symbol2, SYMBOL_VOLUME_MIN);
    if(normalizedLots < minLot) normalizedLots = minLot;
    return normalizedLots;
}

bool OpenPosition(string symbol, ENUM_ORDER_TYPE orderType, double volume)
{
    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    
    if(volume < minLot || volume > maxLot)
    {
        Print("❌ 手数 ", volume, " 超出范围 [", minLot, ", ", maxLot, "]");
        return false;
    }
    
    double remainder = MathAbs(volume - MathRound(volume / lotStep) * lotStep);
    if(remainder > 0.00001)
    {
        Print("❌ 手数 ", volume, " 不是步长 ", lotStep, " 的倍数");
        return false;
    }
    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = symbol;
    request.volume = volume;
    request.type = orderType;
    request.type_filling = ORDER_FILLING_IOC;
    request.magic = Magic_Number;
    request.comment = "PairTrade";
    request.deviation = Slippage;
    
    if(orderType == ORDER_TYPE_BUY)
        request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    else
        request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
    
    bool success = OrderSend(request, result);
    
    if(success && result.retcode == TRADE_RETCODE_DONE)
    {
        Print("✅ ", symbol, " 开仓成功，单号: ", result.order);
        return true;
    }
    else
    {
        Print("❌ ", symbol, " 开仓失败: ", result.retcode, " - ", GetRetcodeDescription(result.retcode));
        return false;
    }
}

void CheckAndCloseAtEndOfDay()
{
   datetime currentGMT = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(currentGMT, dt);
   int currentHour = dt.hour;

   if(currentHour == CloseAtHour)
   {
      double totalProfit = 0.0;
      int totalPositions = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic == Magic_Number)
            {
               totalProfit += PositionGetDouble(POSITION_PROFIT);
               totalPositions++;
            }
         }
      }

      if(totalPositions > 0 && totalProfit > 0)
      {
         Print("⏰ 日内清仓 (GMT ", CloseAtHour, ":00) 总浮盈: ", DoubleToString(totalProfit, 2), " 为正，执行清仓");
         
         if(TradeMode == 0)
         {
            int positions1 = CountPositionsForSymbol(Symbol1);
            int positions2 = CountPositionsForSymbol(Symbol2);
            
            if(positions1 > 0 && positions2 > 0)
            {
                if(EnableSmartClose)
                {
                   if(CloseProfitFirst)
                      CloseAllPairPositionsSmartProfitFirst();
                   else
                      CloseAllPairPositionsSmartLossFirst();
                }
                else
                {
                   CloseAllPairPositions();
                }
            }
            else
            {
                if(positions1 > 0) CloseAllPositionsForSymbol(Symbol1);
                if(positions2 > 0) CloseAllPositionsForSymbol(Symbol2);
                lastCloseTime = TimeCurrent();
                inCoolDown = true;
            }
         }
         else if(TradeMode == 1)
         {
            CloseAllPositionsForSymbol(Symbol1);
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
         }
         else if(TradeMode == 2)
         {
            CloseAllPositionsForSymbol(Symbol2);
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
         }
      }
   }
}

void CloseAllPairPositions()
{
    Print("正在关闭配对仓位...");
    CloseAllPositionsForSymbol(Symbol2);
    Sleep(50);
    CloseAllPositionsForSymbol(Symbol1);
    lastCloseTime = TimeCurrent();
    inCoolDown = true;
    Print("✅ 平仓完成，开始", CoolDownMinutes, "分钟冷却期");
}

void CloseAllPairPositionsSmartProfitFirst()
{
    Print("📊 智能平仓（先盈后亏）");
    PositionInfo pos1 = GetPositionInfo(Symbol1);
    PositionInfo pos2 = GetPositionInfo(Symbol2);
    
    if(!pos1.isValid || !pos2.isValid)
    {
        CloseAllPairPositions();
        return;
    }
    
    bool closeFirst = (pos1.profit > pos2.profit);
    string firstSymbol = closeFirst ? Symbol1 : Symbol2;
    string secondSymbol = closeFirst ? Symbol2 : Symbol1;
    
    bool firstClosed = false;
    for(int retry = 0; retry < MaxCloseRetries && !firstClosed; retry++)
    {
        if(retry > 0) Sleep(CloseRetryDelay);
        if(closeFirst)
            firstClosed = CloseSinglePosition(pos1.ticket, pos1.symbol, pos1.type, pos1.volume);
        else
            firstClosed = CloseSinglePosition(pos2.ticket, pos2.symbol, pos2.type, pos2.volume);
    }
    
    Sleep(CloseRetryDelay);
    
    bool secondClosed = false;
    for(int retry = 0; retry < MaxCloseRetries && !secondClosed; retry++)
    {
        if(retry > 0) Sleep(CloseRetryDelay);
        if(closeFirst)
            secondClosed = CloseSinglePosition(pos2.ticket, pos2.symbol, pos2.type, pos2.volume);
        else
            secondClosed = CloseSinglePosition(pos1.ticket, pos1.symbol, pos1.type, pos1.volume);
    }
    
    Sleep(100);
    int remaining1 = CountPositionsForSymbol(Symbol1);
    int remaining2 = CountPositionsForSymbol(Symbol2);
    
    if(remaining1 == 0 && remaining2 == 0)
    {
        lastCloseTime = TimeCurrent();
        inCoolDown = true;
        Print("✅ 平仓完成");
    }
    else
    {
        if(remaining1 > 0) CloseAllPositionsForSymbol(Symbol1);
        if(remaining2 > 0) CloseAllPositionsForSymbol(Symbol2);
        if(CountPositionsForSymbol(Symbol1) == 0 && CountPositionsForSymbol(Symbol2) == 0)
        {
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
        }
    }
}

void CloseAllPairPositionsSmartLossFirst()
{
    Print("📊 智能平仓（先亏后盈）");
    PositionInfo pos1 = GetPositionInfo(Symbol1);
    PositionInfo pos2 = GetPositionInfo(Symbol2);
    
    if(!pos1.isValid || !pos2.isValid)
    {
        CloseAllPairPositions();
        return;
    }
    
    bool closeFirst = (pos1.profit < pos2.profit);
    string firstSymbol = closeFirst ? Symbol1 : Symbol2;
    string secondSymbol = closeFirst ? Symbol2 : Symbol1;
    
    bool firstClosed = false;
    for(int retry = 0; retry < MaxCloseRetries && !firstClosed; retry++)
    {
        if(retry > 0) Sleep(CloseRetryDelay);
        if(closeFirst)
            firstClosed = CloseSinglePosition(pos1.ticket, pos1.symbol, pos1.type, pos1.volume);
        else
            firstClosed = CloseSinglePosition(pos2.ticket, pos2.symbol, pos2.type, pos2.volume);
    }
    
    Sleep(CloseRetryDelay);
    
    bool secondClosed = false;
    for(int retry = 0; retry < MaxCloseRetries && !secondClosed; retry++)
    {
        if(retry > 0) Sleep(CloseRetryDelay);
        if(closeFirst)
            secondClosed = CloseSinglePosition(pos2.ticket, pos2.symbol, pos2.type, pos2.volume);
        else
            secondClosed = CloseSinglePosition(pos1.ticket, pos1.symbol, pos1.type, pos1.volume);
    }
    
    Sleep(100);
    int remaining1 = CountPositionsForSymbol(Symbol1);
    int remaining2 = CountPositionsForSymbol(Symbol2);
    
    if(remaining1 == 0 && remaining2 == 0)
    {
        lastCloseTime = TimeCurrent();
        inCoolDown = true;
        Print("✅ 平仓完成");
    }
    else
    {
        if(remaining1 > 0) CloseAllPositionsForSymbol(Symbol1);
        if(remaining2 > 0) CloseAllPositionsForSymbol(Symbol2);
        if(CountPositionsForSymbol(Symbol1) == 0 && CountPositionsForSymbol(Symbol2) == 0)
        {
            lastCloseTime = TimeCurrent();
            inCoolDown = true;
        }
    }
}

PositionInfo GetPositionInfo(string symbol)
{
    PositionInfo pos = {};
    pos.symbol = symbol;
    pos.isValid = false;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(posSymbol == symbol && magic == Magic_Number)
            {
                pos.ticket = ticket;
                pos.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                pos.volume = PositionGetDouble(POSITION_VOLUME);
                pos.profit = PositionGetDouble(POSITION_PROFIT);
                pos.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                pos.currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
                pos.swap = PositionGetDouble(POSITION_SWAP);
                pos.openTime = (datetime)PositionGetInteger(POSITION_TIME);
                pos.isValid = true;
                break;
            }
        }
    }
    return pos;
}

bool CloseSinglePosition(ulong ticket, string symbol, ENUM_POSITION_TYPE type, double volume)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = symbol;
    request.volume = volume;
    request.magic = Magic_Number;
    request.comment = "SmartClose";
    request.type_filling = ORDER_FILLING_IOC;
    request.deviation = Slippage;
    
    if(type == POSITION_TYPE_BUY)
    {
        request.type = ORDER_TYPE_SELL;
        request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
    }
    else
    {
        request.type = ORDER_TYPE_BUY;
        request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    }
    
    bool success = OrderSend(request, result);
    if(success && result.retcode == TRADE_RETCODE_DONE)
    {
        Print("✅ ", symbol, " 平仓成功");
        return true;
    }
    else
    {
        Print("❌ ", symbol, " 平仓失败: ", result.retcode);
        return false;
    }
}

void CloseAllPositionsForSymbol(string symbol)
{
    int closed = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(posSymbol == symbol && magic == Magic_Number)
            {
                ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                double volume = PositionGetDouble(POSITION_VOLUME);
                if(CloseSinglePosition(ticket, symbol, type, volume))
                    closed++;
                Sleep(50);
            }
        }
    }
    if(closed > 0) Print("📊 ", symbol, " 已平仓 ", closed, " 个仓位");
}

int CountPositionsForSymbol(string symbol)
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(posSymbol == symbol && magic == Magic_Number)
                count++;
        }
    }
    return count;
}

string GetRetcodeDescription(uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:          return "重报价";
        case TRADE_RETCODE_REJECT:           return "请求拒绝";
        case TRADE_RETCODE_CANCEL:           return "取消";
        case TRADE_RETCODE_PLACED:           return "挂单成功";
        case TRADE_RETCODE_DONE:             return "订单完成";
        case TRADE_RETCODE_DONE_PARTIAL:     return "部分成交";
        case TRADE_RETCODE_ERROR:            return "执行错误";
        case TRADE_RETCODE_TIMEOUT:          return "超时";
        case TRADE_RETCODE_INVALID:          return "无效参数";
        case TRADE_RETCODE_INVALID_VOLUME:   return "无效手数";
        case TRADE_RETCODE_INVALID_PRICE:    return "无效价格";
        case TRADE_RETCODE_INVALID_STOPS:    return "无效止损";
        case TRADE_RETCODE_TRADE_DISABLED:   return "交易禁用";
        case TRADE_RETCODE_MARKET_CLOSED:    return "市场关闭";
        case TRADE_RETCODE_NO_MONEY:         return "资金不足";
        case TRADE_RETCODE_PRICE_CHANGED:    return "价格变化";
        case TRADE_RETCODE_PRICE_OFF:        return "价格偏离";
        case TRADE_RETCODE_TOO_MANY_REQUESTS: return "请求过多";
        default:                             return "未知错误(" + IntegerToString(retcode) + ")";
    }
}

//+------------------------------------------------------------------+
//| 显示信息                                                         |
//+------------------------------------------------------------------+
void DisplayInfo()
{
    string timeFrameStr;
    switch(TimeFrame)
    {
        case PERIOD_M1: timeFrameStr = "M1"; break;
        case PERIOD_M5: timeFrameStr = "M5"; break;
        case PERIOD_M15: timeFrameStr = "M15"; break;
        case PERIOD_M30: timeFrameStr = "M30"; break;
        case PERIOD_H1: timeFrameStr = "H1"; break;
        case PERIOD_H4: timeFrameStr = "H4"; break;
        case PERIOD_D1: timeFrameStr = "D1"; break;
        case PERIOD_W1: timeFrameStr = "W1"; break;
        case PERIOD_MN1: timeFrameStr = "MN1"; break;
        default: timeFrameStr = "自定义";
    }
    
    string info = "\n=== 新Z-Score配对交易 ===";
    info += "\n周期: " + timeFrameStr + " 回看: " + string(LookBack_Period);
    info += "\n价差: ln(S1/SMA1)-ln(S2/SMA2)";
    info += "\n开仓: " + DoubleToString(ZScore_Open, 1) + "σ  平仓: " + DoubleToString(ZScore_Close, 1) + "σ";
    info += "\n冷却: " + DoubleToString(CoolDownMinutes, 0) + "分钟  滑点: " + string(Slippage);
    info += "\n时间(GMT): " + string(EarliestOpenHour) + ":00-" + string(LatestOpenHour) + ":00";
    info += "\n--------------------------------";
    info += "\n" + Symbol1 + ": " + DoubleToString(price1, 2) + "  " + Symbol2 + ": " + DoubleToString(price2, 2);
    info += "\n价差: " + DoubleToString(logSpread, 6);
    
    if(histCount >= LookBack_Period)
    {
        info += "\n均值: " + DoubleToString(meanValue, 6) + " 标准差: " + DoubleToString(stdValue, 6);
        info += "\nZ-Score: " + DoubleToString(zscore, 2);
        info += "\n--------------------------------";
        
        int positions1 = CountPositionsForSymbol(Symbol1);
        int positions2 = CountPositionsForSymbol(Symbol2);
        info += "\n" + Symbol1 + "持仓: " + string(positions1) + "  " + Symbol2 + "持仓: " + string(positions2);
        
        if(positions1 > 0 || positions2 > 0)
        {
            double totalProfit = 0.0;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket > 0 && PositionSelectByTicket(ticket))
               {
                  long magic = PositionGetInteger(POSITION_MAGIC);
                  if(magic == Magic_Number)
                     totalProfit += PositionGetDouble(POSITION_PROFIT);
               }
            }
            info += "\n总浮盈: " + DoubleToString(totalProfit, 2);
        }
        
        if((TradeMode == 0 && positions1 == 0 && positions2 == 0) ||
           (TradeMode == 1 && positions1 == 0) ||
           (TradeMode == 2 && positions2 == 0))
        {
            if(inCoolDown && lastCloseTime > 0)
            {
                double minutesLeft = CoolDownMinutes - ((TimeCurrent() - lastCloseTime) / 60.0);
                info += "\n⏳ 冷却中 " + DoubleToString(minutesLeft, 1) + "分钟";
            }
            else if(zscore >= ZScore_Open)
            {
                info += IsTradeTimeAllowed() ? "\n🎯 满足开仓!" : "\n⏰ 满足但不在开仓时间";
            }
        }
        else
        {
            if(zscore <= ZScore_Close) info += "\n📉 满足平仓!";
        }
    }
    else
    {
        info += "\n数据收集中: " + string(histCount) + "/" + string(LookBack_Period);
    }
    info += "\n==================================";
    Comment(info);
}

//+------------------------------------------------------------------+
//| 去初始化函数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Comment("");
    Print("EA去初始化完成，原因: ", reason);
}
//+------------------------------------------------------------------+