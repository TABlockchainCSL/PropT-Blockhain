import csv
import os
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path(__file__).parent
WAD = 10**18
TOKEN_ID = os.getenv("PMM_TOKEN_ID", "18")
INPUTS = {
    "Buy → sell": BASE_DIR / f"pmm_token_{TOKEN_ID}_price_buy_then_sell.csv",
    "Sell → buy": BASE_DIR / f"pmm_token_{TOKEN_ID}_price_sell_then_buy.csv",
}
OUTPUT = BASE_DIR / f"pmm_token_{TOKEN_ID}_price_over_time.png"


plt.style.use("seaborn-v0_8-whitegrid")
figure, axis = plt.subplots(figsize=(12, 6), layout="constrained")

for label, input_file in INPUTS.items():
    with input_file.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    dates = [date.fromisoformat(row["block_date"]) for row in rows]
    prices = [int(row["mid_price_quote_per_token"]) / WAD for row in rows]
    axis.plot(dates, prices, label=label, linewidth=1.4)

axis.axhline(10_000, color="black", linestyle="--", linewidth=1, label="Guide valuation: 10,000")
axis.set_title(f"PropertyPMM simulated mid-price — Goro token #{TOKEN_ID}")
axis.set_xlabel("Date")
axis.set_ylabel("Quote units per token")
axis.legend()
figure.savefig(OUTPUT, dpi=180)
print(f"Chart saved to: {OUTPUT.resolve()}")
