# 后续研究路线图

## P0：必须先做

### 1. 连续跨年验证

固定 A/B/C 不变：

- 2024-01-01 ~ 2025-12-31 连续回测
- 2023 单年
- 2022 单年（如有数据）

目的：确认单年切片末尾活动 Basket 在后续年份如何收场，并识别 A 的 regime sensitivity 是否可复现。

### 2. 尾部 Basket 风险

当前 B/C 在 2024/2025 的最长持仓约 101~116 天，A 2024 达到约 361 天。优先测试：

- MaxBasketAge 15/30/45 天后禁止继续加仓；
- 持仓超过阈值后，逐步放宽 `MinBasketProfit`，允许盈亏平衡或有限小亏退出；
- 记录每个 Basket 的实际最大加仓层数；
- 独立统计时间型退出造成的 realized tail loss。

### 3. 账户级风险限制

当前：

- `InpMaxTotalBaseLots = 0`（禁用）
- `InpMaxMarginUsagePct = 0`（禁用）

部署前必须基于账户规模启用，并做保证金压力测试。

## P1：稳定性研究

### MaxAbsZ 敏感性

固定 A/B/C，测试 10 / 15 / 20 / 30，隔离 v10.4 到 v10.6 的风险口径变化。

### LookBack 稳健性

先同步测试：

- Regression/Z = 45/45
- 60/60
- 90/90

若差异明显，再拆开两个窗口交叉。

### 交易成本压力

提高：spread、slippage、commission。重点关注年度 PF 约 1.1~1.3 的时期是否仍能盈利。

### 风险归一化比较

让 A/B/C 在相近最大总手数、保证金使用或风险预算下对比收益，区分“信号质量”与“只是仓位更大”。

## P2：结构升级

### Hedge ratio

当前 OLS beta 只用于 residual signal，仓位按名义金额匹配。可测试：

- OLS beta neutral
- dollar neutral
- volatility neutral

### Regime filter

A 可能只适合强均值回归环境。可研究不含未来信息的市场状态过滤器，让 A 条件启用、B/C 常驻。

### Walk-forward

重新定义：开发期 → 验证期 → 真正 OOS，并用滚动窗口检验参数稳定性。

## 当前不建议做的事

- 不建议继续在同一长历史区间细调 OpenZ/AddZ/LotStep 追最高 Score。
- 不建议因为单次全年净利润高就放大风险。
- 不建议把 2024/2025 称为严格 OOS。
