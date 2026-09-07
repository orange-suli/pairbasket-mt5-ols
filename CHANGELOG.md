# Changelog

## v10.6 — A/B/C 时间切片基线

- 固定 OLS residual + M15。
- 将 A/B/C 三套候选封装为策略预设。
- 固定 MaxAdd=7。
- A 使用 CloseZ=0；B/C 使用 CloseZ=1。
- MaxAbsZ=30。
- 优化仅枚举三套预设，用于年度/跨年度稳定性测试。

## v10.5 — MaxAdd / CloseZ 验证

- A/B/C × MaxAdd(7/9/11) × CloseZ(0/0.5/1) 共 27 组。
- 为允许高层加仓，将 MaxAbsZ 从 10 提高到 30。
- 结论：MaxAdd=7 足够；A 保持 Close0；B/C Close1 改善平均持仓效率。

## v10.4 — M15 36 组缩圈

- OpenZ：3.0 / 3.5 / 4.0 / 4.5。
- AddZ：1.0 / 1.5 / 2.0。
- AddLotStep：0.02 / 0.03 / 0.04。
- 发现高收益峰 3/1/.04，以及高质量区域 4.5/2/.03~.04。

## v10.1 — OLS M15/M30 Score 优化

- 固定 OLS residual。
- 引入综合 Score。
- 约 120 组网格后确认 M15 与 M30 最优区域不同，后续主攻 M15。

## v10.0 — 双 Spread 与风险指标

- 新增 rolling OLS log residual Spread。
- 新增 MaxAccountProfit/Loss、WorstBasketLoss、MaxDD、持仓时间、ExtremeZ、Sharpe 等优化指标。

## v9.1 — 线性阶梯加仓

- 将倍数/指数型加仓改为 `BaseLots + N * AddLotStep`。
- 加入 M15/M30/H1 可优化周期枚举。

## v7.0 — Basket 状态机

- 统一 Z 正负方向。
- 增加多层 Basket 阶梯加仓。
- 回归后且 Basket 盈利才整组退出。
- 增加失败回滚、冷却、重启状态恢复等。

## v6.1 — 原始基线

- SMA-relative Spread。
- 单次开仓/简单回归退出。
