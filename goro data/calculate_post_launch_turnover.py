import csv
from collections import defaultdict
from decimal import Decimal
from pathlib import Path


BASE_DIR = Path(__file__).parent
WAD = Decimal(1)
supplies = {}
with (BASE_DIR / "asset_supply.csv").open(newline="", encoding="utf-8") as file:
    for row in csv.DictReader(file):
        supplies[(row["token_standard"], row["token_id"])] = Decimal(row["total_supply"])

daily = defaultdict(lambda: {"sell": Decimal(0), "buy": Decimal(0)})
with (BASE_DIR / "dune_query_6936221.csv").open(newline="", encoding="utf-8") as file:
    for row in csv.DictReader(file):
        key = (row["token_standard"], row["token_id"], row["block_date"])
        daily[key]["sell"] += Decimal(row["amount_in"])
        daily[key]["buy"] += Decimal(row["amount_out"])

rows = []
for (standard, token_id), supply in supplies.items():
    asset_days = sorted(
        (block_date, values)
        for (day_standard, day_token_id, block_date), values in daily.items()
        if (day_standard, day_token_id) == (standard, token_id)
    )
    first_sell_date = next(block_date for block_date, values in asset_days if values["sell"] > 0)
    sell = sum(values["sell"] for block_date, values in asset_days if block_date >= first_sell_date)
    buy = sum(values["buy"] for block_date, values in asset_days if block_date >= first_sell_date)
    volume = sell + buy
    rows.append(
        {
            "token_standard": standard,
            "token_id": token_id,
            "post_launch_start_date": first_sell_date,
            "post_launch_sell": str(sell),
            "post_launch_buy": str(buy),
            "post_launch_volume": str(volume),
            "total_supply": str(supply),
            "post_launch_turnover": f"{volume / supply:.8f}",
            "post_launch_turnover_percent": f"{volume / supply * 100:.4f}",
        }
    )

rows.sort(key=lambda row: Decimal(row["post_launch_turnover"]), reverse=True)
output = BASE_DIR / "asset_post_launch_turnover_ranked.csv"
with output.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)

for index, row in enumerate(rows, start=1):
    print(f"{index}. #{row['token_id']}: {row['post_launch_turnover']}")
print(f"CSV saved to: {output.resolve()}")
