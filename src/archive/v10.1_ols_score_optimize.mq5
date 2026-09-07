//+------------------------------------------------------------------+
//|                    PairAB_BasketScaleIn_v10.1.mq5                |
//|                    配对交易 - Basket阶梯加仓版                   |
//|                    Z方向统一 + 回归后盈利平仓                    |
//|                    双Spread：SMA相对偏离 + OLS log残差          |
//+------------------------------------------------------------------+
#property copyright "配对交易Basket阶梯加仓版 - 双Spread优化版"
#property version   "10.1"
#property description "配对交易EA，基于Z-Score正负统一交易方向"
#property description "本轮固定OLS residual，仅优化M15/M30 + 首仓Z/加仓Z间距/线性手数增量，并输出综合Score"
#property strict

//+------------------------------------------------------------------+
//| 输入参数（外部参数，可在MT5策略测试和运行面板中调节）            |
//+------------------------------------------------------------------+

//=== 基础交易品种 ===
input string   InpSymbol1 = "NAS100";             // 品种1（例如：纳指）
input string   InpSymbol2 = "US2000";             // 品种2（例如：罗素2000）

//=== 本轮优化周期：只测试 M15 / M30 ===
enum ENUM_OPT_TIMEFRAME
{
   OPT_TF_M15 = 0,   // M15
   OPT_TF_M30 = 1    // M30
};
input ENUM_OPT_TIMEFRAME InpTimeFrame = OPT_TF_M15; // 优化范围固定为 0..1

//=== Spread模型：优化时可用 Start=0 Step=1 Stop=1 一次测试两种算法 ===
enum ENUM_SPREAD_MODEL
{
   SPREAD_SMA_RELATIVE = 0,      // 原模型：ln(S1/SMA1) - ln(S2/SMA2)
   SPREAD_OLS_LOG_RESIDUAL = 1   // 新模型：log(S1)=alpha+beta*log(S2)+epsilon，Spread=epsilon
};
input ENUM_SPREAD_MODEL InpSpreadModel = SPREAD_OLS_LOG_RESIDUAL; // 本轮优化固定OLS，不参与枚举
input int     InpRegressionLookBack = 60;       // OLS回归窗口；仅新Spread模型使用

//=== 交易模式 ===
enum ENUM_TRADE_MODE
{
   MODE_BOTH = 0,     // 同时开仓品种1和品种2
   MODE_ONLY_S1 = 1,  // 只开仓品种1
   MODE_ONLY_S2 = 2   // 只开仓品种2
};
input ENUM_TRADE_MODE InpTradeMode = MODE_BOTH; // 交易模式

//=== 核心策略参数 ===
input int     InpLookBack = 60;                // Z-Score回看周期（建议20-30）
input double  InpZScoreOpen = 2.0;             // 首仓阈值：|Z|达到该值开仓
input double  InpZScoreClose = 0.0;            // 回归阈值：正Basket Z<=该值；负Basket Z>=-该值

//=== 阶梯加仓参数 ===
input bool    InpEnableScaleIn = true;          // 是否启用连续偏离加仓
input double  InpAddZStep = 1.0;             // 每继续偏离多少Z加仓一次
input int     InpMaxAddCount = 7;               // 最多加仓次数（不含首仓）
input double  InpAddLotStep = 0.01;             // 线性加仓增量：LevelN = 基础手数 + N * 该增量
input int     InpMinAddIntervalSec = 60;        // 两次加仓最短间隔（秒）
input double  InpMaxAbsZ = 10.0;                 // |Z|达到/超过此值后禁止继续加仓（<=0禁用）
input double  InpMaxTotalBaseLots = 0.0;        // 基础腿最大总手数（0=禁用；BOTH/ONLY_S1看S1，ONLY_S2看S2）
input double  InpMaxMarginUsagePct = 0.0;       // 加仓前最大保证金占净值比例%（0=禁用）

//=== Basket盈利平仓 ===
input bool    InpRequireProfitClose = true;     // 正常平仓必须Basket净盈利
input double  InpMinBasketProfit = 1.0;         // 最低Basket净盈利（账户货币，建议覆盖滑点成本）
input bool    InpEndOfDayRequireReversion = true; // 日内清仓是否也必须先发生回归

//=== 资金与风险管理 ===
input double  InpLots = 0.01;                   // 基准手数（品种1/单腿模式基础手数）
input int     InpMagicNumber = 20260217;       // EA魔术号（用于识别订单）

//=== 手数配比参数 ===
input double  InpSymbol1LotSize = 1.0;         // 品种1每手单位数（指数CFD通常为1）
input double  InpSymbol2LotSize = 1.0;         // 品种2每手单位数（指数CFD通常为1）

//=== 冷却期参数 ===
input double  InpCoolDownMinutes = 60.0;       // 整个Basket平仓后冷却期（分钟）

//=== 时间控制 ===
input int     InpEarliestHour = 1;             // 允许首仓/加仓的最早小时（GMT）
input int     InpLatestHour = 22;              // 允许首仓/加仓的最晚小时（GMT）
input int     InpCloseAtHour = 23;             // 日内清仓小时（GMT）

//=== 订单执行参数 ===
input int     InpSlippage = 20;                // 滑点容忍度（点数）
input int     InpMaxRetries = 3;               // 平仓最大重试次数
input int     InpRetryDelay = 200;             // 平仓重试延迟（毫秒）

//=== 平仓增强选项 ===
input bool    InpEnableSmartClose = true;      // 启用智能平仓（按品种汇总盈亏决定先后）
input bool    InpCloseProfitFirst = true;      // true:先平汇总盈利更高的腿 false:先平汇总盈利更低的腿

//=== 优化统计 ===
input double  InpExtremeZThreshold = 3.0;      // 极端Z阈值；<=0时自动使用InpZScoreOpen
input bool    InpExportOptimizationCSV = true; // 兼容参数；v10.1完成优化时强制导出CSV
input string  InpOptimizationCsvName = "PairBasket_v10_1_OLS_OptimizationMetrics.csv"; // 输出到Common\\Files

//=== 日志控制 ===
input bool    InpDebugPrint = true;            // 启用调试日志输出

//+------------------------------------------------------------------+
//| 内部变量（由输入参数赋值）                                      |
//+------------------------------------------------------------------+
string   Symbol1;
string   Symbol2;
ENUM_TIMEFRAMES TimeFrame;
int      TradeMode;
int      SpreadModel;
int      RegressionLookBack;
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

bool     EnableScaleIn;
double   AddZStep;
int      MaxAddCount;
double   AddLotStep;
int      MinAddIntervalSec;
double   MaxAbsZ;
double   MaxTotalBaseLots;
double   MaxMarginUsagePct;
bool     RequireProfitClose;
double   MinBasketProfit;
bool     EndOfDayRequireReversion;
double   ExtremeZThreshold;

//=== Z-Score与历史数据 ===
double price1, price2;
double logSpread;
double meanValue, stdValue, zscore;

//=== OLS Spread诊断值（仅SPREAD_OLS_LOG_RESIDUAL使用） ===
double regressionAlpha = 0.0;
double regressionBeta  = 0.0;
double regressionR2    = 0.0;

double diffHistory[];
int histCount = 0;
datetime lastBarTime = 0;

//=== 冷却期状态 ===
datetime lastCloseTime = 0;
bool inCoolDown = false;

datetime lastTimeCheckLog = 0;

//+------------------------------------------------------------------+
//| Basket方向                                                      |
//| SHORT_SPREAD: Z>0极端，SELL S1 + BUY S2                         |
//| LONG_SPREAD : Z<0极端，BUY S1 + SELL S2                         |
//+------------------------------------------------------------------+
enum ENUM_PAIR_DIRECTION
{
   PAIR_DIR_NONE = 0,
   PAIR_DIR_SHORT_SPREAD = 1,
   PAIR_DIR_LONG_SPREAD = -1
};

//=== Basket运行状态 ===
bool                g_pairActive = false;
ENUM_PAIR_DIRECTION g_pairDirection = PAIR_DIR_NONE;
double              g_initialEntryZ = 0.0;
double              g_lastAddZ = 0.0;
int                 g_addCount = 0;
datetime            g_lastAddTime = 0;
bool                g_reversionReached = false;
datetime            g_basketStartTime = 0;
bool                g_needAnchorAfterRecovery = false;

//=== 优化/回测风险统计（每个Tester Pass独立） ===
double   g_testInitialBalance = 0.0;
double   g_testPeakEquity = 0.0;
double   g_testMaxAccountProfit = 0.0;      // 相对初始余额的最大正权益
double   g_testMaxAccountLoss = 0.0;        // 相对初始余额的最大亏损绝对值
double   g_testMaxEquityDrawdown = 0.0;     // 峰值权益到后续低点的最大回撤金额
double   g_testMaxEquityDrawdownPct = 0.0;  // 上述回撤相对峰值权益的百分比

double   g_metricBasketStartEquity = 0.0;
double   g_testWorstBasketLoss = 0.0;       // 单Basket最大亏损绝对值（含浮亏）
double   g_testLongestBasketHoldSec = 0.0;
double   g_testTotalBasketHoldSec = 0.0;
long     g_testCompletedBasketCount = 0;

bool     g_extremeZActive = false;
datetime g_extremeZStartTime = 0;
double   g_testMaxExtremeZDurationSec = 0.0;
double   g_testTotalExtremeZDurationSec = 0.0;
long     g_testExtremeZEpisodeCount = 0;

#define OPT_FRAME_NAME "PAIR_OPT_METRICS_V10_1"
#define OPT_FRAME_ID   10011

enum ENUM_OPT_METRIC_INDEX
{
   OM_MAX_ACCOUNT_PROFIT = 0,
   OM_MAX_ACCOUNT_LOSS,
   OM_WORST_BASKET_LOSS,
   OM_MAX_EQUITY_DD,
   OM_MAX_EQUITY_DD_PCT,
   OM_LONGEST_BASKET_HOLD_SEC,
   OM_AVG_BASKET_HOLD_SEC,
   OM_MAX_EXTREME_Z_SEC,
   OM_AVG_EXTREME_Z_SEC,
   OM_SHARPE,
   OM_NET_PROFIT,
   OM_PROFIT_FACTOR,
   OM_BASKET_COUNT,
   OM_EXTREME_EPISODE_COUNT,
   OM_ACTIVE_BASKET_AGE_SEC,
   OM_METRIC_COUNT
};

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
//| 将优化枚举映射为MT5真实周期                                     |
//| 优化参数值：0=M15，1=M30                                       |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ResolveOptimizationTimeFrame(ENUM_OPT_TIMEFRAME tf)
{
    switch(tf)
    {
        case OPT_TF_M15: return PERIOD_M15;
        case OPT_TF_M30: return PERIOD_M30;
    }
    return PERIOD_M15;
}

//+------------------------------------------------------------------+
//| 是否处于策略测试器/优化器                                        |
//| 测试器中不使用Terminal Global Variables，避免不同优化Pass互相污染 |
//+------------------------------------------------------------------+
bool IsTesterEnvironment()
{
    return (bool)MQLInfoInteger(MQL_TESTER);
}

//+------------------------------------------------------------------+
//| 初始化函数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
    //=== 将输入参数赋值给内部变量 ===
    Symbol1 = InpSymbol1;
    Symbol2 = InpSymbol2;
    TimeFrame = ResolveOptimizationTimeFrame(InpTimeFrame);
    TradeMode = (int)InpTradeMode;
    SpreadModel = SPREAD_OLS_LOG_RESIDUAL; // v10.1寻优阶段固定OLS residual
    RegressionLookBack = InpRegressionLookBack;
    LookBack_Period = InpLookBack;
    ZScore_Open = MathAbs(InpZScoreOpen);
    ZScore_Close = MathAbs(InpZScoreClose);
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

    EnableScaleIn = InpEnableScaleIn;
    AddZStep = InpAddZStep;
    MaxAddCount = InpMaxAddCount;
    AddLotStep = InpAddLotStep;
    MinAddIntervalSec = InpMinAddIntervalSec;
    MaxAbsZ = InpMaxAbsZ;
    MaxTotalBaseLots = InpMaxTotalBaseLots;
    MaxMarginUsagePct = InpMaxMarginUsagePct;
    RequireProfitClose = InpRequireProfitClose;
    MinBasketProfit = InpMinBasketProfit;
    EndOfDayRequireReversion = InpEndOfDayRequireReversion;
    ExtremeZThreshold = (InpExtremeZThreshold > 0 ? InpExtremeZThreshold : ZScore_Open);

    //=== 参数基本校验 ===
    if(LookBack_Period < 2 || ZScore_Open <= 0 || Lots <= 0 ||
       AddZStep <= 0 || MaxAddCount < 0 || AddLotStep < 0 ||
       MinAddIntervalSec < 0 || MinBasketProfit < 0 ||
       CoolDownMinutes < 0 || MaxCloseRetries < 1 || CloseRetryDelay < 0 ||
       ExtremeZThreshold <= 0 ||
       (SpreadModel == SPREAD_OLS_LOG_RESIDUAL && RegressionLookBack < 2))
    {
        Print("❌ 输入参数无效，请检查LookBack/ZScore/Lots/加仓/平仓/冷却参数");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(EnableScaleIn && MaxAbsZ > 0 && MaxAbsZ < ZScore_Open)
    {
        Print("❌ InpMaxAbsZ不能小于InpZScoreOpen；如不使用MaxAbsZ请设置<=0");
        return INIT_PARAMETERS_INCORRECT;
    }

    // 初始化动态数组
    ArrayResize(diffHistory, 0);
    histCount = 0;
    ResetTesterMetrics();

    RestoreCoolDownState();
    RestoreBasketState();

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

    Print("=== 配对交易Basket阶梯加仓版 v10.1 OLS寻优 ===");
    Print("Spread模型: ", SpreadModelToString(SpreadModel));
    if(SpreadModel == SPREAD_OLS_LOG_RESIDUAL)
        Print("OLS窗口: ", RegressionLookBack, "根已完成K线；当前bar不参与回归拟合，避免前视");
    Print("交易方向: Z>0 做空Spread(Sell S1/Buy S2)，Z<0 做多Spread(Buy S1/Sell S2)");
    Print("品种1: ", Symbol1, " | 品种2: ", Symbol2);
    Print("分析时间周期: ", timeFrameStr, " | 回看周期: ", LookBack_Period, "根K线");
    Print("首仓: |Z| >= ", DoubleToString(ZScore_Open, 2), " | 回归阈值: ±", DoubleToString(ZScore_Close, 2));
    Print("阶梯加仓: ", EnableScaleIn ? "启用" : "禁用",
          " | Z间距=", DoubleToString(AddZStep, 2),
          " | 最多加仓=", MaxAddCount,
          " | 线性手数增量=", DoubleToString(AddLotStep, 4));
    Print("加仓保护: MaxAbsZ=", DoubleToString(MaxAbsZ, 2),
          " | MinInterval=", MinAddIntervalSec, "秒",
          " | MaxBaseLots=", DoubleToString(MaxTotalBaseLots, 2),
          " | MaxMarginUsage=", DoubleToString(MaxMarginUsagePct, 1), "%");
    Print("盈利平仓: ", RequireProfitClose ? "强制" : "关闭",
          " | MinBasketProfit=", DoubleToString(MinBasketProfit, 2),
          " | EOD需回归=", EndOfDayRequireReversion ? "是" : "否");
    Print("基准手数: ", Lots, " | 冷却期: ", CoolDownMinutes, "分钟");
    Print("开仓/加仓时间(GMT): ", EarliestOpenHour, ":00 - ", LatestOpenHour, ":00");
    Print("日内清仓时间(GMT): ", CloseAtHour, ":00");
    Print("智能平仓: ", EnableSmartClose ? "启用" : "禁用",
          " | 顺序: ", CloseProfitFirst ? "先汇总盈利高的腿" : "先汇总盈利低的腿");
    Print("交易模式: ", TradeMode, " (0=同时, 1=只品种1, 2=只品种2)");
    Print("优化统计: ExtremeZ阈值=", DoubleToString(ExtremeZThreshold, 2),
          " | CSV=", InpExportOptimizationCSV ? InpOptimizationCsvName : "关闭");
    Print("Basket恢复状态: ", g_pairActive ? "有活动Basket" : "无活动Basket");
    Print("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 主处理函数                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    // 风险统计在策略判断前后各更新一次，确保开/平仓瞬间和浮动盈亏都被记录。
    UpdateTesterRiskMetrics();

    if(!GetPrices())
        return;

    UpdateHistory();

    if(histCount >= LookBack_Period)
    {
        CalculateZScore();
        UpdateExtremeZMetrics();
        UpdateCoolDownStatus();
        SynchronizeBasketState();

        // 若重启时只有持仓、没有可恢复的Basket状态，第一次拿到有效Z时
        // 只用当前Z重建“下一次加仓锚点”，避免恢复后瞬间误加仓。
        if(g_pairActive && g_needAnchorAfterRecovery && stdValue > 0)
        {
            if(g_initialEntryZ == 0.0)
                g_initialEntryZ = zscore;
            g_lastAddZ = zscore;
            g_lastAddTime = TimeCurrent();
            g_needAnchorAfterRecovery = false;
            SaveBasketState();
            Print("🔄 Basket恢复锚点已重建，当前Z=", DoubleToString(zscore, 2));
        }

        if(!g_pairActive)
        {
            if(!inCoolDown)
                CheckOpenConditions();
        }
        else
        {
            // 先处理退出。如果本Tick已经平完，则不再判断加仓。
            bool basketClosed = CheckCloseConditions();
            if(!basketClosed && g_pairActive)
                CheckScaleInConditions();
        }
    }

    if(HasAnyManagedPosition())
        CheckAndCloseAtEndOfDay();

    DisplayInfo();
    UpdateTesterRiskMetrics();
}

//+------------------------------------------------------------------+
//| 获取价格数据 / 计算Spread                                         |
//| 模型0：ln(S1/SMA1) - ln(S2/SMA2)                                 |
//| 模型1：rolling OLS log残差：                                      |
//|        log(S1_t)=alpha_t+beta_t*log(S2_t)+epsilon_t               |
//|        Spread_t=epsilon_t                                         |
//| OLS使用前N根已完成K线(i=1..N)拟合，当前bar(i=0)只用于计算残差。    |
//+------------------------------------------------------------------+
bool GetPrices()
{
    int calcLookBack = LookBack_Period;
    if(SpreadModel == SPREAD_OLS_LOG_RESIDUAL && RegressionLookBack > calcLookBack)
        calcLookBack = RegressionLookBack;

    int barsNeeded = calcLookBack + 1;

    if(iBars(Symbol1, TimeFrame) < barsNeeded)
    {
        static bool symbol1WarningPrinted = false;
        if(!symbol1WarningPrinted)
        {
            Print("⚠️ 品种1数据不足，需要至少 ", barsNeeded, " 根K线");
            symbol1WarningPrinted = true;
        }
        return false;
    }
    if(iBars(Symbol2, TimeFrame) < barsNeeded)
    {
        static bool symbol2WarningPrinted = false;
        if(!symbol2WarningPrinted)
        {
            Print("⚠️ 品种2数据不足，需要至少 ", barsNeeded, " 根K线");
            symbol2WarningPrinted = true;
        }
        return false;
    }

    double close1[];
    double close2[];
    ArraySetAsSeries(close1, true);
    ArraySetAsSeries(close2, true);

    if(CopyClose(Symbol1, TimeFrame, 0, barsNeeded, close1) < barsNeeded) return false;
    if(CopyClose(Symbol2, TimeFrame, 0, barsNeeded, close2) < barsNeeded) return false;

    double currentPrice1 = close1[0];
    double currentPrice2 = close2[0];
    if(currentPrice1 <= 0 || currentPrice2 <= 0)
        return false;

    price1 = currentPrice1;
    price2 = currentPrice2;

    regressionAlpha = 0.0;
    regressionBeta = 0.0;
    regressionR2 = 0.0;

    //==============================================================
    // Spread模型0：原有的相对自身SMA偏离
    //==============================================================
    if(SpreadModel == SPREAD_SMA_RELATIVE)
    {
        double sum1 = 0.0;
        double sum2 = 0.0;
        for(int i = 1; i <= LookBack_Period; i++)
        {
            if(close1[i] <= 0 || close2[i] <= 0)
                return false;
            sum1 += close1[i];
            sum2 += close2[i];
        }

        double sma1 = sum1 / LookBack_Period;
        double sma2 = sum2 / LookBack_Period;
        if(sma1 <= 0 || sma2 <= 0)
            return false;

        double ret1 = MathLog(currentPrice1 / sma1);
        double ret2 = MathLog(currentPrice2 / sma2);
        logSpread = ret1 - ret2;
        return true;
    }

    //==============================================================
    // Spread模型1：rolling OLS log-price residual
    // y = log(S1), x = log(S2)
    // y = alpha + beta*x + epsilon
    // Spread = epsilon(current)
    //==============================================================
    if(SpreadModel == SPREAD_OLS_LOG_RESIDUAL)
    {
        int n = RegressionLookBack;
        double sumX = 0.0;
        double sumY = 0.0;

        for(int i = 1; i <= n; i++)
        {
            if(close1[i] <= 0 || close2[i] <= 0)
                return false;

            double x = MathLog(close2[i]);
            double y = MathLog(close1[i]);
            sumX += x;
            sumY += y;
        }

        double meanX = sumX / n;
        double meanY = sumY / n;
        double sxx = 0.0;
        double sxy = 0.0;
        double syy = 0.0;

        for(int i = 1; i <= n; i++)
        {
            double x = MathLog(close2[i]);
            double y = MathLog(close1[i]);
            double dx = x - meanX;
            double dy = y - meanY;
            sxx += dx * dx;
            sxy += dx * dy;
            syy += dy * dy;
        }

        if(sxx <= 1e-16)
        {
            if(DebugPrint)
                Print("⚠️ OLS无法计算：log(", Symbol2, ")窗口方差过小");
            return false;
        }

        regressionBeta = sxy / sxx;
        regressionAlpha = meanY - regressionBeta * meanX;

        double sse = 0.0;
        for(int i = 1; i <= n; i++)
        {
            double x = MathLog(close2[i]);
            double y = MathLog(close1[i]);
            double fitted = regressionAlpha + regressionBeta * x;
            double resid = y - fitted;
            sse += resid * resid;
        }
        regressionR2 = (syy > 1e-16 ? 1.0 - sse / syy : 0.0);

        double currentX = MathLog(currentPrice2);
        double currentY = MathLog(currentPrice1);
        logSpread = currentY - (regressionAlpha + regressionBeta * currentX);
        return true;
    }

    return false;
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
//| 首仓条件：统一以Z-Score正负决定交易方向                          |
//+------------------------------------------------------------------+
void CheckOpenConditions()
{
    if(!IsTradeTimeAllowed())
    {
        if(TimeCurrent() - lastTimeCheckLog >= 3600)
        {
            if(DebugPrint)
                Print("当前时间(GMT) ", TimeToString(TimeGMT(), TIME_MINUTES), " 不在首仓/加仓时间内");
            lastTimeCheckLog = TimeCurrent();
        }
        return;
    }

    if(stdValue <= 0)
        return;

    ENUM_PAIR_DIRECTION direction = PAIR_DIR_NONE;
    if(zscore >= ZScore_Open)
        direction = PAIR_DIR_SHORT_SPREAD;
    else if(zscore <= -ZScore_Open)
        direction = PAIR_DIR_LONG_SPREAD;
    else
        return;

    if(inCoolDown)
        return;

    Print("========================================");
    Print("🎯 首仓条件满足! Z=", DoubleToString(zscore, 2),
          " | 方向=", DirectionToString(direction));

    datetime candidateStartTime = TimeCurrent();
    double candidateStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(OpenPairLevel(direction, 0))
    {
        g_pairActive = true;
        g_pairDirection = direction;
        g_initialEntryZ = zscore;
        g_lastAddZ = zscore;
        g_addCount = 0;
        g_lastAddTime = TimeCurrent();
        g_reversionReached = false;
        g_basketStartTime = candidateStartTime;
        g_needAnchorAfterRecovery = false;
        g_metricBasketStartEquity = candidateStartEquity;
        SaveBasketState();

        Print("✅ Basket首仓成功 | EntryZ=", DoubleToString(g_initialEntryZ, 2));
    }
    else
    {
        Print("❌ Basket首仓失败，本次不创建Basket状态");
    }
    Print("========================================");
}

//+------------------------------------------------------------------+
//| 连续偏离阶梯加仓                                                 |
//+------------------------------------------------------------------+
void CheckScaleInConditions()
{
    if(!EnableScaleIn || !g_pairActive || g_reversionReached)
        return;

    if(stdValue <= 0 || AddZStep <= 0)
        return;

    if(!HasRequiredBasketPositions())
    {
        if(DebugPrint)
            Print("⚠️ Basket腿不完整，暂停加仓，等待人工检查/平仓处理");
        return;
    }

    if(g_addCount >= MaxAddCount)
        return;

    if(!IsTradeTimeAllowed())
        return;

    if(MinAddIntervalSec > 0 && g_lastAddTime > 0 &&
       (TimeCurrent() - g_lastAddTime) < MinAddIntervalSec)
        return;

    if(MaxAbsZ > 0 && MathAbs(zscore) >= MaxAbsZ)
    {
        if(DebugPrint)
        {
            static datetime lastMaxZLog = 0;
            if(TimeCurrent() - lastMaxZLog >= 300)
            {
                Print("🛑 |Z|=", DoubleToString(MathAbs(zscore), 2),
                      " 已达到/超过MaxAbsZ=", DoubleToString(MaxAbsZ, 2), "，停止继续加仓");
                lastMaxZLog = TimeCurrent();
            }
        }
        return;
    }

    if(!IsMarginUsageAllowedForAdd())
        return;

    bool shouldAdd = false;
    if(g_pairDirection == PAIR_DIR_SHORT_SPREAD)
        shouldAdd = (zscore >= g_lastAddZ + AddZStep);
    else if(g_pairDirection == PAIR_DIR_LONG_SPREAD)
        shouldAdd = (zscore <= g_lastAddZ - AddZStep);

    if(!shouldAdd)
        return;

    int nextLevel = g_addCount + 1;
    double levelBaseLots = GetLevelBaseLots(nextLevel);
    if(levelBaseLots <= 0)
    {
        Print("❌ Level ", nextLevel, " 手数计算无效，跳过加仓");
        return;
    }

    if(MaxTotalBaseLots > 0)
    {
        string baseSymbol = (TradeMode == 2 ? Symbol2 : Symbol1);
        double currentBaseVolume = GetTotalVolumeForSymbol(baseSymbol);
        if(currentBaseVolume + levelBaseLots > MaxTotalBaseLots + 0.0000001)
        {
            Print("🛑 加仓将超过最大基础腿总手数: 当前=", DoubleToString(currentBaseVolume, 4),
                  " + 新层=", DoubleToString(levelBaseLots, 4),
                  " > 上限=", DoubleToString(MaxTotalBaseLots, 4));
            return;
        }
    }

    Print("========================================");
    Print("➕ 阶梯加仓触发 | Level=", nextLevel,
          " | 当前Z=", DoubleToString(zscore, 2),
          " | 上次加仓Z=", DoubleToString(g_lastAddZ, 2),
          " | 间距=", DoubleToString(AddZStep, 2));

    // 每个Tick最多只调用一次OpenPairLevel，因此即使跳过多个Z档位也只增加一层。
    if(OpenPairLevel(g_pairDirection, nextLevel))
    {
        g_addCount++;
        g_lastAddZ = zscore;
        g_lastAddTime = TimeCurrent();
        SaveBasketState();
        Print("✅ Level ", nextLevel, " 加仓成功 | AddCount=", g_addCount,
              " | 新锚点Z=", DoubleToString(g_lastAddZ, 2));
    }
    else
    {
        Print("❌ Level ", nextLevel, " 加仓失败，Basket历史层保持不变");
    }
    Print("========================================");
}

//+------------------------------------------------------------------+
//| Basket平仓：先确认“发生回归”，再确认“总Basket盈利”              |
//+------------------------------------------------------------------+
bool CheckCloseConditions()
{
    if(!g_pairActive || stdValue <= 0)
        return false;

    bool justReached = false;
    if(!g_reversionReached)
    {
        if(g_pairDirection == PAIR_DIR_SHORT_SPREAD && zscore <= ZScore_Close)
        {
            g_reversionReached = true;
            justReached = true;
        }
        else if(g_pairDirection == PAIR_DIR_LONG_SPREAD && zscore >= -ZScore_Close)
        {
            g_reversionReached = true;
            justReached = true;
        }

        if(justReached)
        {
            SaveBasketState();
            Print("🔁 Basket已到达回归区域 | Z=", DoubleToString(zscore, 2),
                  " | 后续等待总Basket达到盈利条件");
        }
    }

    if(!g_reversionReached)
        return false;

    double basketNetProfit = GetBasketNetProfit();
    if(RequireProfitClose && basketNetProfit < MinBasketProfit)
        return false;

    Print("========================================");
    Print("💰 Basket退出条件满足 | Reversion=YES | NetProfit=",
          DoubleToString(basketNetProfit, 2),
          " | MinProfit=", DoubleToString(MinBasketProfit, 2),
          " | Z=", DoubleToString(zscore, 2));

    bool closed = CloseCurrentBasket("回归后盈利平仓");
    Print("========================================");
    return closed;
}

//+------------------------------------------------------------------+
//| 统一开一层Pair                                                   |
//+------------------------------------------------------------------+
bool OpenPairLevel(ENUM_PAIR_DIRECTION direction, int level)
{
    if(direction == PAIR_DIR_NONE || level < 0)
        return false;

    string levelComment = "Pair_L" + IntegerToString(level);
    double baseLots = GetLevelBaseLots(level);
    if(baseLots <= 0)
        return false;

    if(TradeMode == 0)
    {
        double symbol1Lots = NormalizeVolumeForSymbol(Symbol1, baseLots);
        if(symbol1Lots <= 0)
        {
            Print("❌ ", Symbol1, " Level手数无效: ", DoubleToString(baseLots, 6));
            return false;
        }

        ENUM_ORDER_TYPE type1 = (direction == PAIR_DIR_SHORT_SPREAD ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
        ENUM_ORDER_TYPE type2 = (direction == PAIR_DIR_SHORT_SPREAD ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

        double filled1 = 0.0;
        bool partial1 = false;
        bool success1 = OpenPositionDetailed(Symbol1, type1, symbol1Lots, levelComment, filled1, partial1);
        if(!success1 || filled1 <= 0)
            return false;

        // 第一条腿若部分成交，用实际成交手数重新计算第二条腿，保持名义金额尽量匹配。
        double symbol2Lots = CalculateSymbol2Lots(filled1);
        if(symbol2Lots <= 0)
        {
            Print("❌ ", Symbol2, " 对冲手数计算失败，回滚本层第一条腿");
            RollbackNewlyOpenedLeg(Symbol1, type1, filled1, levelComment);
            return false;
        }

        Print("Level ", level, " 方向: ", DirectionToString(direction),
              " | ", Symbol1, "实际=", DoubleToString(filled1, 4),
              " | ", Symbol2, "目标=", DoubleToString(symbol2Lots, 4),
              partial1 ? " | S1部分成交" : "");

        Sleep(50);
        double filled2 = 0.0;
        bool partial2 = false;
        bool success2 = OpenPositionDetailed(Symbol2, type2, symbol2Lots, levelComment, filled2, partial2);
        if(success2 && !partial2)
            return true;

        // 第二条腿失败或部分成交时，本层整体回滚，避免留下失衡Pair。
        Print("❌ 第二条腿未完整成交，回滚本次新增Level，不影响历史Level");
        if(filled2 > 0)
        {
            bool rollback2 = RollbackNewlyOpenedLeg(Symbol2, type2, filled2, levelComment);
            if(!rollback2)
                Print("🚨 本层第二条腿回滚失败，请立即检查账户持仓");
        }
        bool rollback1 = RollbackNewlyOpenedLeg(Symbol1, type1, filled1, levelComment);
        if(!rollback1)
            Print("🚨 本层第一条腿回滚失败，请立即检查账户持仓");
        return false;
    }

    if(TradeMode == 1)
    {
        double symbol1Lots = NormalizeVolumeForSymbol(Symbol1, baseLots);
        ENUM_ORDER_TYPE type1 = (direction == PAIR_DIR_SHORT_SPREAD ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
        return OpenPosition(Symbol1, type1, symbol1Lots, levelComment);
    }

    if(TradeMode == 2)
    {
        double symbol2Lots = NormalizeVolumeForSymbol(Symbol2, baseLots);
        ENUM_ORDER_TYPE type2 = (direction == PAIR_DIR_SHORT_SPREAD ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
        return OpenPosition(Symbol2, type2, symbol2Lots, levelComment);
    }

    return false;
}

//+------------------------------------------------------------------+
//| 每层基础手数                                                     |
//+------------------------------------------------------------------+
double GetLevelBaseLots(int level)
{
    if(level < 0)
        return 0.0;

    // 线性递增：
    // Level 0 = Lots
    // Level 1 = Lots + 1 * AddLotStep
    // Level 2 = Lots + 2 * AddLotStep
    // ...
    return Lots + (double)level * AddLotStep;
}

//+------------------------------------------------------------------+
//| 时间控制                                                         |
//+------------------------------------------------------------------+
bool IsTradeTimeAllowed()
{
    datetime currentGMT = TimeGMT();
    MqlDateTime dt;
    TimeToStruct(currentGMT, dt);
    int currentHour = dt.hour;
    return (currentHour >= EarliestOpenHour && currentHour <= LatestOpenHour);
}

//+------------------------------------------------------------------+
//| 冷却期                                                           |
//+------------------------------------------------------------------+
void UpdateCoolDownStatus()
{
    if(lastCloseTime == 0)
    {
        inCoolDown = false;
        return;
    }

    double minutesSinceClose = (TimeCurrent() - lastCloseTime) / 60.0;
    inCoolDown = (minutesSinceClose < CoolDownMinutes);

    if(!inCoolDown)
        DeleteCoolDownState();
}

void StartCoolDown()
{
    lastCloseTime = TimeCurrent();
    inCoolDown = (CoolDownMinutes > 0);
    SaveCoolDownState();
    Print("✅ Basket已全部平仓，开始", DoubleToString(CoolDownMinutes, 1), "分钟冷却期");
}

//+------------------------------------------------------------------+
//| 手数计算与标准化                                                 |
//+------------------------------------------------------------------+
double NormalizeVolumeForSymbol(string symbol, double volume)
{
    if(volume <= 0)
        return 0.0;

    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

    if(minLot <= 0 || maxLot <= 0 || lotStep <= 0)
        return 0.0;

    if(volume > maxLot + 0.0000001)
        return 0.0;

    double normalized = MathRound(volume / lotStep) * lotStep;
    if(normalized < minLot)
        normalized = minLot;
    if(normalized > maxLot)
        return 0.0;

    return NormalizeDouble(normalized, 8);
}

double CalculateSymbol2Lots(double symbol1Lots)
{
    double symbol1Notional = symbol1Lots * Symbol1LotSize * price1;
    double symbol2NotionalPerLot = Symbol2LotSize * price2;
    if(symbol2NotionalPerLot <= 0)
        return 0;

    double rawLots = symbol1Notional / symbol2NotionalPerLot;
    return NormalizeVolumeForSymbol(Symbol2, rawLots);
}

//+------------------------------------------------------------------+
//| 开仓                                                             |
//+------------------------------------------------------------------+
bool OpenPositionDetailed(string symbol, ENUM_ORDER_TYPE orderType, double volume, string orderComment,
                          double &filledVolume, bool &isPartial)
{
    filledVolume = 0.0;
    isPartial = false;

    volume = NormalizeVolumeForSymbol(symbol, volume);
    if(volume <= 0)
    {
        Print("❌ ", symbol, " 手数无效或超过上限");
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
    request.comment = orderComment;
    request.deviation = Slippage;

    if(orderType == ORDER_TYPE_BUY)
        request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    else
        request.price = SymbolInfoDouble(symbol, SYMBOL_BID);

    bool success = OrderSend(request, result);

    if(success && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL))
    {
        filledVolume = (result.volume > 0 ? result.volume : volume);
        isPartial = (result.retcode == TRADE_RETCODE_DONE_PARTIAL || filledVolume + 0.0000001 < volume);

        Print("✅ ", symbol, " 开仓成交 | comment=", orderComment,
              " | 请求=", DoubleToString(volume, 4),
              " | 成交=", DoubleToString(filledVolume, 4),
              " | order=", result.order, " | deal=", result.deal,
              " | retcode=", result.retcode);
        return (filledVolume > 0);
    }

    Print("❌ ", symbol, " 开仓失败: ", result.retcode, " - ", GetRetcodeDescription(result.retcode));
    return false;
}

bool OpenPosition(string symbol, ENUM_ORDER_TYPE orderType, double volume, string orderComment)
{
    double filledVolume = 0.0;
    bool isPartial = false;
    return OpenPositionDetailed(symbol, orderType, volume, orderComment, filledVolume, isPartial);
}

//+------------------------------------------------------------------+
//| 第二条腿失败时，仅回滚本层新增的第一条腿                         |
//+------------------------------------------------------------------+
bool RollbackNewlyOpenedLeg(string symbol, ENUM_ORDER_TYPE openType, double requestedVolume, string levelComment)
{
    ENUM_POSITION_TYPE expectedType = (openType == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
    long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);

    // Hedging账户：优先按本层comment找到最新独立Position。
    if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    {
        ulong newestTicket = 0;
        long newestTimeMsc = -1;
        double newestVolume = 0.0;

        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0 || !PositionSelectByTicket(ticket))
                continue;

            if(PositionGetString(POSITION_SYMBOL) != symbol)
                continue;
            if((long)PositionGetInteger(POSITION_MAGIC) != Magic_Number)
                continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != expectedType)
                continue;

            string comment = PositionGetString(POSITION_COMMENT);
            if(comment != levelComment)
                continue;

            long timeMsc = PositionGetInteger(POSITION_TIME_MSC);
            if(timeMsc > newestTimeMsc)
            {
                newestTimeMsc = timeMsc;
                newestTicket = ticket;
                newestVolume = PositionGetDouble(POSITION_VOLUME);
            }
        }

        if(newestTicket > 0)
            return CloseSinglePosition(newestTicket, symbol, expectedType, newestVolume);
    }

    // Netting/Exchange账户（或Hedging未找到comment）：只减掉本次新增的volume。
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != symbol)
            continue;
        if((long)PositionGetInteger(POSITION_MAGIC) != Magic_Number)
            continue;
        if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != expectedType)
            continue;

        double currentVolume = PositionGetDouble(POSITION_VOLUME);
        double rollbackVolume = MathMin(currentVolume, requestedVolume);
        rollbackVolume = NormalizeVolumeForSymbol(symbol, rollbackVolume);
        if(rollbackVolume > 0)
            return CloseSinglePosition(ticket, symbol, expectedType, rollbackVolume);
    }

    return false;
}

//+------------------------------------------------------------------+
//| 保证金占用保护                                                   |
//+------------------------------------------------------------------+
bool IsMarginUsageAllowedForAdd()
{
    if(MaxMarginUsagePct <= 0)
        return true;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double margin = AccountInfoDouble(ACCOUNT_MARGIN);
    if(equity <= 0)
        return false;

    double usagePct = margin / equity * 100.0;
    if(usagePct >= MaxMarginUsagePct)
    {
        Print("🛑 当前保证金/净值=", DoubleToString(usagePct, 1),
              "% >= 加仓上限 ", DoubleToString(MaxMarginUsagePct, 1), "% ，停止加仓");
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| 日内清仓：默认同样要求“已回归 + Basket净盈利”                    |
//+------------------------------------------------------------------+
void CheckAndCloseAtEndOfDay()
{
    datetime currentGMT = TimeGMT();
    MqlDateTime dt;
    TimeToStruct(currentGMT, dt);

    if(dt.hour != CloseAtHour || !g_pairActive)
        return;

    if(EndOfDayRequireReversion && !g_reversionReached)
        return;

    double basketNetProfit = GetBasketNetProfit();
    if(RequireProfitClose && basketNetProfit < MinBasketProfit)
        return;

    Print("⏰ 日内清仓条件满足 (GMT ", CloseAtHour, ":00)",
          " | Reversion=", g_reversionReached ? "YES" : "NO",
          " | BasketNet=", DoubleToString(basketNetProfit, 2));
    CloseCurrentBasket("日内清仓");
}

//+------------------------------------------------------------------+
//| Basket盈利统计                                                   |
//| 当前持仓：POSITION_PROFIT + POSITION_SWAP                         |
//| 历史成交：本Basket开始以来的Commission/Fee；若有退出成交则加Realized P/L |
//+------------------------------------------------------------------+
double GetBasketNetProfit()
{
    double total = 0.0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

        string symbol = PositionGetString(POSITION_SYMBOL);
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic != Magic_Number || (symbol != Symbol1 && symbol != Symbol2))
            continue;

        total += PositionGetDouble(POSITION_PROFIT);
        total += PositionGetDouble(POSITION_SWAP);
    }

    if(g_basketStartTime > 0 && HistorySelect(g_basketStartTime, TimeCurrent()))
    {
        int deals = HistoryDealsTotal();
        for(int i = 0; i < deals; i++)
        {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0)
                continue;

            long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
            string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
            if(magic != Magic_Number || (symbol != Symbol1 && symbol != Symbol2))
                continue;

            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            total += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            total += HistoryDealGetDouble(dealTicket, DEAL_FEE);

            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
            {
                total += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                total += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            }
        }
    }

    return total;
}

//+------------------------------------------------------------------+
//| 每个品种当前持仓汇总盈亏（用于决定智能平仓顺序）                 |
//+------------------------------------------------------------------+
double GetSymbolBasketFloatingProfit(string symbol)
{
    double total = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) == symbol &&
           (long)PositionGetInteger(POSITION_MAGIC) == Magic_Number)
        {
            total += PositionGetDouble(POSITION_PROFIT);
            total += PositionGetDouble(POSITION_SWAP);
        }
    }
    return total;
}

//+------------------------------------------------------------------+
//| 统一Basket平仓入口                                               |
//+------------------------------------------------------------------+
bool CloseCurrentBasket(string reason)
{
    if(!HasAnyManagedPosition())
    {
        FinalizeBasketClose(reason + "（检测到已无持仓）");
        return true;
    }

    bool allClosed = false;
    if(TradeMode == 0)
    {
        if(EnableSmartClose)
        {
            if(CloseProfitFirst)
                allClosed = CloseAllPairPositionsSmartProfitFirst();
            else
                allClosed = CloseAllPairPositionsSmartLossFirst();
        }
        else
        {
            allClosed = CloseAllPairPositions();
        }
    }
    else if(TradeMode == 1)
    {
        allClosed = CloseAllPositionsForSymbolWithRetries(Symbol1);
    }
    else if(TradeMode == 2)
    {
        allClosed = CloseAllPositionsForSymbolWithRetries(Symbol2);
    }

    Sleep(100);
    if(allClosed && !HasAnyManagedPosition())
    {
        FinalizeBasketClose(reason);
        return true;
    }

    Print("⚠️ Basket未完全平仓，不启动冷却；保留Basket状态继续管理");
    SaveBasketState();
    return false;
}

bool CloseAllPairPositions()
{
    Print("正在关闭整个Basket（默认顺序：S2 → S1）...");
    bool s2Closed = CloseAllPositionsForSymbolWithRetries(Symbol2);
    Sleep(50);
    bool s1Closed = CloseAllPositionsForSymbolWithRetries(Symbol1);
    return (s1Closed && s2Closed);
}

bool CloseAllPairPositionsSmartProfitFirst()
{
    Print("📊 智能平仓（按品种汇总：先盈利高的腿）");
    double profit1 = GetSymbolBasketFloatingProfit(Symbol1);
    double profit2 = GetSymbolBasketFloatingProfit(Symbol2);

    string firstSymbol = (profit1 >= profit2 ? Symbol1 : Symbol2);
    string secondSymbol = (firstSymbol == Symbol1 ? Symbol2 : Symbol1);

    Print(Symbol1, " 汇总浮盈=", DoubleToString(profit1, 2),
          " | ", Symbol2, " 汇总浮盈=", DoubleToString(profit2, 2),
          " | 先平=", firstSymbol);

    bool firstClosed = CloseAllPositionsForSymbolWithRetries(firstSymbol);
    Sleep(CloseRetryDelay);
    bool secondClosed = CloseAllPositionsForSymbolWithRetries(secondSymbol);
    return (firstClosed && secondClosed);
}

bool CloseAllPairPositionsSmartLossFirst()
{
    Print("📊 智能平仓（按品种汇总：先盈利低的腿）");
    double profit1 = GetSymbolBasketFloatingProfit(Symbol1);
    double profit2 = GetSymbolBasketFloatingProfit(Symbol2);

    string firstSymbol = (profit1 <= profit2 ? Symbol1 : Symbol2);
    string secondSymbol = (firstSymbol == Symbol1 ? Symbol2 : Symbol1);

    Print(Symbol1, " 汇总浮盈=", DoubleToString(profit1, 2),
          " | ", Symbol2, " 汇总浮盈=", DoubleToString(profit2, 2),
          " | 先平=", firstSymbol);

    bool firstClosed = CloseAllPositionsForSymbolWithRetries(firstSymbol);
    Sleep(CloseRetryDelay);
    bool secondClosed = CloseAllPositionsForSymbolWithRetries(secondSymbol);
    return (firstClosed && secondClosed);
}

//+------------------------------------------------------------------+
//| 平单                                                             |
//+------------------------------------------------------------------+
bool CloseSinglePosition(ulong ticket, string symbol, ENUM_POSITION_TYPE type, double volume)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};

    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = symbol;
    request.volume = volume;
    request.magic = Magic_Number;
    request.comment = "BasketClose";
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
    if(success && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL))
    {
        Print("✅ ", symbol, " 平仓/减仓成功 | ticket=", ticket, " | volume=", DoubleToString(volume, 4));
        return true;
    }

    Print("❌ ", symbol, " 平仓失败: ", result.retcode, " - ", GetRetcodeDescription(result.retcode));
    return false;
}

int CloseAllPositionsForSymbol(string symbol)
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
    if(closed > 0)
        Print("📊 ", symbol, " 本轮已提交平仓 ", closed, " 个仓位");
    return closed;
}

bool CloseAllPositionsForSymbolWithRetries(string symbol)
{
    for(int retry = 0; retry < MaxCloseRetries; retry++)
    {
        if(CountPositionsForSymbol(symbol) == 0)
            return true;

        if(retry > 0)
            Sleep(CloseRetryDelay);

        CloseAllPositionsForSymbol(symbol);
        Sleep(100);
    }

    int remaining = CountPositionsForSymbol(symbol);
    if(remaining > 0)
        Print("❌ ", symbol, " 重试后仍剩余 ", remaining, " 个持仓");
    return (remaining == 0);
}

//+------------------------------------------------------------------+
//| 持仓统计                                                         |
//+------------------------------------------------------------------+
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

double GetTotalVolumeForSymbol(string symbol)
{
    double total = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == symbol &&
               (long)PositionGetInteger(POSITION_MAGIC) == Magic_Number)
            {
                total += PositionGetDouble(POSITION_VOLUME);
            }
        }
    }
    return total;
}

bool HasAnyManagedPosition()
{
    return (CountPositionsForSymbol(Symbol1) > 0 || CountPositionsForSymbol(Symbol2) > 0);
}

bool HasRequiredBasketPositions()
{
    int positions1 = CountPositionsForSymbol(Symbol1);
    int positions2 = CountPositionsForSymbol(Symbol2);

    if(TradeMode == 0)
        return (positions1 > 0 && positions2 > 0);
    if(TradeMode == 1)
        return (positions1 > 0);
    if(TradeMode == 2)
        return (positions2 > 0);
    return false;
}

//+------------------------------------------------------------------+
//| Basket状态持久化（Terminal Global Variables）                    |
//+------------------------------------------------------------------+
string BasketStatePrefix()
{
    // 加入分析周期，避免同一Magic/品种在不同周期实例之间共享状态。
    string prefix = "PB_" + IntegerToString(Magic_Number) + "_" + Symbol1 + "_" + Symbol2 +
                    "_TF" + IntegerToString((int)TimeFrame) +
                    "_SM" + IntegerToString(SpreadModel);
    if(StringLen(prefix) > 44)
        prefix = StringSubstr(prefix, 0, 44);
    return prefix;
}

string GVName(string suffix)
{
    return BasketStatePrefix() + "_" + suffix;
}

void SaveBasketState()
{
    // 优化/回测Pass使用内存状态即可，禁止写Terminal全局变量，避免不同Pass互相污染。
    if(IsTesterEnvironment())
        return;

    if(!g_pairActive)
        return;

    GlobalVariableSet(GVName("DIR"), (double)g_pairDirection);
    GlobalVariableSet(GVName("ENTRYZ"), g_initialEntryZ);
    GlobalVariableSet(GVName("LASTZ"), g_lastAddZ);
    GlobalVariableSet(GVName("ADDC"), (double)g_addCount);
    GlobalVariableSet(GVName("ADDT"), (double)g_lastAddTime);
    GlobalVariableSet(GVName("REVERT"), g_reversionReached ? 1.0 : 0.0);
    GlobalVariableSet(GVName("START"), (double)g_basketStartTime);
    GlobalVariablesFlush();
}

void DeleteBasketState()
{
    if(IsTesterEnvironment())
        return;

    string suffixes[] = {"DIR", "ENTRYZ", "LASTZ", "ADDC", "ADDT", "REVERT", "START"};
    for(int i = 0; i < ArraySize(suffixes); i++)
    {
        string name = GVName(suffixes[i]);
        if(GlobalVariableCheck(name))
            GlobalVariableDel(name);
    }
}

void ResetBasketState()
{
    g_pairActive = false;
    g_pairDirection = PAIR_DIR_NONE;
    g_initialEntryZ = 0.0;
    g_lastAddZ = 0.0;
    g_addCount = 0;
    g_lastAddTime = 0;
    g_reversionReached = false;
    g_basketStartTime = 0;
    g_needAnchorAfterRecovery = false;
    g_metricBasketStartEquity = 0.0;
    DeleteBasketState();
}

void RestoreBasketState()
{
    // 策略测试器每个Pass从独立的内存状态开始，不读取Terminal Global Variables。
    if(IsTesterEnvironment())
    {
        g_pairActive = HasAnyManagedPosition();
        g_pairDirection = PAIR_DIR_NONE;
        g_initialEntryZ = 0.0;
        g_lastAddZ = 0.0;
        g_addCount = 0;
        g_lastAddTime = 0;
        g_reversionReached = false;
        g_basketStartTime = 0;
        g_needAnchorAfterRecovery = g_pairActive;
        return;
    }

    bool hasPositions = HasAnyManagedPosition();
    bool hasSavedState = GlobalVariableCheck(GVName("DIR"));

    if(!hasPositions)
    {
        if(hasSavedState)
            DeleteBasketState();
        ResetBasketState();
        return;
    }

    if(hasSavedState)
    {
        g_pairActive = true;
        g_pairDirection = (ENUM_PAIR_DIRECTION)(int)GlobalVariableGet(GVName("DIR"));
        g_initialEntryZ = GlobalVariableCheck(GVName("ENTRYZ")) ? GlobalVariableGet(GVName("ENTRYZ")) : 0.0;
        g_lastAddZ = GlobalVariableCheck(GVName("LASTZ")) ? GlobalVariableGet(GVName("LASTZ")) : 0.0;
        g_addCount = GlobalVariableCheck(GVName("ADDC")) ? (int)GlobalVariableGet(GVName("ADDC")) : 0;
        g_lastAddTime = GlobalVariableCheck(GVName("ADDT")) ? (datetime)GlobalVariableGet(GVName("ADDT")) : 0;
        g_reversionReached = GlobalVariableCheck(GVName("REVERT")) ? (GlobalVariableGet(GVName("REVERT")) > 0.5) : false;
        g_basketStartTime = GlobalVariableCheck(GVName("START")) ? (datetime)GlobalVariableGet(GVName("START")) : TimeCurrent();
        g_needAnchorAfterRecovery = false;

        Print("🔄 已从Terminal Global Variables恢复Basket状态 | Dir=", DirectionToString(g_pairDirection),
              " | AddCount=", g_addCount,
              " | LastZ=", DoubleToString(g_lastAddZ, 2),
              " | Reversion=", g_reversionReached ? "YES" : "NO");
        return;
    }

    // 存在真实持仓但没有保存状态：安全推断方向，第一次有效Z只作为新的加仓锚点。
    ENUM_PAIR_DIRECTION inferred = InferDirectionFromPositions();
    if(inferred == PAIR_DIR_NONE)
    {
        Print("🚨 检测到EA持仓但无法推断Basket方向，暂停自动加仓；请检查持仓方向");
        g_pairActive = true;
        g_pairDirection = PAIR_DIR_NONE;
        g_needAnchorAfterRecovery = true;
        g_basketStartTime = TimeCurrent();
        return;
    }

    g_pairActive = true;
    g_pairDirection = inferred;
    g_initialEntryZ = 0.0;
    g_lastAddZ = 0.0;
    g_lastAddTime = TimeCurrent();
    g_reversionReached = false;
    g_basketStartTime = TimeCurrent();
    g_needAnchorAfterRecovery = true;

    long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
    if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    {
        int levels = 0;
        if(TradeMode == 0)
            levels = MathMax(CountPositionsForSymbol(Symbol1), CountPositionsForSymbol(Symbol2));
        else if(TradeMode == 1)
            levels = CountPositionsForSymbol(Symbol1);
        else if(TradeMode == 2)
            levels = CountPositionsForSymbol(Symbol2);

        g_addCount = (levels > 0 ? levels - 1 : 0);
    }
    else
    {
        // Netting账户无法从Position数量反推出加仓层数，安全起见从0开始并重建Z锚点。
        g_addCount = 0;
    }

    SaveBasketState();
    Print("⚠️ 检测到持仓但无保存状态：已推断方向=", DirectionToString(g_pairDirection),
          "，将用首个有效Z重建加仓锚点");
}

ENUM_PAIR_DIRECTION InferDirectionFromPositions()
{
    double signedS1 = GetSignedVolume(Symbol1); // BUY为+，SELL为-
    double signedS2 = GetSignedVolume(Symbol2);

    if(TradeMode == 0)
    {
        if(signedS1 < 0 && signedS2 > 0)
            return PAIR_DIR_SHORT_SPREAD;
        if(signedS1 > 0 && signedS2 < 0)
            return PAIR_DIR_LONG_SPREAD;
    }
    else if(TradeMode == 1)
    {
        if(signedS1 < 0) return PAIR_DIR_SHORT_SPREAD;
        if(signedS1 > 0) return PAIR_DIR_LONG_SPREAD;
    }
    else if(TradeMode == 2)
    {
        if(signedS2 > 0) return PAIR_DIR_SHORT_SPREAD;
        if(signedS2 < 0) return PAIR_DIR_LONG_SPREAD;
    }

    return PAIR_DIR_NONE;
}

double GetSignedVolume(string symbol)
{
    double signedVolume = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != symbol ||
           (long)PositionGetInteger(POSITION_MAGIC) != Magic_Number)
            continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double volume = PositionGetDouble(POSITION_VOLUME);
        signedVolume += (type == POSITION_TYPE_BUY ? volume : -volume);
    }
    return signedVolume;
}

void SynchronizeBasketState()
{
    bool hasPositions = HasAnyManagedPosition();

    if(hasPositions && !g_pairActive)
    {
        RestoreBasketState();
        return;
    }

    // Basket状态仍在，但仓位被外部/人工完全关闭：按一次完整退出处理并启动冷却，避免立刻重开。
    if(!hasPositions && g_pairActive)
    {
        Print("⚠️ 检测到活动Basket持仓已被外部完全关闭，按Basket结束处理");
        FinalizeBasketClose("外部/人工平仓");
    }
}

void FinalizeBasketClose(string reason)
{
    Print("✅ Basket完整结束 | 原因: ", reason);
    RecordCompletedBasketMetrics();
    ResetBasketState();
    StartCoolDown();
}

//+------------------------------------------------------------------+
//| 冷却状态持久化                                                   |
//+------------------------------------------------------------------+
void SaveCoolDownState()
{
    if(IsTesterEnvironment())
        return;

    GlobalVariableSet(GVName("CLOSE"), (double)lastCloseTime);
    GlobalVariablesFlush();
}

void RestoreCoolDownState()
{
    if(IsTesterEnvironment())
    {
        lastCloseTime = 0;
        inCoolDown = false;
        return;
    }

    if(GlobalVariableCheck(GVName("CLOSE")))
    {
        lastCloseTime = (datetime)GlobalVariableGet(GVName("CLOSE"));
        UpdateCoolDownStatus();
    }
}

void DeleteCoolDownState()
{
    if(IsTesterEnvironment())
        return;

    string name = GVName("CLOSE");
    if(GlobalVariableCheck(name))
        GlobalVariableDel(name);
}

//+------------------------------------------------------------------+
//| Spread模型文字                                                   |
//+------------------------------------------------------------------+
string SpreadModelToString(int model)
{
    if(model == SPREAD_SMA_RELATIVE)
        return "SMA_RELATIVE: ln(S1/SMA1)-ln(S2/SMA2)";
    if(model == SPREAD_OLS_LOG_RESIDUAL)
        return "OLS_LOG_RESIDUAL: log(S1)-alpha-beta*log(S2)";
    return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| Tester风险指标初始化                                              |
//+------------------------------------------------------------------+
void ResetTesterMetrics()
{
    g_testInitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(g_testInitialBalance <= 0)
        g_testInitialBalance = equity;

    g_testPeakEquity = equity;
    g_testMaxAccountProfit = 0.0;
    g_testMaxAccountLoss = 0.0;
    g_testMaxEquityDrawdown = 0.0;
    g_testMaxEquityDrawdownPct = 0.0;

    g_metricBasketStartEquity = 0.0;
    g_testWorstBasketLoss = 0.0;
    g_testLongestBasketHoldSec = 0.0;
    g_testTotalBasketHoldSec = 0.0;
    g_testCompletedBasketCount = 0;

    g_extremeZActive = false;
    g_extremeZStartTime = 0;
    g_testMaxExtremeZDurationSec = 0.0;
    g_testTotalExtremeZDurationSec = 0.0;
    g_testExtremeZEpisodeCount = 0;
}

//+------------------------------------------------------------------+
//| 每Tick更新账户/Basket风险指标（仅测试器）                         |
//| MaxAccountProfit/Loss均相对初始Balance，使用Equity，因此含浮盈浮亏 |
//+------------------------------------------------------------------+
void UpdateTesterRiskMetrics()
{
    if(!IsTesterEnvironment())
        return;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);

    if(g_testInitialBalance <= 0)
    {
        g_testInitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        if(g_testInitialBalance <= 0)
            g_testInitialBalance = equity;
    }

    if(g_testPeakEquity == 0.0)
        g_testPeakEquity = (g_testInitialBalance > 0 ? g_testInitialBalance : equity);

    double accountPnL = equity - g_testInitialBalance;
    if(accountPnL > g_testMaxAccountProfit)
        g_testMaxAccountProfit = accountPnL;
    if(accountPnL < 0 && -accountPnL > g_testMaxAccountLoss)
        g_testMaxAccountLoss = -accountPnL;

    if(equity > g_testPeakEquity)
        g_testPeakEquity = equity;

    double drawdown = g_testPeakEquity - equity;
    if(drawdown > g_testMaxEquityDrawdown)
        g_testMaxEquityDrawdown = drawdown;

    if(g_testPeakEquity > 0)
    {
        double ddPct = drawdown / g_testPeakEquity * 100.0;
        if(ddPct > g_testMaxEquityDrawdownPct)
            g_testMaxEquityDrawdownPct = ddPct;
    }

    if(g_pairActive)
    {
        // 优化时每个Pass只有本EA在管理账户，因此用Basket开仓前Equity作为基准，
        // 可低成本地记录该Basket全生命周期的实际权益浮动（含点差/佣金/Swap/浮盈亏）。
        if(g_metricBasketStartEquity <= 0)
            g_metricBasketStartEquity = equity;

        double basketPnL = equity - g_metricBasketStartEquity;
        if(basketPnL < 0 && -basketPnL > g_testWorstBasketLoss)
            g_testWorstBasketLoss = -basketPnL;

        if(g_basketStartTime > 0)
        {
            double holdSec = (double)(TimeCurrent() - g_basketStartTime);
            if(holdSec > g_testLongestBasketHoldSec)
                g_testLongestBasketHoldSec = holdSec;
        }
    }
}

//+------------------------------------------------------------------+
//| Basket完成时记录持仓时长                                          |
//+------------------------------------------------------------------+
void RecordCompletedBasketMetrics()
{
    if(!IsTesterEnvironment())
        return;

    UpdateTesterRiskMetrics();

    if(g_basketStartTime > 0)
    {
        double holdSec = (double)(TimeCurrent() - g_basketStartTime);
        if(holdSec < 0)
            holdSec = 0;

        g_testTotalBasketHoldSec += holdSec;
        g_testCompletedBasketCount++;

        if(holdSec > g_testLongestBasketHoldSec)
            g_testLongestBasketHoldSec = holdSec;
    }

    g_metricBasketStartEquity = 0.0;
}

//+------------------------------------------------------------------+
//| 极端Z持续时间：|Z|>=ExtremeZThreshold视为一个连续episode          |
//+------------------------------------------------------------------+
void UpdateExtremeZMetrics()
{
    if(!IsTesterEnvironment() || stdValue <= 0)
        return;

    datetime now = TimeCurrent();
    bool isExtreme = (MathAbs(zscore) >= ExtremeZThreshold);

    if(isExtreme)
    {
        if(!g_extremeZActive)
        {
            g_extremeZActive = true;
            g_extremeZStartTime = now;
        }

        double duration = (double)(now - g_extremeZStartTime);
        if(duration > g_testMaxExtremeZDurationSec)
            g_testMaxExtremeZDurationSec = duration;
        return;
    }

    if(g_extremeZActive)
    {
        double duration = (double)(now - g_extremeZStartTime);
        if(duration < 0)
            duration = 0;

        g_testTotalExtremeZDurationSec += duration;
        g_testExtremeZEpisodeCount++;

        if(duration > g_testMaxExtremeZDurationSec)
            g_testMaxExtremeZDurationSec = duration;

        g_extremeZActive = false;
        g_extremeZStartTime = 0;
    }
}

//+------------------------------------------------------------------+
//| 获取帧中的输入参数值                                              |
//+------------------------------------------------------------------+
string FindFrameInputValue(string &parameters[], uint parametersCount, string parameterName)
{
    string prefix = parameterName + "=";
    for(uint i = 0; i < parametersCount && i < (uint)ArraySize(parameters); i++)
    {
        if(StringFind(parameters[i], prefix) == 0)
            return StringSubstr(parameters[i], StringLen(prefix));
    }
    return "";
}

string FrameTimeFrameName(string rawValue)
{
    if(StringFind(rawValue, "M15") >= 0) return "M15";
    if(StringFind(rawValue, "M30") >= 0) return "M30";

    int v = (int)StringToInteger(rawValue);
    if(v == OPT_TF_M15) return "M15";
    if(v == OPT_TF_M30) return "M30";
    return rawValue;
}

string FrameSpreadModelName(string rawValue)
{
    if(StringFind(rawValue, "OLS") >= 0) return "OLS_LOG_RESIDUAL";
    if(StringFind(rawValue, "SMA") >= 0) return "SMA_RELATIVE";

    int v = (int)StringToInteger(rawValue);
    if(v == SPREAD_SMA_RELATIVE) return "SMA_RELATIVE";
    if(v == SPREAD_OLS_LOG_RESIDUAL) return "OLS_LOG_RESIDUAL";
    return rawValue;
}

//+------------------------------------------------------------------+
//| 综合优化评分 Score                                               |
//| 目标：奖励收益/Sharpe/PF，同时惩罚回撤、单Basket尾部风险、长持仓 |
//| Score越高越好；核心质量为负时返回负分。                          |
//+------------------------------------------------------------------+
double CalculateOptimizationScore(double initialDeposit,
                                  double netProfit,
                                  double sharpe,
                                  double profitFactor,
                                  double maxDrawdownPct,
                                  double worstBasketLoss,
                                  double longestBasketHoldSec,
                                  double activeBasketAgeSec,
                                  double maxExtremeZSec,
                                  long basketCount)
{
    if(initialDeposit <= 0.0)
        initialDeposit = 1.0;

    double returnPct = 100.0 * netProfit / initialDeposit;
    double worstBasketLossPct = 100.0 * worstBasketLoss / initialDeposit;
    double longestHoldDays = longestBasketHoldSec / 86400.0;
    double activeBasketDays = activeBasketAgeSec / 86400.0;
    double maxExtremeHours = maxExtremeZSec / 3600.0;

    // 盈利质量：PF只奖励超过1.0的部分，避免“仅靠高净利润但PF接近1”的组合排名过高。
    double pfEdge = profitFactor - 1.0;

    // 若策略本身没有正的统计优势，直接给负分，防止负×负意外得到正分。
    if(netProfit <= 0.0 || sharpe <= 0.0 || pfEdge <= 0.0)
    {
        double badness = MathAbs(returnPct) + MathMax(0.0, maxDrawdownPct)
                       + MathMax(0.0, worstBasketLossPct);
        return -badness;
    }

    // 核心：Return% × Sharpe × (PF-1)。乘100仅为了让Score更易读。
    double score = returnPct * sharpe * pfEdge * 100.0;

    // 风险惩罚：10% DD 或 10% 单Basket亏损都显著降低评分。
    double riskDenom = 1.0
                     + MathMax(0.0, maxDrawdownPct) / 10.0
                     + MathMax(0.0, worstBasketLossPct) / 10.0;
    score /= riskDenom;

    // 尾部持仓惩罚：超过30天的最长Basket按比例扣分。
    if(longestHoldDays > 30.0)
        score *= 30.0 / longestHoldDays;

    // 回测结束仍有未解决Basket时处罚更重：超过7天按比例扣分。
    if(activeBasketDays > 7.0)
        score *= 7.0 / activeBasketDays;

    // 极端Z连续超过24小时，按持续时长扣分。
    if(maxExtremeHours > 24.0)
        score *= 24.0 / maxExtremeHours;

    // 样本太少时降低可信度；30个Basket以上不再处罚。
    if(basketCount > 0 && basketCount < 30)
        score *= (double)basketCount / 30.0;
    else if(basketCount <= 0)
        score = -1000000.0;

    return score;
}

//+------------------------------------------------------------------+
//| 单Pass结束：发送自定义指标，并返回综合Score作为Custom max         |
//+------------------------------------------------------------------+
double OnTester()
{
    UpdateTesterRiskMetrics();

    double maxHoldSec = g_testLongestBasketHoldSec;
    double totalHoldSec = g_testTotalBasketHoldSec;
    long observedBasketCount = g_testCompletedBasketCount;
    double activeBasketAgeSec = 0.0;

    // 数据结束时仍未平仓的Basket也计入“观察到的持仓时长”，避免低估尾部持仓风险。
    if(g_pairActive && g_basketStartTime > 0)
    {
        activeBasketAgeSec = (double)(TimeCurrent() - g_basketStartTime);
        if(activeBasketAgeSec < 0)
            activeBasketAgeSec = 0;

        totalHoldSec += activeBasketAgeSec;
        observedBasketCount++;
        if(activeBasketAgeSec > maxHoldSec)
            maxHoldSec = activeBasketAgeSec;
    }

    double maxExtremeSec = g_testMaxExtremeZDurationSec;
    double totalExtremeSec = g_testTotalExtremeZDurationSec;
    long extremeCount = g_testExtremeZEpisodeCount;

    if(g_extremeZActive && g_extremeZStartTime > 0)
    {
        double activeExtremeSec = (double)(TimeCurrent() - g_extremeZStartTime);
        if(activeExtremeSec < 0)
            activeExtremeSec = 0;

        totalExtremeSec += activeExtremeSec;
        extremeCount++;
        if(activeExtremeSec > maxExtremeSec)
            maxExtremeSec = activeExtremeSec;
    }

    double avgHoldSec = (observedBasketCount > 0 ? totalHoldSec / observedBasketCount : 0.0);
    double avgExtremeSec = (extremeCount > 0 ? totalExtremeSec / extremeCount : 0.0);

    double sharpe = TesterStatistics(STAT_SHARPE_RATIO);
    double netProfit = TesterStatistics(STAT_PROFIT);
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double initialDeposit = TesterStatistics(STAT_INITIAL_DEPOSIT);

    if(!MathIsValidNumber(sharpe))
        sharpe = -999.0;
    if(!MathIsValidNumber(netProfit))
        netProfit = 0.0;
    if(!MathIsValidNumber(profitFactor))
        profitFactor = 0.0;
    if(!MathIsValidNumber(initialDeposit) || initialDeposit <= 0.0)
        initialDeposit = g_testInitialBalance > 0.0 ? g_testInitialBalance : 1.0;

    double score = CalculateOptimizationScore(initialDeposit,
                                              netProfit,
                                              sharpe,
                                              profitFactor,
                                              g_testMaxEquityDrawdownPct,
                                              g_testWorstBasketLoss,
                                              maxHoldSec,
                                              activeBasketAgeSec,
                                              maxExtremeSec,
                                              observedBasketCount);

    double metrics[];
    ArrayResize(metrics, OM_METRIC_COUNT);
    metrics[OM_MAX_ACCOUNT_PROFIT] = g_testMaxAccountProfit;
    metrics[OM_MAX_ACCOUNT_LOSS] = g_testMaxAccountLoss;
    metrics[OM_WORST_BASKET_LOSS] = g_testWorstBasketLoss;
    metrics[OM_MAX_EQUITY_DD] = g_testMaxEquityDrawdown;
    metrics[OM_MAX_EQUITY_DD_PCT] = g_testMaxEquityDrawdownPct;
    metrics[OM_LONGEST_BASKET_HOLD_SEC] = maxHoldSec;
    metrics[OM_AVG_BASKET_HOLD_SEC] = avgHoldSec;
    metrics[OM_MAX_EXTREME_Z_SEC] = maxExtremeSec;
    metrics[OM_AVG_EXTREME_Z_SEC] = avgExtremeSec;
    metrics[OM_SHARPE] = sharpe;
    metrics[OM_NET_PROFIT] = netProfit;
    metrics[OM_PROFIT_FACTOR] = profitFactor;
    metrics[OM_BASKET_COUNT] = (double)observedBasketCount;
    metrics[OM_EXTREME_EPISODE_COUNT] = (double)extremeCount;
    metrics[OM_ACTIVE_BASKET_AGE_SEC] = activeBasketAgeSec;

    // 只在优化Pass中发送Frame。单次测试时OnTester返回综合Score。
    if((bool)MQLInfoInteger(MQL_OPTIMIZATION))
    {
        if(!FrameAdd(OPT_FRAME_NAME, OPT_FRAME_ID, score, metrics))
            Print("⚠️ FrameAdd失败，错误=", GetLastError());
    }

    // 在Strategy Tester中选择“Custom max”时，按综合Score排序。
    return score;
}

//+------------------------------------------------------------------+
//| 优化帧收集模式初始化                                              |
//+------------------------------------------------------------------+
int OnTesterInit()
{
    // 本轮研究目标固定：OLS residual + M15/M30，寻找三个参数的最佳组合。
    // ParameterSetRange会覆盖Strategy Tester里旧的勾选/范围，减少误跑无关参数。
    bool ok = true;

    // 固定OLS，不优化Spread模型。
    ok = ParameterSetRange("InpSpreadModel", false,
                            (long)SPREAD_OLS_LOG_RESIDUAL, 0, 0, 0) && ok;

    // 周期只测试 M15 / M30。
    ok = ParameterSetRange("InpTimeFrame", true,
                            (long)OPT_TF_M15,
                            (long)OPT_TF_M15, 1, (long)OPT_TF_M30) && ok;

    // 三个核心寻优参数：共 7 × 5 × 4 × 2 = 280 个完整组合。
    ok = ParameterSetRange("InpZScoreOpen", true, 2.0, 1.50, 0.25, 3.00) && ok;
    ok = ParameterSetRange("InpAddZStep", true, 1.0, 0.50, 0.25, 1.50) && ok;
    ok = ParameterSetRange("InpAddLotStep", true, 0.01, 0.00, 0.01, 0.03) && ok;

    // 其余数值/枚举/布尔参数全部固定，避免旧.set或UI勾选把搜索空间意外扩大。
    ok = ParameterSetRange("InpRegressionLookBack", false, (long)InpRegressionLookBack, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpTradeMode", false, (long)MODE_BOTH, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpLookBack", false, (long)InpLookBack, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpZScoreClose", false, InpZScoreClose, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpEnableScaleIn", false, (long)true, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpMaxAddCount", false, (long)InpMaxAddCount, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpMinAddIntervalSec", false, (long)InpMinAddIntervalSec, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpMaxAbsZ", false, InpMaxAbsZ, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpMaxTotalBaseLots", false, InpMaxTotalBaseLots, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpMaxMarginUsagePct", false, InpMaxMarginUsagePct, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpRequireProfitClose", false, (long)InpRequireProfitClose, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpMinBasketProfit", false, InpMinBasketProfit, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpEndOfDayRequireReversion", false, (long)InpEndOfDayRequireReversion, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpLots", false, InpLots, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpMagicNumber", false, (long)InpMagicNumber, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpSymbol1LotSize", false, InpSymbol1LotSize, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpSymbol2LotSize", false, InpSymbol2LotSize, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpCoolDownMinutes", false, InpCoolDownMinutes, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpEarliestHour", false, (long)InpEarliestHour, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpLatestHour", false, (long)InpLatestHour, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpCloseAtHour", false, (long)InpCloseAtHour, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpSlippage", false, (long)InpSlippage, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpMaxRetries", false, (long)InpMaxRetries, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpRetryDelay", false, (long)InpRetryDelay, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpEnableSmartClose", false, (long)InpEnableSmartClose, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpCloseProfitFirst", false, (long)InpCloseProfitFirst, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpExtremeZThreshold", false, InpExtremeZThreshold, 0.0, 0.0, 0.0) && ok;
    ok = ParameterSetRange("InpExportOptimizationCSV", false, (long)InpExportOptimizationCSV, 0, 0, 0) && ok;
    ok = ParameterSetRange("InpDebugPrint", false, (long)false, 0, 0, 0) && ok; // 优化时关闭大量日志，提高速度

    if(!ok)
    {
        Print("❌ OnTesterInit设置优化范围失败，error=", GetLastError());
        return INIT_FAILED;
    }

    Print("✅ v10.1优化范围已锁定：OLS | M15/M30 | ZOpen 1.50-3.00 | AddZStep 0.50-1.50 | AddLotStep 0.00-0.03 | 280组合");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 完成优化后导出每个参数组合的自定义指标CSV                         |
//+------------------------------------------------------------------+
void OnTesterDeinit()
{
    // v10.1寻优版强制导出结果表，避免旧.set把该开关设为false后丢失评估表。
    int handle = FileOpen(InpOptimizationCsvName,
                          FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON,
                          ',');
    if(handle == INVALID_HANDLE)
    {
        Print("❌ 无法创建优化指标CSV: ", InpOptimizationCsvName,
              " | error=", GetLastError());
        return;
    }

    FileWrite(handle,
              "Pass",
              "SpreadModel",
              "TimeFrame",
              "LookBack",
              "RegressionLookBack",
              "ZScoreOpen",
              "ZScoreClose",
              "AddZStep",
              "MaxAddCount",
              "AddLotStep",
              "BaseLots",
              "MinBasketProfit",
              "ExtremeZThreshold",
              "NetProfit",
              "Sharpe",
              "ProfitFactor",
              "MaxAccountProfit",
              "MaxAccountLoss",
              "WorstBasketLoss",
              "MaxEquityDrawdown",
              "MaxEquityDrawdownPct",
              "LongestBasketHoldHours",
              "AvgBasketHoldHours",
              "MaxExtremeZHours",
              "AvgExtremeZHours",
              "BasketCountObserved",
              "ExtremeZEpisodeCount",
              "ActiveBasketAgeHoursAtEnd",
              "Score");

    if(!FrameFilter(OPT_FRAME_NAME, OPT_FRAME_ID))
    {
        Print("⚠️ 未找到优化指标Frame，CSV仅写入表头。error=", GetLastError());
        FileClose(handle);
        return;
    }

    ulong pass = 0;
    string frameName = "";
    long frameId = 0;
    double customValue = 0.0;
    double metrics[];

    while(FrameNext(pass, frameName, frameId, customValue, metrics))
    {
        if(frameName != OPT_FRAME_NAME || frameId != OPT_FRAME_ID)
            continue;
        if(ArraySize(metrics) < OM_METRIC_COUNT)
            continue;

        string parameters[];
        uint parametersCount = 0;
        if(!FrameInputs(pass, parameters, parametersCount))
            parametersCount = 0;

        string spreadRaw = FindFrameInputValue(parameters, parametersCount, "InpSpreadModel");
        string tfRaw = FindFrameInputValue(parameters, parametersCount, "InpTimeFrame");
        string spreadName = FrameSpreadModelName(spreadRaw);
        if(spreadName == "" || spreadName == spreadRaw)
            spreadName = "OLS_LOG_RESIDUAL";

        FileWrite(handle,
                  (long)pass,
                  spreadName,
                  FrameTimeFrameName(tfRaw),
                  FindFrameInputValue(parameters, parametersCount, "InpLookBack"),
                  FindFrameInputValue(parameters, parametersCount, "InpRegressionLookBack"),
                  FindFrameInputValue(parameters, parametersCount, "InpZScoreOpen"),
                  FindFrameInputValue(parameters, parametersCount, "InpZScoreClose"),
                  FindFrameInputValue(parameters, parametersCount, "InpAddZStep"),
                  FindFrameInputValue(parameters, parametersCount, "InpMaxAddCount"),
                  FindFrameInputValue(parameters, parametersCount, "InpAddLotStep"),
                  FindFrameInputValue(parameters, parametersCount, "InpLots"),
                  FindFrameInputValue(parameters, parametersCount, "InpMinBasketProfit"),
                  FindFrameInputValue(parameters, parametersCount, "InpExtremeZThreshold"),
                  DoubleToString(metrics[OM_NET_PROFIT], 2),
                  DoubleToString(metrics[OM_SHARPE], 6),
                  DoubleToString(metrics[OM_PROFIT_FACTOR], 6),
                  DoubleToString(metrics[OM_MAX_ACCOUNT_PROFIT], 2),
                  DoubleToString(metrics[OM_MAX_ACCOUNT_LOSS], 2),
                  DoubleToString(metrics[OM_WORST_BASKET_LOSS], 2),
                  DoubleToString(metrics[OM_MAX_EQUITY_DD], 2),
                  DoubleToString(metrics[OM_MAX_EQUITY_DD_PCT], 4),
                  DoubleToString(metrics[OM_LONGEST_BASKET_HOLD_SEC] / 3600.0, 4),
                  DoubleToString(metrics[OM_AVG_BASKET_HOLD_SEC] / 3600.0, 4),
                  DoubleToString(metrics[OM_MAX_EXTREME_Z_SEC] / 3600.0, 4),
                  DoubleToString(metrics[OM_AVG_EXTREME_Z_SEC] / 3600.0, 4),
                  (long)metrics[OM_BASKET_COUNT],
                  (long)metrics[OM_EXTREME_EPISODE_COUNT],
                  DoubleToString(metrics[OM_ACTIVE_BASKET_AGE_SEC] / 3600.0, 4),
                  DoubleToString(customValue, 6));
    }

    FileClose(handle);

    string fullPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) +
                      "\\Files\\" + InpOptimizationCsvName;
    Print("✅ 优化指标CSV已导出: ", fullPath);
}

//+------------------------------------------------------------------+
//| 方向文字                                                         |
//+------------------------------------------------------------------+
string DirectionToString(ENUM_PAIR_DIRECTION direction)
{
    if(direction == PAIR_DIR_SHORT_SPREAD)
        return "SHORT_SPREAD (Sell S1 / Buy S2)";
    if(direction == PAIR_DIR_LONG_SPREAD)
        return "LONG_SPREAD (Buy S1 / Sell S2)";
    return "NONE";
}

//+------------------------------------------------------------------+
//| 返回码描述                                                       |
//+------------------------------------------------------------------+
string GetRetcodeDescription(uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:           return "重报价";
        case TRADE_RETCODE_REJECT:            return "请求拒绝";
        case TRADE_RETCODE_CANCEL:            return "取消";
        case TRADE_RETCODE_PLACED:            return "挂单成功";
        case TRADE_RETCODE_DONE:              return "订单完成";
        case TRADE_RETCODE_DONE_PARTIAL:      return "部分成交";
        case TRADE_RETCODE_ERROR:             return "执行错误";
        case TRADE_RETCODE_TIMEOUT:           return "超时";
        case TRADE_RETCODE_INVALID:           return "无效参数";
        case TRADE_RETCODE_INVALID_VOLUME:    return "无效手数";
        case TRADE_RETCODE_INVALID_PRICE:     return "无效价格";
        case TRADE_RETCODE_INVALID_STOPS:     return "无效止损";
        case TRADE_RETCODE_TRADE_DISABLED:    return "交易禁用";
        case TRADE_RETCODE_MARKET_CLOSED:     return "市场关闭";
        case TRADE_RETCODE_NO_MONEY:          return "资金不足";
        case TRADE_RETCODE_PRICE_CHANGED:     return "价格变化";
        case TRADE_RETCODE_PRICE_OFF:         return "价格偏离";
        case TRADE_RETCODE_TOO_MANY_REQUESTS: return "请求过多";
        default:                              return "未知错误(" + IntegerToString(retcode) + ")";
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

    string info = "\n=== Z-Score Basket阶梯配对 v10.1 ===";
    info += "\n周期: " + timeFrameStr + " Z回看: " + IntegerToString(LookBack_Period);
    if(SpreadModel == SPREAD_SMA_RELATIVE)
        info += "\nSpread: ln(S1/SMA1)-ln(S2/SMA2)";
    else
        info += "\nSpread: OLS log残差  RegLookBack=" + IntegerToString(RegressionLookBack);
    info += "\n首仓: |Z|≥" + DoubleToString(ZScore_Open, 2) + "  回归: ±" + DoubleToString(ZScore_Close, 2);
    info += "\n加仓: ";
    info += (EnableScaleIn ? "ON" : "OFF");
    info += " ZStep=" + DoubleToString(AddZStep, 2) + " Max=" + IntegerToString(MaxAddCount);
    info += " LotStep=" + DoubleToString(AddLotStep, 4);
    info += "\n盈利平仓: ";
    info += (RequireProfitClose ? "ON" : "OFF");
    info += " Min=" + DoubleToString(MinBasketProfit, 2);
    info += "\n冷却: " + DoubleToString(CoolDownMinutes, 0) + "分钟  滑点: " + IntegerToString(Slippage);
    info += "\n--------------------------------";
    info += "\n" + Symbol1 + ": " + DoubleToString(price1, 2) + "  " + Symbol2 + ": " + DoubleToString(price2, 2);
    info += "\n价差: " + DoubleToString(logSpread, 6);
    if(SpreadModel == SPREAD_OLS_LOG_RESIDUAL)
    {
        info += "\nOLS α=" + DoubleToString(regressionAlpha, 6) +
                " β=" + DoubleToString(regressionBeta, 4) +
                " R²=" + DoubleToString(regressionR2, 4);
    }

    if(histCount >= LookBack_Period)
    {
        info += "\n均值: " + DoubleToString(meanValue, 6) + " 标准差: " + DoubleToString(stdValue, 6);
        info += "\nZ-Score: " + DoubleToString(zscore, 2);
        info += "\n--------------------------------";

        int positions1 = CountPositionsForSymbol(Symbol1);
        int positions2 = CountPositionsForSymbol(Symbol2);
        info += "\n" + Symbol1 + "持仓: " + IntegerToString(positions1) +
                "  " + Symbol2 + "持仓: " + IntegerToString(positions2);

        if(g_pairActive)
        {
            info += "\nBasket: " + DirectionToString(g_pairDirection);
            info += "\nLevel: " + IntegerToString(g_addCount + 1) +
                    " (已加仓" + IntegerToString(g_addCount) + "次)";
            info += "\nEntryZ: " + DoubleToString(g_initialEntryZ, 2) +
                    "  LastAddZ: " + DoubleToString(g_lastAddZ, 2);
            info += "\n回归状态: ";
            info += (g_reversionReached ? "已到达" : "未到达");
            info += "\nBasket净值: " + DoubleToString(GetBasketNetProfit(), 2);

            if(EnableScaleIn && !g_reversionReached && g_addCount < MaxAddCount && g_pairDirection != PAIR_DIR_NONE)
            {
                double nextZ = (g_pairDirection == PAIR_DIR_SHORT_SPREAD ? g_lastAddZ + AddZStep : g_lastAddZ - AddZStep);
                info += "\n下一加仓Z: " + DoubleToString(nextZ, 2);
            }
        }
        else if(inCoolDown && lastCloseTime > 0)
        {
            double minutesLeft = CoolDownMinutes - ((TimeCurrent() - lastCloseTime) / 60.0);
            info += "\n⏳ 冷却中 " + DoubleToString(MathMax(0.0, minutesLeft), 1) + "分钟";
        }
        else if(MathAbs(zscore) >= ZScore_Open)
        {
            info += IsTradeTimeAllowed() ? "\n🎯 满足首仓!" : "\n⏰ 满足但不在开仓时间";
        }
    }
    else
    {
        info += "\n数据收集中: " + IntegerToString(histCount) + "/" + IntegerToString(LookBack_Period);
    }

    info += "\n==================================";
    Comment(info);
}

//+------------------------------------------------------------------+
//| 去初始化函数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_pairActive)
        SaveBasketState();
    if(lastCloseTime > 0)
        SaveCoolDownState();

    Comment("");
    Print("EA去初始化完成，原因: ", reason);
}
//+------------------------------------------------------------------+
