# MT5 回测与时间切片操作指南

## 当前主入口

`src/PairBasket_v10_6_OLS_M15_3Preset_2025_TimeSlice.mq5`

当前版本固定：OLS residual、M15、RegressionLookBack=60、Z LookBack=60、MaxAdd=7、MaxAbsZ=30。优化时只枚举 A/B/C 三套预设。

## 三套预设

| Preset | OpenZ | CloseZ | AddZ | LotStep | MaxAdd |
|---|---:|---:|---:|---:|---:|
| A | 3.0 | 0.0 | 1.0 | 0.04 | 7 |
| B | 4.5 | 1.0 | 2.0 | 0.03 | 7 |
| C | 4.5 | 1.0 | 2.0 | 0.04 | 7 |

## 编译

1. MT5 → File → Open Data Folder。
2. 把 MQ5 放到 `MQL5/Experts/`。
3. 用该 MT5 实例启动的 MetaEditor 打开并 F7 编译。
4. 确认 `0 errors`，并检查 EX5 时间戳。
5. Navigator → Expert Advisors → Refresh。

如果 Strategy Tester 仍显示旧输入参数，通常是旧 EX5、另一个 MT5 Data Folder 或 Tester 缓存导致；可给 EA 改唯一文件名并重新编译。

## 时间切片

建议保持参数完全不变，只改日期：

- 已完成：2024、2025
- 下一步：2024-01-01 ~ 2025-12-31 连续两年
- 然后：2023、2022（如数据可用）

注意：单年切片末尾可能仍有活动 Basket，所以单年结果存在边界效应。必须结合 `ActiveBasketAgeHoursAtEnd` 与连续跨年测试判断。

## 优化设置

- Optimization：Slow complete algorithm / 完成优化
- 只有 `InpStrategyPreset` 参与枚举，共 3 Pass
- 测试模型优先使用真实 ticks（若券商历史支持）
- 不要把旧 `.set` 中的其他优化范围误带入；当前源码的 `OnTesterInit()` 会固定非预设参数

## 核心评价字段

- NetProfit
- Sharpe
- ProfitFactor
- MaxAccountProfit / MaxAccountLoss
- WorstBasketLoss
- MaxEquityDrawdownPct
- LongestBasketHoldHours
- AvgBasketHoldHours
- BasketCountObserved
- ActiveBasketAgeHoursAtEnd
- Score

## CSV 位置

EA 使用 `FILE_COMMON` 写入优化结果。常见目录：

`%APPDATA%/MetaQuotes/Terminal/Common/Files/`

实际路径以 MT5 Journal 打印为准。

## 结果解读优先级

不要只按 Score 排名。对于当前策略，至少同时看：

1. 是否跨多个独立时期保持正收益；
2. Sharpe / PF 是否稳定；
3. 最大回撤；
4. Worst Basket；
5. 最长持仓和测试末尾活动 Basket；
6. Basket 数量是否足够；
7. 交易成本变化后是否仍有优势。
