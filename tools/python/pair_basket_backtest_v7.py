#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pair Basket Scale-In v7.0 - Python Backtester
=============================================

This script is a research/backtest translation of the MT5 EA:
TMGM20260820PairUSIndex_BasketScaleIn_v7.0.mq5

Core strategy preserved:
1) Spread = ln(P1 / SMA1) - ln(P2 / SMA2)
2) Z > +OpenZ  -> SHORT spread: SELL S1 + BUY S2
   Z < -OpenZ  -> LONG  spread: BUY  S1 + SELL S2
3) If deviation continues by AddZStep from the last successful add Z,
   add one new level (at most one level per input row).
4) Once reversion threshold has been touched, stop adding.
5) Normal exit only after reversion has occurred AND basket net floating P/L
   reaches MinBasketProfit (unless require_profit_close=False).
6) Cooldown starts only after the whole basket is closed.

IMPORTANT BACKTEST NOTE
-----------------------
MT5 evaluates OnTick while this script evaluates each input row. If your input
is 1-minute or tick-like data and analysis_timeframe_minutes=15, the behavior
is much closer to the live M15 EA. If you only provide M15 close bars, results
are a bar-level approximation and cannot reproduce intrabar triggers/slippage.

Run:
    python pair_basket_backtest_v7.py
or override paths:
    python pair_basket_backtest_v7.py --data my_pair.csv --output out_dir

See the companion README for the CSV schema and parameter explanations.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass, asdict
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd


# ============================================================================
# 用户配置区：大多数回测参数都在这里修改
# ============================================================================
@dataclass
class BacktestConfig:
    # ---------- 文件 / 列名 ----------
    data_path: str = "pair_data.csv"
    output_dir: str = "backtest_output"
    time_col: str = "time"
    s1_close_col: str = "USTEC_close"
    s2_close_col: str = "US2000_close"

    # 可选：如果CSV直接提供Bid/Ask，填写列名；否则保持None，用spread参数合成。
    s1_bid_col: Optional[str] = None
    s1_ask_col: Optional[str] = None
    s2_bid_col: Optional[str] = None
    s2_ask_col: Optional[str] = None

    # CSV时间的时区。无时区时间会按这里本地化，然后统一转UTC/GMT。
    # 常用："UTC"、"Asia/Shanghai"、"America/New_York"。
    input_timezone: str = "UTC"

    # 分析周期。EA原版默认M15。
    # 输入可比分析周期更细，例如1分钟数据 + 15分钟分析周期。
    analysis_timeframe_minutes: int = 15

    # ---------- 品种 / 交易模式 ----------
    symbol1: str = "USTEC"
    symbol2: str = "US2000"
    trade_mode: str = "BOTH"  # BOTH / ONLY_S1 / ONLY_S2

    # ---------- 核心Z-Score ----------
    lookback: int = 20
    zscore_open: float = 2.0
    zscore_close: float = 0.0

    # ---------- 阶梯加仓 ----------
    enable_scale_in: bool = True
    add_z_step: float = 0.50
    max_add_count: int = 3
    add_lot_multiplier: float = 1.00
    min_add_interval_sec: int = 60
    max_abs_z: float = 5.0              # <=0 表示禁用
    max_total_base_lots: float = 0.0    # 0 表示禁用
    max_margin_usage_pct: float = 0.0   # 0 表示禁用；Python版为估算值

    # ---------- Basket盈利平仓 ----------
    require_profit_close: bool = True
    min_basket_profit: float = 1.0
    end_of_day_require_reversion: bool = True

    # 与EA一致：只影响两条腿的提交平仓先后。
    # 在单根bar成交模型中，两腿仍按同一输入行价格成交，因此不会改变总PnL。
    enable_smart_close: bool = True
    close_profit_first: bool = True

    # ---------- 资金 / 手数 ----------
    initial_capital: float = 100_000.0
    base_lots: float = 0.10
    symbol1_contract_size: float = 1.0
    symbol2_contract_size: float = 1.0

    # 手数规则（应按券商真实规格修改）
    s1_min_lot: float = 0.01
    s1_max_lot: float = 100.0
    s1_lot_step: float = 0.01
    s2_min_lot: float = 0.01
    s2_max_lot: float = 100.0
    s2_lot_step: float = 0.01

    # ---------- 时间 / 冷却期（全部按UTC/GMT判断） ----------
    cooldown_minutes: float = 60.0
    earliest_hour_gmt: int = 1
    latest_hour_gmt: int = 22
    close_at_hour_gmt: int = 23

    # ---------- 成交成本模型 ----------
    # 若没有Bid/Ask列，则用 close +/- spread/2 合成。
    # 单位是“价格点”，不是MT5 points。例：指数点差1.2，则填1.2。
    s1_spread_price: float = 0.0
    s2_spread_price: float = 0.0

    # 每次成交额外不利滑点，单位同样是价格点。
    s1_slippage_price: float = 0.0
    s2_slippage_price: float = 0.0

    # 每手、每边的佣金/fee，单位为账户货币；填正数代表成本。
    s1_commission_per_lot_per_side: float = 0.0
    s2_commission_per_lot_per_side: float = 0.0
    s1_fee_per_lot_per_side: float = 0.0
    s2_fee_per_lot_per_side: float = 0.0

    # 简化Swap模型：每手每天账户货币，负数代表成本。按持仓时间连续折算。
    s1_swap_long_per_lot_day: float = 0.0
    s1_swap_short_per_lot_day: float = 0.0
    s2_swap_long_per_lot_day: float = 0.0
    s2_swap_short_per_lot_day: float = 0.0

    # ---------- 保证金估算 ----------
    # 仅用于 max_margin_usage_pct 研究过滤，不等同于券商真实保证金规则。
    leverage: float = 20.0

    # ---------- 回测结束处理 ----------
    # False：保留未平仓并按最后价格计算MTM；更符合“盈利才平”的策略语义。
    # True：数据结束时强制平仓，仅用于做封闭样本统计。
    force_close_at_end: bool = False

    # 可选：指标允许用更早数据预热，但在该UTC时间之前不允许交易。
    # 格式如 "2025-01-01 00:00:00+00:00"；None表示从可交易起点开始。
    signal_start_time: Optional[str] = None

    debug: bool = False


CONFIG = BacktestConfig()
# ============================================================================
# 用户配置区结束
# ============================================================================


class PairDirection(Enum):
    NONE = 0
    SHORT_SPREAD = 1   # Sell S1 + Buy S2
    LONG_SPREAD = -1   # Buy S1 + Sell S2


@dataclass
class Position:
    symbol: str
    side: int                 # +1 BUY, -1 SELL
    volume: float
    contract_size: float
    entry_price: float
    open_time: pd.Timestamp
    level: int
    open_commission: float
    open_fee: float


@dataclass
class BasketState:
    basket_id: int
    direction: PairDirection
    start_time: pd.Timestamp
    initial_entry_z: float
    last_add_z: float
    add_count: int = 0
    last_add_time: Optional[pd.Timestamp] = None
    reversion_reached: bool = False
    reversion_time: Optional[pd.Timestamp] = None
    max_abs_z: float = 0.0
    min_net_profit_seen: float = 0.0
    max_net_profit_seen: float = 0.0


class PairBasketBacktester:
    def __init__(self, cfg: BacktestConfig):
        self.cfg = cfg
        self._validate_config()

        self.positions: List[Position] = []
        self.basket: Optional[BasketState] = None
        self.next_basket_id = 1

        self.realized_pnl = 0.0
        self.last_close_time: Optional[pd.Timestamp] = None

        # EA-like analysis state
        self.current_bucket: Optional[pd.Timestamp] = None
        self.current_bucket_last_p1: Optional[float] = None
        self.current_bucket_last_p2: Optional[float] = None
        self.completed_s1: List[float] = []
        self.completed_s2: List[float] = []
        self.diff_history: List[float] = []

        # Outputs
        self.events: List[Dict] = []
        self.closed_legs: List[Dict] = []
        self.basket_results: List[Dict] = []
        self.equity_rows: List[Dict] = []

        self.signal_start_ts = (
            pd.Timestamp(cfg.signal_start_time).tz_convert("UTC")
            if cfg.signal_start_time and pd.Timestamp(cfg.signal_start_time).tzinfo is not None
            else (
                pd.Timestamp(cfg.signal_start_time).tz_localize("UTC")
                if cfg.signal_start_time else None
            )
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def run(self, df: pd.DataFrame) -> Dict[str, pd.DataFrame]:
        last_ctx = None

        cols = ["_time", "_p1", "_p2", "_bid1", "_ask1", "_bid2", "_ask2"]
        for ts, p1, p2, bid1, ask1, bid2, ask2 in df[cols].itertuples(index=False, name=None):
            p1 = float(p1)
            p2 = float(p2)
            bid1 = float(bid1)
            ask1 = float(ask1)
            bid2 = float(bid2)
            ask2 = float(ask2)

            ctx = self._update_indicator_state(ts, p1, p2, bid1, ask1, bid2, ask2)
            last_ctx = ctx

            if ctx["z_valid"]:
                self._update_cooldown(ts)
                self._update_basket_extremes(ctx)

                trading_enabled_by_date = self.signal_start_ts is None or ts >= self.signal_start_ts
                if trading_enabled_by_date:
                    if self.basket is None:
                        if not self._in_cooldown(ts):
                            self._check_open(ctx)
                    else:
                        closed = self._check_close(ctx)
                        if not closed and self.basket is not None:
                            self._check_scale_in(ctx)

                    if self.basket is not None:
                        self._check_end_of_day(ctx)

            self._record_equity(ctx)

        if last_ctx is not None and self.basket is not None and self.cfg.force_close_at_end:
            self._close_current_basket(last_ctx, "数据结束强制平仓", bypass_profit_rule=True)
            # overwrite final equity point after forced close
            self._record_equity(last_ctx, replace_same_timestamp=True)

        return self._build_outputs()

    # ------------------------------------------------------------------
    # Indicator logic: mirrors EA order as closely as row data allows
    # ------------------------------------------------------------------
    def _update_indicator_state(
        self,
        ts: pd.Timestamp,
        p1: float,
        p2: float,
        bid1: float,
        ask1: float,
        bid2: float,
        ask2: float,
    ) -> Dict:
        freq = f"{self.cfg.analysis_timeframe_minutes}min"
        bucket = ts.floor(freq)
        new_bucket = self.current_bucket is None or bucket != self.current_bucket

        if self.current_bucket is None:
            self.current_bucket = bucket
        elif new_bucket:
            # The previous analysis bar becomes completed at the first row of the new bar.
            if self.current_bucket_last_p1 is not None and self.current_bucket_last_p2 is not None:
                self.completed_s1.append(self.current_bucket_last_p1)
                self.completed_s2.append(self.current_bucket_last_p2)
            self.current_bucket = bucket

        self.current_bucket_last_p1 = p1
        self.current_bucket_last_p2 = p2

        ctx = {
            "time": ts,
            "p1": p1,
            "p2": p2,
            "bid1": bid1,
            "ask1": ask1,
            "bid2": bid2,
            "ask2": ask2,
            "new_bucket": new_bucket,
            "sma1": np.nan,
            "sma2": np.nan,
            "log_spread": np.nan,
            "mean": np.nan,
            "std": np.nan,
            "z": np.nan,
            "z_valid": False,
        }

        n = self.cfg.lookback
        if len(self.completed_s1) < n or len(self.completed_s2) < n:
            return ctx

        # Same as EA: SMA uses bars [1..N], i.e. completed bars, excluding current bar.
        sma1 = float(np.mean(self.completed_s1[-n:]))
        sma2 = float(np.mean(self.completed_s2[-n:]))
        if p1 <= 0 or p2 <= 0 or sma1 <= 0 or sma2 <= 0:
            return ctx

        log_spread = math.log(p1 / sma1) - math.log(p2 / sma2)

        # Same as EA UpdateHistory(): append spread only once when a new analysis bar appears.
        # On finer data, later rows in the same bar update the current numerator but not history.
        if new_bucket:
            self.diff_history.append(log_spread)

        ctx.update({"sma1": sma1, "sma2": sma2, "log_spread": log_spread})

        if len(self.diff_history) < n:
            return ctx

        window = np.asarray(self.diff_history[-n:], dtype=float)
        mean = float(window.mean())
        std = float(window.std(ddof=0))  # EA uses population std: divide by N
        z = (log_spread - mean) / std if std > 0 else 0.0

        ctx.update({"mean": mean, "std": std, "z": z, "z_valid": std > 0})
        return ctx

    # ------------------------------------------------------------------
    # Entry / scale in / exit
    # ------------------------------------------------------------------
    def _check_open(self, ctx: Dict) -> None:
        if not self._is_trade_time_allowed(ctx["time"]):
            return

        z = ctx["z"]
        open_z = abs(self.cfg.zscore_open)
        if z >= open_z:
            direction = PairDirection.SHORT_SPREAD
        elif z <= -open_z:
            direction = PairDirection.LONG_SPREAD
        else:
            return

        basket_id = self.next_basket_id
        if self._open_pair_level(ctx, direction, level=0, basket_id=basket_id):
            self.basket = BasketState(
                basket_id=basket_id,
                direction=direction,
                start_time=ctx["time"],
                initial_entry_z=z,
                last_add_z=z,
                add_count=0,
                last_add_time=ctx["time"],
                reversion_reached=False,
                max_abs_z=abs(z),
                min_net_profit_seen=0.0,
                max_net_profit_seen=0.0,
            )
            self.next_basket_id += 1
            self._event(ctx, "OPEN", level=0, details=f"{direction.name}")

    def _check_scale_in(self, ctx: Dict) -> None:
        b = self.basket
        if b is None:
            return
        if not self.cfg.enable_scale_in or b.reversion_reached:
            return
        if b.add_count >= self.cfg.max_add_count:
            return
        if not self._is_trade_time_allowed(ctx["time"]):
            return

        if self.cfg.min_add_interval_sec > 0 and b.last_add_time is not None:
            elapsed = (ctx["time"] - b.last_add_time).total_seconds()
            if elapsed < self.cfg.min_add_interval_sec:
                return

        z = ctx["z"]
        if self.cfg.max_abs_z > 0 and abs(z) >= self.cfg.max_abs_z:
            return

        if self.cfg.max_margin_usage_pct > 0:
            usage = self._estimated_margin_usage_pct(ctx)
            if usage >= self.cfg.max_margin_usage_pct:
                return

        if b.direction == PairDirection.SHORT_SPREAD:
            should_add = z >= b.last_add_z + self.cfg.add_z_step
        else:
            should_add = z <= b.last_add_z - self.cfg.add_z_step
        if not should_add:
            return

        next_level = b.add_count + 1
        level_base_lots = self._level_base_lots(next_level)
        if level_base_lots <= 0:
            return

        if self.cfg.max_total_base_lots > 0:
            base_symbol = self.cfg.symbol2 if self.cfg.trade_mode.upper() == "ONLY_S2" else self.cfg.symbol1
            current_base_volume = self._total_volume(base_symbol)
            if current_base_volume + level_base_lots > self.cfg.max_total_base_lots + 1e-12:
                return

        # At most one add per input row, matching the EA design.
        if self._open_pair_level(ctx, b.direction, next_level, b.basket_id):
            b.add_count += 1
            b.last_add_z = z
            b.last_add_time = ctx["time"]
            self._event(ctx, "ADD", level=next_level, details=f"new_anchor_z={z:.4f}")

    def _check_close(self, ctx: Dict) -> bool:
        b = self.basket
        if b is None:
            return False

        close_z = abs(self.cfg.zscore_close)
        if not b.reversion_reached:
            if b.direction == PairDirection.SHORT_SPREAD and ctx["z"] <= close_z:
                b.reversion_reached = True
                b.reversion_time = ctx["time"]
                self._event(ctx, "REVERSION", details=f"z={ctx['z']:.4f}")
            elif b.direction == PairDirection.LONG_SPREAD and ctx["z"] >= -close_z:
                b.reversion_reached = True
                b.reversion_time = ctx["time"]
                self._event(ctx, "REVERSION", details=f"z={ctx['z']:.4f}")

        if not b.reversion_reached:
            return False

        basket_net = self._basket_net_floating(ctx)
        if self.cfg.require_profit_close and basket_net < self.cfg.min_basket_profit:
            return False

        return self._close_current_basket(ctx, "回归后盈利平仓")

    def _check_end_of_day(self, ctx: Dict) -> None:
        b = self.basket
        if b is None:
            return
        if ctx["time"].hour != self.cfg.close_at_hour_gmt:
            return
        if self.cfg.end_of_day_require_reversion and not b.reversion_reached:
            return
        basket_net = self._basket_net_floating(ctx)
        if self.cfg.require_profit_close and basket_net < self.cfg.min_basket_profit:
            return
        self._close_current_basket(ctx, "日内清仓")

    # ------------------------------------------------------------------
    # Open / close execution model
    # ------------------------------------------------------------------
    def _open_pair_level(
        self, ctx: Dict, direction: PairDirection, level: int, basket_id: int
    ) -> bool:
        mode = self.cfg.trade_mode.upper()
        base_lots = self._level_base_lots(level)
        if base_lots <= 0:
            return False

        if mode == "BOTH":
            s1_lots = self._normalize_volume(self.cfg.symbol1, base_lots)
            if s1_lots <= 0:
                return False

            s2_lots = self._calculate_symbol2_lots(s1_lots, ctx["p1"], ctx["p2"])
            if s2_lots <= 0:
                return False

            side1 = -1 if direction == PairDirection.SHORT_SPREAD else +1
            side2 = +1 if direction == PairDirection.SHORT_SPREAD else -1
            self.positions.append(self._make_position(ctx, self.cfg.symbol1, side1, s1_lots, level))
            self.positions.append(self._make_position(ctx, self.cfg.symbol2, side2, s2_lots, level))
            return True

        if mode == "ONLY_S1":
            s1_lots = self._normalize_volume(self.cfg.symbol1, base_lots)
            side1 = -1 if direction == PairDirection.SHORT_SPREAD else +1
            if s1_lots <= 0:
                return False
            self.positions.append(self._make_position(ctx, self.cfg.symbol1, side1, s1_lots, level))
            return True

        if mode == "ONLY_S2":
            s2_lots = self._normalize_volume(self.cfg.symbol2, base_lots)
            side2 = +1 if direction == PairDirection.SHORT_SPREAD else -1
            if s2_lots <= 0:
                return False
            self.positions.append(self._make_position(ctx, self.cfg.symbol2, side2, s2_lots, level))
            return True

        raise ValueError(f"Unsupported trade_mode={self.cfg.trade_mode}")

    def _make_position(self, ctx: Dict, symbol: str, side: int, volume: float, level: int) -> Position:
        if symbol == self.cfg.symbol1:
            bid, ask = ctx["bid1"], ctx["ask1"]
            slip = self.cfg.s1_slippage_price
            contract = self.cfg.symbol1_contract_size
            commission = self.cfg.s1_commission_per_lot_per_side * volume
            fee = self.cfg.s1_fee_per_lot_per_side * volume
        else:
            bid, ask = ctx["bid2"], ctx["ask2"]
            slip = self.cfg.s2_slippage_price
            contract = self.cfg.symbol2_contract_size
            commission = self.cfg.s2_commission_per_lot_per_side * volume
            fee = self.cfg.s2_fee_per_lot_per_side * volume

        entry = (ask + slip) if side > 0 else (bid - slip)
        return Position(
            symbol=symbol,
            side=side,
            volume=volume,
            contract_size=contract,
            entry_price=entry,
            open_time=ctx["time"],
            level=level,
            open_commission=commission,
            open_fee=fee,
        )

    def _close_current_basket(self, ctx: Dict, reason: str, bypass_profit_rule: bool = False) -> bool:
        if self.basket is None:
            return False

        b = self.basket
        preclose_net = self._basket_net_floating(ctx)
        if not bypass_profit_rule and self.cfg.require_profit_close and preclose_net < self.cfg.min_basket_profit:
            return False

        # Smart-close ordering is recorded, but at row-data resolution all legs close on this row.
        ordered = list(self.positions)
        if self.cfg.trade_mode.upper() == "BOTH":
            if self.cfg.enable_smart_close:
                p1_float = self._symbol_floating(self.cfg.symbol1, ctx)
                p2_float = self._symbol_floating(self.cfg.symbol2, ctx)
                if self.cfg.close_profit_first:
                    first = self.cfg.symbol1 if p1_float >= p2_float else self.cfg.symbol2
                else:
                    first = self.cfg.symbol1 if p1_float <= p2_float else self.cfg.symbol2
                second = self.cfg.symbol2 if first == self.cfg.symbol1 else self.cfg.symbol1
                symbol_order = [first, second]
            else:
                # EA default non-smart order: S2 -> S1
                symbol_order = [self.cfg.symbol2, self.cfg.symbol1]
            ordered = sorted(self.positions, key=lambda p: symbol_order.index(p.symbol))

        basket_realized = 0.0
        for pos in ordered:
            leg = self._realize_position(pos, ctx)
            basket_realized += leg["net_pnl"]
            self.closed_legs.append({
                "basket_id": b.basket_id,
                **leg,
                "exit_reason": reason,
            })

        self.realized_pnl += basket_realized

        duration_hours = (ctx["time"] - b.start_time).total_seconds() / 3600.0
        self.basket_results.append({
            "basket_id": b.basket_id,
            "direction": b.direction.name,
            "start_time": b.start_time,
            "end_time": ctx["time"],
            "duration_hours": duration_hours,
            "initial_entry_z": b.initial_entry_z,
            "exit_z": ctx["z"],
            "add_count": b.add_count,
            "levels": b.add_count + 1,
            "reversion_reached": b.reversion_reached,
            "reversion_time": b.reversion_time,
            "max_abs_z": b.max_abs_z,
            "min_net_profit_seen": b.min_net_profit_seen,
            "max_net_profit_seen": b.max_net_profit_seen,
            "preclose_net_floating": preclose_net,
            "realized_net_pnl": basket_realized,
            "exit_reason": reason,
        })

        self._event(ctx, "CLOSE", details=f"{reason}; realized={basket_realized:.2f}")
        self.positions.clear()
        self.basket = None
        self.last_close_time = ctx["time"]
        return True

    def _realize_position(self, pos: Position, ctx: Dict) -> Dict:
        if pos.symbol == self.cfg.symbol1:
            bid, ask = ctx["bid1"], ctx["ask1"]
            slip = self.cfg.s1_slippage_price
            close_commission = self.cfg.s1_commission_per_lot_per_side * pos.volume
            close_fee = self.cfg.s1_fee_per_lot_per_side * pos.volume
        else:
            bid, ask = ctx["bid2"], ctx["ask2"]
            slip = self.cfg.s2_slippage_price
            close_commission = self.cfg.s2_commission_per_lot_per_side * pos.volume
            close_fee = self.cfg.s2_fee_per_lot_per_side * pos.volume

        exit_price = (bid - slip) if pos.side > 0 else (ask + slip)
        gross = pos.side * (exit_price - pos.entry_price) * pos.volume * pos.contract_size
        swap = self._accrued_swap(pos, ctx["time"])
        net = gross + swap - pos.open_commission - pos.open_fee - close_commission - close_fee

        return {
            "symbol": pos.symbol,
            "side": "BUY" if pos.side > 0 else "SELL",
            "level": pos.level,
            "volume": pos.volume,
            "open_time": pos.open_time,
            "close_time": ctx["time"],
            "entry_price": pos.entry_price,
            "exit_price": exit_price,
            "gross_pnl": gross,
            "swap": swap,
            "open_commission": pos.open_commission,
            "open_fee": pos.open_fee,
            "close_commission": close_commission,
            "close_fee": close_fee,
            "net_pnl": net,
        }

    # ------------------------------------------------------------------
    # P/L / costs / margin
    # ------------------------------------------------------------------
    def _basket_net_floating(self, ctx: Dict) -> float:
        # Mirrors EA intent: current liquidation P/L + swap - already-paid opening costs.
        return float(sum(self._position_net_floating(p, ctx) for p in self.positions))

    def _position_net_floating(self, pos: Position, ctx: Dict) -> float:
        if pos.symbol == self.cfg.symbol1:
            bid, ask = ctx["bid1"], ctx["ask1"]
        else:
            bid, ask = ctx["bid2"], ctx["ask2"]
        liquidation = bid if pos.side > 0 else ask
        gross = pos.side * (liquidation - pos.entry_price) * pos.volume * pos.contract_size
        return gross + self._accrued_swap(pos, ctx["time"]) - pos.open_commission - pos.open_fee

    def _symbol_floating(self, symbol: str, ctx: Dict) -> float:
        return sum(self._position_net_floating(p, ctx) for p in self.positions if p.symbol == symbol)

    def _accrued_swap(self, pos: Position, now: pd.Timestamp) -> float:
        days = max(0.0, (now - pos.open_time).total_seconds() / 86400.0)
        if pos.symbol == self.cfg.symbol1:
            rate = self.cfg.s1_swap_long_per_lot_day if pos.side > 0 else self.cfg.s1_swap_short_per_lot_day
        else:
            rate = self.cfg.s2_swap_long_per_lot_day if pos.side > 0 else self.cfg.s2_swap_short_per_lot_day
        return rate * pos.volume * days

    def _estimated_margin(self, ctx: Dict) -> float:
        if self.cfg.leverage <= 0:
            return float("inf")
        total = 0.0
        for p in self.positions:
            px = ctx["p1"] if p.symbol == self.cfg.symbol1 else ctx["p2"]
            total += abs(p.volume * p.contract_size * px) / self.cfg.leverage
        return total

    def _estimated_margin_usage_pct(self, ctx: Dict) -> float:
        equity = self.cfg.initial_capital + self.realized_pnl + self._basket_net_floating(ctx)
        if equity <= 0:
            return float("inf")
        return self._estimated_margin(ctx) / equity * 100.0

    # ------------------------------------------------------------------
    # Lots / time / state helpers
    # ------------------------------------------------------------------
    def _level_base_lots(self, level: int) -> float:
        return self.cfg.base_lots * (self.cfg.add_lot_multiplier ** level)

    def _calculate_symbol2_lots(self, s1_lots: float, p1: float, p2: float) -> float:
        denom = self.cfg.symbol2_contract_size * p2
        if denom <= 0:
            return 0.0
        raw = s1_lots * self.cfg.symbol1_contract_size * p1 / denom
        return self._normalize_volume(self.cfg.symbol2, raw)

    def _normalize_volume(self, symbol: str, volume: float) -> float:
        if volume <= 0:
            return 0.0
        if symbol == self.cfg.symbol1:
            min_lot, max_lot, step = self.cfg.s1_min_lot, self.cfg.s1_max_lot, self.cfg.s1_lot_step
        else:
            min_lot, max_lot, step = self.cfg.s2_min_lot, self.cfg.s2_max_lot, self.cfg.s2_lot_step
        if min_lot <= 0 or max_lot <= 0 or step <= 0 or volume > max_lot + 1e-12:
            return 0.0
        # Approximate MQL MathRound (positive volume): half-up to lot step.
        normalized = math.floor(volume / step + 0.5) * step
        if normalized < min_lot:
            normalized = min_lot
        if normalized > max_lot + 1e-12:
            return 0.0
        from decimal import Decimal
        exponent = Decimal(str(step)).normalize().as_tuple().exponent
        decimals = max(0, min(8, -exponent))
        return round(normalized, decimals)

    def _total_volume(self, symbol: str) -> float:
        return sum(p.volume for p in self.positions if p.symbol == symbol)

    def _is_trade_time_allowed(self, ts: pd.Timestamp) -> bool:
        h = ts.hour
        return self.cfg.earliest_hour_gmt <= h <= self.cfg.latest_hour_gmt

    def _in_cooldown(self, ts: pd.Timestamp) -> bool:
        if self.last_close_time is None or self.cfg.cooldown_minutes <= 0:
            return False
        return (ts - self.last_close_time).total_seconds() < self.cfg.cooldown_minutes * 60.0

    def _update_cooldown(self, ts: pd.Timestamp) -> None:
        # Kept for parity / readability; cooldown is derived from last_close_time.
        _ = self._in_cooldown(ts)

    def _update_basket_extremes(self, ctx: Dict) -> None:
        if self.basket is None:
            return
        b = self.basket
        b.max_abs_z = max(b.max_abs_z, abs(ctx["z"]))
        net = self._basket_net_floating(ctx)
        b.min_net_profit_seen = min(b.min_net_profit_seen, net)
        b.max_net_profit_seen = max(b.max_net_profit_seen, net)

    # ------------------------------------------------------------------
    # Output / diagnostics
    # ------------------------------------------------------------------
    def _event(self, ctx: Dict, event: str, level: Optional[int] = None, details: str = "") -> None:
        self.events.append({
            "time": ctx["time"],
            "event": event,
            "basket_id": self.basket.basket_id if self.basket is not None else self.next_basket_id,
            "level": level,
            "direction": self.basket.direction.name if self.basket is not None else "",
            "z": ctx.get("z", np.nan),
            "log_spread": ctx.get("log_spread", np.nan),
            "p1": ctx.get("p1", np.nan),
            "p2": ctx.get("p2", np.nan),
            "basket_net_floating": self._basket_net_floating(ctx) if self.positions else 0.0,
            "details": details,
        })
        if self.cfg.debug:
            print(self.events[-1])

    def _record_equity(self, ctx: Dict, replace_same_timestamp: bool = False) -> None:
        floating = self._basket_net_floating(ctx) if self.positions else 0.0
        equity = self.cfg.initial_capital + self.realized_pnl + floating
        margin = self._estimated_margin(ctx) if self.positions else 0.0
        usage = margin / equity * 100.0 if equity > 0 else float("inf")
        row = {
            "time": ctx["time"],
            "p1": ctx["p1"],
            "p2": ctx["p2"],
            "sma1": ctx["sma1"],
            "sma2": ctx["sma2"],
            "log_spread": ctx["log_spread"],
            "z": ctx["z"],
            "basket_active": self.basket is not None,
            "basket_id": self.basket.basket_id if self.basket else np.nan,
            "direction": self.basket.direction.name if self.basket else "",
            "add_count": self.basket.add_count if self.basket else 0,
            "reversion_reached": self.basket.reversion_reached if self.basket else False,
            "basket_net_floating": floating,
            "realized_pnl": self.realized_pnl,
            "equity": equity,
            "estimated_margin": margin,
            "estimated_margin_usage_pct": usage,
            "in_cooldown": self._in_cooldown(ctx["time"]),
        }
        if replace_same_timestamp and self.equity_rows and self.equity_rows[-1]["time"] == ctx["time"]:
            self.equity_rows[-1] = row
        else:
            self.equity_rows.append(row)

    def _build_outputs(self) -> Dict[str, pd.DataFrame]:
        event_cols = [
            "time", "event", "basket_id", "level", "direction", "z", "log_spread",
            "p1", "p2", "basket_net_floating", "details"
        ]
        leg_cols = [
            "basket_id", "symbol", "side", "level", "volume", "open_time", "close_time",
            "entry_price", "exit_price", "gross_pnl", "swap", "open_commission", "open_fee",
            "close_commission", "close_fee", "net_pnl", "exit_reason"
        ]
        basket_cols = [
            "basket_id", "direction", "start_time", "end_time", "duration_hours",
            "initial_entry_z", "exit_z", "add_count", "levels", "reversion_reached",
            "reversion_time", "max_abs_z", "min_net_profit_seen", "max_net_profit_seen",
            "preclose_net_floating", "realized_net_pnl", "exit_reason"
        ]
        equity_cols = [
            "time", "p1", "p2", "sma1", "sma2", "log_spread", "z", "basket_active",
            "basket_id", "direction", "add_count", "reversion_reached", "basket_net_floating",
            "realized_pnl", "equity", "estimated_margin", "estimated_margin_usage_pct", "in_cooldown"
        ]
        pos_cols = [
            "symbol", "side", "volume", "contract_size", "entry_price", "open_time",
            "level", "open_commission", "open_fee"
        ]
        return {
            "events": pd.DataFrame(self.events, columns=event_cols),
            "closed_legs": pd.DataFrame(self.closed_legs, columns=leg_cols),
            "baskets": pd.DataFrame(self.basket_results, columns=basket_cols),
            "equity": pd.DataFrame(self.equity_rows, columns=equity_cols),
            "open_positions": pd.DataFrame([asdict(p) for p in self.positions], columns=pos_cols),
        }

    def _validate_config(self) -> None:
        c = self.cfg
        if c.lookback < 2:
            raise ValueError("lookback must be >= 2")
        if abs(c.zscore_open) <= 0:
            raise ValueError("zscore_open must be > 0")
        if c.base_lots <= 0:
            raise ValueError("base_lots must be > 0")
        if c.add_z_step <= 0 or c.max_add_count < 0 or c.add_lot_multiplier <= 0:
            raise ValueError("invalid scale-in parameters")
        if c.min_add_interval_sec < 0 or c.cooldown_minutes < 0:
            raise ValueError("time parameters must be >= 0")
        if c.min_basket_profit < 0:
            raise ValueError("min_basket_profit must be >= 0")
        if c.analysis_timeframe_minutes <= 0:
            raise ValueError("analysis_timeframe_minutes must be > 0")
        if c.enable_scale_in and c.max_abs_z > 0 and c.max_abs_z < abs(c.zscore_open):
            raise ValueError("max_abs_z cannot be below zscore_open when enabled")
        if c.trade_mode.upper() not in {"BOTH", "ONLY_S1", "ONLY_S2"}:
            raise ValueError("trade_mode must be BOTH / ONLY_S1 / ONLY_S2")


def load_pair_csv(path: str, cfg: BacktestConfig) -> pd.DataFrame:
    """Load and normalize user CSV into internal columns.

    Required columns:
        cfg.time_col, cfg.s1_close_col, cfg.s2_close_col

    Optional bid/ask columns are used only when all four configured columns exist.
    Otherwise bid/ask are synthesized from close and configured spread_price.
    """
    df = pd.read_csv(path)
    required = [cfg.time_col, cfg.s1_close_col, cfg.s2_close_col]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"CSV missing required columns: {missing}")

    ts = pd.to_datetime(df[cfg.time_col], errors="coerce")
    if ts.isna().any():
        bad = int(ts.isna().sum())
        raise ValueError(f"time column contains {bad} unparsable timestamps")

    # DatetimeIndex makes timezone operations consistent.
    idx = pd.DatetimeIndex(ts)
    if idx.tz is None:
        idx = idx.tz_localize(cfg.input_timezone)
    idx = idx.tz_convert("UTC")

    out = pd.DataFrame({
        "_time": idx,
        "_p1": pd.to_numeric(df[cfg.s1_close_col], errors="coerce"),
        "_p2": pd.to_numeric(df[cfg.s2_close_col], errors="coerce"),
    })

    use_real_quotes = all([
        cfg.s1_bid_col, cfg.s1_ask_col, cfg.s2_bid_col, cfg.s2_ask_col,
        cfg.s1_bid_col in df.columns if cfg.s1_bid_col else False,
        cfg.s1_ask_col in df.columns if cfg.s1_ask_col else False,
        cfg.s2_bid_col in df.columns if cfg.s2_bid_col else False,
        cfg.s2_ask_col in df.columns if cfg.s2_ask_col else False,
    ])

    if use_real_quotes:
        out["_bid1"] = pd.to_numeric(df[cfg.s1_bid_col], errors="coerce")
        out["_ask1"] = pd.to_numeric(df[cfg.s1_ask_col], errors="coerce")
        out["_bid2"] = pd.to_numeric(df[cfg.s2_bid_col], errors="coerce")
        out["_ask2"] = pd.to_numeric(df[cfg.s2_ask_col], errors="coerce")
    else:
        out["_bid1"] = out["_p1"] - cfg.s1_spread_price / 2.0
        out["_ask1"] = out["_p1"] + cfg.s1_spread_price / 2.0
        out["_bid2"] = out["_p2"] - cfg.s2_spread_price / 2.0
        out["_ask2"] = out["_p2"] + cfg.s2_spread_price / 2.0

    out = out.dropna().sort_values("_time").drop_duplicates("_time", keep="last").reset_index(drop=True)
    if (out[["_p1", "_p2", "_bid1", "_ask1", "_bid2", "_ask2"]] <= 0).any().any():
        raise ValueError("prices/bid/ask must all be > 0")
    if len(out) < cfg.lookback * 2:
        raise ValueError(
            f"not enough rows: {len(out)}. For a fresh EA-like warmup, provide comfortably more than 2*lookback observations/bars."
        )
    return out


def save_outputs(outputs: Dict[str, pd.DataFrame], output_dir: str, cfg: BacktestConfig) -> None:
    outdir = Path(output_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    for name, df in outputs.items():
        df.to_csv(outdir / f"{name}.csv", index=False, encoding="utf-8-sig")

    # Save effective config for reproducibility.
    pd.Series(asdict(cfg), name="value").to_csv(outdir / "config_used.csv", encoding="utf-8-sig")


def print_summary(outputs: Dict[str, pd.DataFrame], cfg: BacktestConfig) -> None:
    baskets = outputs["baskets"]
    equity = outputs["equity"]
    open_positions = outputs["open_positions"]

    realized = float(baskets["realized_net_pnl"].sum()) if not baskets.empty else 0.0
    final_equity = float(equity["equity"].iloc[-1]) if not equity.empty else cfg.initial_capital

    if not equity.empty:
        eq = equity["equity"].astype(float)
        running_max = eq.cummax()
        dd = eq - running_max
        dd_pct = dd / running_max.replace(0, np.nan) * 100.0
        max_dd = float(dd.min())
        max_dd_pct = float(dd_pct.min())
    else:
        max_dd = max_dd_pct = 0.0

    closed = len(baskets)
    winners = int((baskets["realized_net_pnl"] > 0).sum()) if closed else 0
    win_rate = winners / closed * 100.0 if closed else 0.0
    total_adds = int(baskets["add_count"].sum()) if closed else 0

    print("\n========== Backtest Summary ==========")
    print(f"Closed baskets          : {closed}")
    print(f"Winning baskets         : {winners} ({win_rate:.1f}%)")
    print(f"Total scale-ins         : {total_adds}")
    print(f"Realized net P/L        : {realized:.2f}")
    print(f"Ending equity (MTM)     : {final_equity:.2f}")
    print(f"Max drawdown            : {max_dd:.2f} ({max_dd_pct:.2f}%)")
    print(f"Open positions at end   : {len(open_positions)}")
    if not baskets.empty:
        print(f"Worst basket intratrade : {baskets['min_net_profit_seen'].min():.2f}")
        print(f"Max |Z| in closed basket: {baskets['max_abs_z'].max():.2f}")
    print("======================================\n")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Pair Basket Scale-In v7.0 Python backtester")
    p.add_argument("--data", default=None, help="override CONFIG.data_path")
    p.add_argument("--output", default=None, help="override CONFIG.output_dir")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    cfg = CONFIG
    if args.data:
        cfg.data_path = args.data
    if args.output:
        cfg.output_dir = args.output

    df = load_pair_csv(cfg.data_path, cfg)
    engine = PairBasketBacktester(cfg)
    outputs = engine.run(df)
    save_outputs(outputs, cfg.output_dir, cfg)
    print_summary(outputs, cfg)
    print(f"Results saved to: {Path(cfg.output_dir).resolve()}")


if __name__ == "__main__":
    main()
