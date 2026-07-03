import csv
import statistics
from pathlib import Path


BASE_DIR = Path(__file__).parent
WAD = 10**18
SUPPLY_FILE = BASE_DIR / "asset_supply.csv"
OUTPUT_FILE = BASE_DIR / "pmm_price_deviation_summary.csv"


with SUPPLY_FILE.open(newline="", encoding="utf-8") as file:
    assets = list(csv.DictReader(file))

rows = []
for asset in assets:
    token_id = asset["token_id"]
    deviations = {}
    for scenario in ("buy_then_sell", "sell_then_buy"):
        path = BASE_DIR / f"pmm_token_{token_id}_price_{scenario}.csv"
        with path.open(newline="", encoding="utf-8") as file:
            prices = [int(row["mid_price_quote_per_token"]) / WAD for row in csv.DictReader(file)]
        deviations[scenario] = statistics.pstdev(prices)

    average_deviation = sum(deviations.values()) / len(deviations)
    rows.append(
        {
            "token_standard": asset["token_standard"],
            "token_id": token_id,
            "buy_then_sell_price_stddev": f"{deviations['buy_then_sell']:.6f}",
            "sell_then_buy_price_stddev": f"{deviations['sell_then_buy']:.6f}",
            "average_price_stddev": f"{average_deviation:.6f}",
        }
    )

rows.sort(key=lambda row: float(row["average_price_stddev"]))
with OUTPUT_FILE.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)

for row in rows:
    print(f"#{row['token_id']}: {row['average_price_stddev']}")
print(f"CSV saved to: {OUTPUT_FILE.resolve()}")
