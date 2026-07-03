import csv
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path(__file__).parent
WAD = 10**18
SCENARIOS = {
    "10% initial reserve": "k_0_05_r_10",
    "20% initial reserve": "k_0_05_r_20",
    "30% initial reserve": "k_0_05_r_30",
}
OUTPUT = BASE_DIR / "pmm_token_20_reserve_10_vs_20_vs_30_price.png"


plt.style.use("seaborn-v0_8-whitegrid")
figure, axis = plt.subplots(figsize=(12, 6), layout="constrained")
for label, tag in SCENARIOS.items():
    path = BASE_DIR / f"pmm_token_20_{tag}_price_buy_then_sell.csv"
    with path.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    dates = [date.fromisoformat(row["block_date"]) for row in rows]
    prices = [int(row["mid_price_quote_per_token"]) / WAD for row in rows]
    axis.plot(dates, prices, label=label, linewidth=1.4)

axis.axhline(10_000, color="black", linestyle="--", linewidth=1, label="Guide valuation: 10,000")
axis.set_title("PropertyPMM price comparison — Goro token #20, k = 0.05")
axis.set_xlabel("Date")
axis.set_ylabel("Quote units per token")
axis.legend()
figure.savefig(OUTPUT, dpi=180)
print(f"Chart saved to: {OUTPUT.resolve()}")
