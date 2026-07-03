import csv
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path(__file__).parent
WAD = 10**18
TOKEN_IDS = ("5", "14", "10", "16", "8")
OUTPUT = BASE_DIR / "pmm_top5_lowest_range_price_over_time.png"


plt.style.use("seaborn-v0_8-whitegrid")
figure, axis = plt.subplots(figsize=(12, 6), layout="constrained")

for token_id in TOKEN_IDS:
    path = BASE_DIR / f"pmm_token_{token_id}_price_buy_then_sell.csv"
    with path.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    dates = [date.fromisoformat(row["block_date"]) for row in rows]
    prices = [int(row["mid_price_quote_per_token"]) / WAD for row in rows]
    axis.plot(dates, prices, label=f"Token #{token_id}", linewidth=1.4)

axis.axhline(10_000, color="black", linestyle="--", linewidth=1, label="Guide valuation: 10,000")
axis.set_title("PropertyPMM mid-price — five assets with the smallest price range")
axis.set_xlabel("Date")
axis.set_ylabel("Quote units per token")
axis.legend(ncol=2)
figure.savefig(OUTPUT, dpi=180)
print(f"Chart saved to: {OUTPUT.resolve()}")
