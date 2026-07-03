import csv
from datetime import date
from pathlib import Path

import matplotlib.pyplot as plt


BASE_DIR = Path(__file__).parent
WAD = 10**18
INPUTS = {
    "20% initial reserve": BASE_DIR / "fork_hoodi_token_20_k_0_05_r_20_daily.csv",
    "30% initial reserve": BASE_DIR / "fork_hoodi_token_20_k_0_05_r_30_daily.csv",
}
OUTPUT = BASE_DIR / "fork_hoodi_token_20_reserve_20_vs_30_price.png"


plt.style.use("seaborn-v0_8-whitegrid")
figure, axis = plt.subplots(figsize=(12, 6), layout="constrained")
for label, input_file in INPUTS.items():
    with input_file.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    dates = [date.fromisoformat(row["block_date"]) for row in rows]
    prices = [int(row["mid_price"]) / WAD for row in rows]
    axis.plot(dates, prices, label=label, linewidth=1.4)

axis.axhline(10_000, color="black", linestyle="--", linewidth=1, label="Guide valuation: 10,000")
axis.set_title("Hoodi Anvil fork — PropertyPMM token #20 proxy, k = 0.05")
axis.set_xlabel("Date")
axis.set_ylabel("Quote units per token")
axis.legend()
figure.savefig(OUTPUT, dpi=180)
print(f"Chart saved to: {OUTPUT.resolve()}")
