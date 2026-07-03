import csv
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path(__file__).parent
WAD = 10**18
INPUTS = {
    "Buy → sell": BASE_DIR / "pmm_token_18_price_buy_then_sell.csv",
    "Sell → buy": BASE_DIR / "pmm_token_18_price_sell_then_buy.csv",
}
OUTPUT = BASE_DIR / "pmm_token_18_reserve_fluctuation.png"


plt.style.use("seaborn-v0_8-whitegrid")
figure, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True, layout="constrained")

for label, input_file in INPUTS.items():
    with input_file.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    dates = [date.fromisoformat(row["block_date"]) for row in rows]
    base_reserve = [int(row["base_reserve"]) / WAD for row in rows]
    quote_reserve = [int(row["quote_reserve"]) / WAD for row in rows]
    axes[0].plot(dates, base_reserve, label=label, linewidth=1.3)
    axes[1].plot(dates, quote_reserve, label=label, linewidth=1.3)

axes[0].axhline(212_073.6, color="black", linestyle="--", linewidth=1, label="Initial reserve")
axes[0].set_title("PropertyPMM reserve fluctuation — Goro token #18")
axes[0].set_ylabel("Base reserve (tokens)")
axes[0].legend()
axes[1].axhline(2_120_736_000, color="black", linestyle="--", linewidth=1, label="Initial reserve")
axes[1].set_ylabel("Quote reserve")
axes[1].set_xlabel("Date")
axes[1].legend()

figure.savefig(OUTPUT, dpi=180)
print(f"Chart saved to: {OUTPUT.resolve()}")
