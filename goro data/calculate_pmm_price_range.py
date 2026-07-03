import csv
from pathlib import Path


BASE_DIR = Path(__file__).parent
WAD = 10**18
SUPPLY_FILE = BASE_DIR / "asset_supply.csv"
OUTPUT_FILE = BASE_DIR / "pmm_price_range_summary.csv"


with SUPPLY_FILE.open(newline="", encoding="utf-8") as file:
    assets = list(csv.DictReader(file))

rows = []
for asset in assets:
    token_id = asset["token_id"]
    ranges = {}
    for scenario in ("buy_then_sell", "sell_then_buy"):
        path = BASE_DIR / f"pmm_token_{token_id}_price_{scenario}.csv"
        with path.open(newline="", encoding="utf-8") as file:
            prices = [int(row["mid_price_quote_per_token"]) / WAD for row in csv.DictReader(file)]
        ranges[scenario] = (min(prices), max(prices))

    average_range = sum(maximum - minimum for minimum, maximum in ranges.values()) / len(ranges)
    rows.append(
        {
            "token_standard": asset["token_standard"],
            "token_id": token_id,
            "buy_then_sell_min_price": f"{ranges['buy_then_sell'][0]:.6f}",
            "buy_then_sell_max_price": f"{ranges['buy_then_sell'][1]:.6f}",
            "buy_then_sell_range": f"{ranges['buy_then_sell'][1] - ranges['buy_then_sell'][0]:.6f}",
            "sell_then_buy_min_price": f"{ranges['sell_then_buy'][0]:.6f}",
            "sell_then_buy_max_price": f"{ranges['sell_then_buy'][1]:.6f}",
            "sell_then_buy_range": f"{ranges['sell_then_buy'][1] - ranges['sell_then_buy'][0]:.6f}",
            "average_price_range": f"{average_range:.6f}",
        }
    )

rows.sort(key=lambda row: float(row["average_price_range"]))
with OUTPUT_FILE.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)

for row in rows:
    print(f"#{row['token_id']}: {row['average_price_range']}")
print(f"CSV saved to: {OUTPUT_FILE.resolve()}")
