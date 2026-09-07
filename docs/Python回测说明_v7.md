# Pair Basket Scale-In v7.0 — Python 回测说明

对应脚本：`pair_basket_backtest_v7.py`

本 Python 版本用于本地历史数据研究，策略逻辑来源于 MT5 v7.0 版本：

- Spread：`ln(P1 / SMA1) - ln(P2 / SMA2)`
- `Z >= +OpenZ`：做空 Spread（Sell S1 + Buy S2）
- `Z <= -OpenZ`：做多 Spread（Buy S1 + Sell S2）
- 偏离继续扩大时，以上一次成功加仓的 Z 为锚点，每隔 `AddZStep` 增加一层
- 一个输入数据行最多加一层
- 一旦触及回归条件，停止继续加仓
- 正常退出：先发生回归，再等待整个 Basket 达到最低盈利阈值
- 整个 Basket 平仓后才进入冷却期

> 注意：MT5 EA 是 `OnTick()` 驱动；Python 脚本是“每一行输入数据评估一次”。因此如果输入 1 分钟或 tick-like 数据，并设置 `analysis_timeframe_minutes=15`，会比直接用 M15 收盘价更接近实盘 EA。只有 M15 bar 数据时，结果是 bar 级近似。

---

## 1. 需要安装的 Python 包

```bash
pip install pandas numpy
```

推荐 Python 3.10+。

---

## 2. 输入数据格式

### 最简格式（推荐先这样跑）

一个 CSV 同时放两个品种，并按时间对齐：

```csv
time,USTEC_close,US2000_close
2026-01-02 14:30:00,20125.4,2210.8
2026-01-02 14:31:00,20128.1,2211.2
2026-01-02 14:32:00,20120.7,2210.1
```

必需列：

| 列 | 含义 |
|---|---|
| `time` | 时间戳 |
| `USTEC_close` | 品种1在该时点的最新价格/收盘价 |
| `US2000_close` | 品种2在该时点的最新价格/收盘价 |

列名不是固定的，可以在脚本顶部配置区改：

```python
time_col = "time"
s1_close_col = "USTEC_close"
s2_close_col = "US2000_close"
```

### 可选：直接提供真实 Bid / Ask

如果本地数据有 Bid/Ask，可增加：

```csv
time,USTEC_close,US2000_close,USTEC_bid,USTEC_ask,US2000_bid,US2000_ask
2026-01-02 14:30:00,20125.4,2210.8,20124.9,20125.9,2210.6,2211.0
```

并在配置区设置：

```python
s1_bid_col = "USTEC_bid"
s1_ask_col = "USTEC_ask"
s2_bid_col = "US2000_bid"
s2_ask_col = "US2000_ask"
```

如果保持 `None`，脚本会用：

```text
Bid = close - spread / 2
Ask = close + spread / 2
```

合成报价。

---

## 3. 两个品种原本是两个 CSV 怎么处理

脚本当前采用“宽表”输入，即一个时间戳一行、两个品种价格并列。

例如原数据：

`USTEC.csv`

```csv
time,close
...
```

`US2000.csv`

```csv
time,close
...
```

可先用 pandas 合并：

```python
import pandas as pd

s1 = pd.read_csv("USTEC.csv")
s2 = pd.read_csv("US2000.csv")

s1 = s1.rename(columns={"close": "USTEC_close"})
s2 = s2.rename(columns={"close": "US2000_close"})

pair = s1.merge(s2, on="time", how="inner")
pair.to_csv("pair_data.csv", index=False)
```

如果两个市场时间不完全一致，应先统一时区和时间粒度，再合并。

---

## 4. 时间格式与时区

配置：

```python
input_timezone = "UTC"
```

如果 CSV 时间没有时区信息，脚本会把它当作这里指定的时区，再转换为 UTC。

例如：

```python
input_timezone = "Asia/Shanghai"
```

表示 CSV 里的：

```text
2026-01-02 22:30:00
```

是北京时间。

EA 的：

```python
earliest_hour_gmt
latest_hour_gmt
close_at_hour_gmt
```

全部按转换后的 UTC/GMT 判断。

如果 CSV 时间本身带 `+00:00`、`-05:00` 等 offset，则会直接按原时区解析并转换 UTC。

---

## 5. 分析周期和输入周期

EA 默认：

```python
analysis_timeframe_minutes = 15
```

### 最推荐

使用 1 分钟数据：

```text
输入频率：1 min
分析周期：15 min
```

这样每分钟都会重新计算当前：

```text
P1
P2
logSpread
Z
Basket浮盈亏
```

但 SMA 使用前面已经完成的 15 分钟 bar。

### 只有 M15 数据也可以

直接用 M15：

```python
analysis_timeframe_minutes = 15
```

但每 15 分钟只有一次策略判断，因此无法知道这一根 K 线中间是否：

- 先达到加仓 Z
- 再快速回归
- 盘中达到盈利阈值

所以回测误差会更大。

---

## 6. Z-Score 的 Python 实现方式

Python 版特意没有简单写成常见的：

```python
spread.rolling(20).mean()
```

而是按 EA 的执行顺序模拟。

### SMA

当前价格使用当前输入行价格；SMA 使用前 `N` 个已经完成的分析周期 bar：

```text
ret1 = ln(current_P1 / SMA1_previous_N_bars)
ret2 = ln(current_P2 / SMA2_previous_N_bars)
Spread = ret1 - ret2
```

### Spread 历史

新的分析周期开始时，把当时的 Spread 加入 `diff_history` 一次。

如果输入数据比分析周期细，例如 1m 输入 + M15 分析，那么同一个 15m bar 内：

- `diff_history` 不重复加入
- 当前 `logSpread` 会随最新价格变化
- Z 的 numerator 会变化

这更接近 EA 的 `UpdateHistory()` + `CalculateZScore()` 结构。

### 标准差

使用总体标准差：

```python
std(ddof=0)
```

对应 EA 的：

```text
sqrt(sum((x-mean)^2) / N)
```

---

## 7. 配置参数在哪里

打开：

```text
pair_basket_backtest_v7.py
```

脚本开头约第 49 行开始有：

```python
# 用户配置区：大多数回测参数都在这里修改
@dataclass
class BacktestConfig:
    ...
```

默认实例在：

```python
CONFIG = BacktestConfig()
```

直接修改 `BacktestConfig` 中的默认值即可。

---

## 8. 核心策略参数

### 开仓

```python
lookback = 20
zscore_open = 2.0
zscore_close = 0.0
```

方向：

```text
Z >= +2.0
→ SHORT_SPREAD
→ Sell S1 + Buy S2

Z <= -2.0
→ LONG_SPREAD
→ Buy S1 + Sell S2
```

---

## 9. 阶梯加仓参数

```python
enable_scale_in = True
add_z_step = 0.50
max_add_count = 3
add_lot_multiplier = 1.00
min_add_interval_sec = 60
max_abs_z = 5.0
```

例：首次实际成交：

```text
Z = +2.08
```

则：

```text
下一层：Z >= 2.58
```

假设实际在：

```text
Z = 2.64
```

成交，则新的锚点变成：

```text
LastAddZ = 2.64
```

再下一层：

```text
Z >= 3.14
```

而不是固定使用 2.5 / 3.0 / 3.5。

### 手数倍率

```python
add_lot_multiplier = 1.0
```

则：

```text
Level0 = 0.10
Level1 = 0.10
Level2 = 0.10
Level3 = 0.10
```

若：

```python
add_lot_multiplier = 1.2
```

则理论基础手数：

```text
Level0 = 0.1000
Level1 = 0.1200
Level2 = 0.1440
Level3 = 0.1728
```

实际会再按券商 lot step 标准化。

---

## 10. Symbol2 对冲手数

`trade_mode = "BOTH"` 时，Symbol2 每一层都重新计算：

```text
S2 lots =
S1 lots × S1 contract_size × P1
--------------------------------
S2 contract_size × P2
```

参数：

```python
symbol1_contract_size = 1.0
symbol2_contract_size = 1.0
```

请根据 TMGM 对应品种的真实 contract size 调整，否则盈亏和对冲比例都会失真。

---

## 11. 强制盈利才平仓

配置：

```python
require_profit_close = True
min_basket_profit = 1.0
```

退出分两阶段。

第一阶段：确认回归。

SHORT Spread：

```text
Z <= +zscore_close
```

LONG Spread：

```text
Z >= -zscore_close
```

例如 `zscore_close=0`，就是穿越/到达 0。

第二阶段：

```text
Basket净浮盈 >= min_basket_profit
```

才全部平仓。

一旦发生过回归：

```text
reversion_reached = True
```

即使下一行 Z 再离开 0，也不会重新开始加仓，而是继续等待 Basket 盈利条件。

---

## 12. Basket 浮盈的定义

当前持仓的研究净浮盈近似：

```text
按当前Bid/Ask可平仓价格计算的浮盈亏
+ Swap估算
- 已发生的开仓Commission
- 已发生的开仓Fee
```

这里**尚未提前扣除未来平仓佣金**，与 EA 的设计思想一致，所以：

```python
min_basket_profit
```

应留出一定成交成本缓冲。

真正平仓后的 `realized_net_pnl` 会再扣除：

```text
平仓Commission
平仓Fee
平仓Slippage
```

因此可能出现：

```text
触发前 Basket = +1.2
最终成交 = +0.7
```

甚至如果阈值太小，最终成交后略负。

---

## 13. 点差 / 滑点 / 佣金

### 没有 Bid/Ask 数据

设置：

```python
s1_spread_price = 1.0
s2_spread_price = 0.4
```

单位是实际价格点。

比如 USTEC：

```text
close = 20100
spread = 1.0
```

脚本使用：

```text
bid = 20099.5
ask = 20100.5
```

### 滑点

```python
s1_slippage_price = 0.2
s2_slippage_price = 0.1
```

所有成交都会向不利方向移动。

### 佣金

```python
s1_commission_per_lot_per_side = 2.0
s2_commission_per_lot_per_side = 2.0
```

代表每手、每次买/卖成交收 2 个账户货币单位。

---

## 14. Swap

默认全部是 0：

```python
s1_swap_long_per_lot_day = 0.0
s1_swap_short_per_lot_day = 0.0
s2_swap_long_per_lot_day = 0.0
s2_swap_short_per_lot_day = 0.0
```

Python 版本目前采用简化模型：

```text
每手每天Swap × 持仓天数（连续折算）
```

这不模拟三倍隔夜、特定结算时间等券商规则。如果你要做精确实盘成本回放，需要再按 TMGM 合约规则改。

---

## 15. 冷却期和交易时间

```python
cooldown_minutes = 60.0
earliest_hour_gmt = 1
latest_hour_gmt = 22
close_at_hour_gmt = 23
```

首仓和加仓只有 GMT：

```text
01:00 ~ 22:59
```

允许触发。

整个 Basket 完全平仓后：

```text
60分钟内不允许新首仓
```

---

## 16. 日内清仓

```python
end_of_day_require_reversion = True
close_at_hour_gmt = 23
```

默认：

```text
到了GMT 23点
AND 已经发生过回归
AND Basket满足盈利阈值
→ 平仓
```

如果：

```python
end_of_day_require_reversion = False
```

则日内清仓不再要求 Z 已经回归，但如果 `require_profit_close=True`，仍然要求 Basket 盈利。

---

## 17. 回测结束还有仓位怎么办

默认：

```python
force_close_at_end = False
```

也就是最后一行数据结束以后：

- 不违反“盈利才平仓”的策略
- 未平仓继续保留在 `open_positions.csv`
- 最终 `equity` 使用最后价格做 MTM
- `realized_pnl` 不包含这些未平仓

如果只是为了封闭样本统计，可设置：

```python
force_close_at_end = True
```

这会忽略正常退出条件，在数据最后一行强制平掉剩余仓位。

这种结果必须和正常策略回测分开看。

---

## 18. 指标预热与正式测试起点

从“全新启动 EA”角度，指标需要：

1. 先形成 `lookback` 个完成的分析 bar，用于 SMA；
2. 再积累 `lookback` 个 Spread 历史，用于 Z。

因此如果：

```python
lookback = 20
analysis_timeframe_minutes = 15
```

最好在正式测试日期前多提供至少数小时/数天数据。

可以设置：

```python
signal_start_time = "2026-01-01 00:00:00+00:00"
```

这样：

- 更早数据只用来预热
- 到指定时间以后才允许首仓/加仓

推荐做参数比较时都使用固定 `signal_start_time`，避免不同数据切片导致 warm-up 差异。

---

## 19. 运行方式

### 方法 A：直接改脚本配置

把数据放为：

```text
pair_data.csv
```

然后：

```bash
python pair_basket_backtest_v7.py
```

### 方法 B：命令行覆盖输入/输出路径

```bash
python pair_basket_backtest_v7.py \
  --data D:/data/us_index_pair.csv \
  --output D:/data/result_v7
```

命令行只覆盖文件路径，其余参数仍使用脚本顶部 `BacktestConfig`。

---

## 20. 输出文件

默认输出目录：

```text
backtest_output/
```

### `events.csv`

策略事件：

```text
OPEN
ADD
REVERSION
CLOSE
```

可以直接检查每次：

- Z 是多少
- 在哪一层加仓
- 加仓锚点怎么变化
- 哪一刻确认回归
- 哪一刻盈利退出

### `closed_legs.csv`

每一条腿的成交明细：

- Basket ID
- Symbol
- BUY / SELL
- Level
- 手数
- 开仓时间
- 平仓时间
- 开仓价
- 平仓价
- Gross PnL
- Swap
- Commission
- Fee
- Net PnL

### `baskets.csv`

最适合研究策略参数：

- Basket开始/结束
- 初始 Z
- 退出 Z
- 加仓次数
- 总层数
- 最大 `|Z|`
- 持仓期最低 Basket 浮盈
- 持仓期最高 Basket 浮盈
- 平仓前净浮盈
- 最终实现净利润
- 平仓原因

### `equity.csv`

每一输入行的：

- P1 / P2
- SMA1 / SMA2
- Spread
- Z
- Basket状态
- 当前加仓次数
- 是否已回归
- Basket浮盈
- 已实现收益
- Equity
- 估算保证金
- Drawdown 可据此计算

### `open_positions.csv`

数据结束时仍未平仓的腿。

### `config_used.csv`

本次实际使用的全部配置，方便参数回测备案。

---

## 21. 保证金保护的限制

参数：

```python
max_margin_usage_pct = 0.0
leverage = 20.0
```

如果启用，Python 采用简化估算：

```text
Margin ≈ Σ(手数 × contract_size × 当前价格) / leverage
```

而 MT5 的真实：

```text
ACCOUNT_MARGIN
```

由券商合约规格、指数CFD保证金率、账户类型等决定。

所以：

> Python 的保证金过滤适合做“相对比较”，不应用来代替 TMGM 实盘保证金计算。

---

## 22. 当前 Python 回测与真实 EA 的主要差异

必须注意以下差异：

1. **成交频率**：Python 每输入行判断一次；MT5 每 Tick 判断。
2. **Bid/Ask**：没有真实报价时只能根据固定 spread 合成。
3. **滑点**：Python 用固定不利滑点；MT5 是真实成交结果。
4. **部分成交/拒单**：Python 研究版默认订单都完整成交；MT5 v7.0 有第二腿失败回滚。
5. **保证金**：Python 是估算模型。
6. **Swap**：Python 当前是连续天数简化模型。
7. **Smart Close 顺序**：Python 同一输入行平两腿，因此“先盈利腿/先亏损腿”不会产生真实毫秒级价格差。
8. **M15 bar-only 数据**：不能重现一根 M15 内先加仓后回归的路径。

因此建议研究顺序：

```text
M15数据快速扫参数
        ↓
1分钟数据筛选参数
        ↓
Tick/Bid-Ask数据验证
        ↓
MT5 Strategy Tester / Demo验证
```

---

## 23. 第一轮建议测试参数组

建议暂时保持手数不递增，先测试 Z 间距本身：

```python
lookback = 20
zscore_open = 2.0
zscore_close = 0.0

base_lots = 0.10
add_lot_multiplier = 1.0
max_add_count = 3

# 分别跑：
add_z_step = 0.3
add_z_step = 0.5
add_z_step = 0.8
add_z_step = 1.0
```

重点比较 `baskets.csv`：

```text
realized_net_pnl
min_net_profit_seen
max_abs_z
add_count
duration_hours
```

尤其不要只比较最终总利润。

连续逆势加仓策略最重要的比较维度通常是：

```text
收益
vs
最大Basket浮亏
vs
最大总仓位
vs
回归等待时间
```

---

## 24. 一条很重要的回测解释

“加仓降低成本、减少回归所需距离”不等于“缩短市场真实回归时间”。

加仓真正改变的是：

```text
Basket整体盈亏平衡点
```

所以回测时建议重点看：

- 首仓以后最大 Z 去到哪里
- 加了几层
- Basket 最低浮亏
- 从最后一次加仓到盈利平仓用了多久
- 不加仓版本在同一行情下需要多久才能盈利

这几个数据组合起来，才能判断阶梯加仓有没有真正改善策略，而不是单纯把尾部风险延后。
