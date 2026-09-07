from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
rows = []
for csv_path in sorted((ROOT / "results" / "timeslice").glob("*.csv")):
    year = csv_path.stem
    df = pd.read_csv(csv_path)
    for _, r in df.iterrows():
        preset = str(r["StrategyPreset"])[0]
        rows.append({
            "Year": year,
            "Preset": preset,
            "NetProfit": r["NetProfit"],
            "Sharpe": r["Sharpe"],
            "PF": r["ProfitFactor"],
            "MaxDDPct": r["MaxEquityDrawdownPct"],
            "WorstBasket": r["WorstBasketLoss"],
            "LongestHoldDays": r["LongestBasketHoldHours"] / 24.0,
            "AvgHoldDays": r["AvgBasketHoldHours"] / 24.0,
            "BasketCount": int(r["BasketCountObserved"]),
            "ActiveBasketDaysAtEnd": r["ActiveBasketAgeHoursAtEnd"] / 24.0,
        })

out = pd.DataFrame(rows).sort_values(["Year", "Preset"])
print(out.to_string(index=False, float_format=lambda x: f"{x:.3f}"))
