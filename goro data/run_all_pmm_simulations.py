import csv
import os
import subprocess
import sys
from pathlib import Path


BASE_DIR = Path(__file__).parent
PROJECT_DIR = BASE_DIR.parent
WAD = 10**18
SUMMARY_FILE = BASE_DIR / "pmm_all_assets_simulation_summary.csv"


with (BASE_DIR / "asset_supply.csv").open(newline="", encoding="utf-8") as file:
    assets = list(csv.DictReader(file))

requested_tokens = set(sys.argv[1:])
if requested_tokens:
    assets = [asset for asset in assets if asset["token_id"] in requested_tokens]

summary_rows = []
for asset in assets:
    token_id = asset["token_id"]
    if os.getenv("PMM_SUMMARY_ONLY") != "1":
        environment = os.environ | {"PMM_TOKEN_ID": token_id}
        subprocess.run(
            ["forge", "test", "--match-contract", "PropertyPMMGoroFlowSimulationTest", "-q"],
            cwd=PROJECT_DIR,
            env=environment,
            check=True,
        )

    scenario_rows = {}
    for scenario in ("buy_then_sell", "sell_then_buy"):
        path = BASE_DIR / f"pmm_token_{token_id}_price_{scenario}.csv"
        with path.open(newline="", encoding="utf-8") as file:
            rows = list(csv.DictReader(file))
        prices = [int(row["mid_price_quote_per_token"]) / WAD for row in rows]
        last = rows[-1]
        scenario_rows[scenario] = {
            "days": len(rows),
            "min_price": min(prices),
            "max_price": max(prices),
            "final_price": prices[-1],
            "rejected_buy": int(last["rejected_buy_base"]) / WAD,
            "rejected_sell": int(last["rejected_sell_base"]) / WAD,
        }

    buy_then_sell = scenario_rows["buy_then_sell"]
    sell_then_buy = scenario_rows["sell_then_buy"]
    summary_rows.append(
        {
            "token_standard": asset["token_standard"],
            "token_id": token_id,
            "total_supply": asset["total_supply"],
            "days": buy_then_sell["days"],
            "buy_then_sell_min_price": f"{buy_then_sell['min_price']:.6f}",
            "buy_then_sell_max_price": f"{buy_then_sell['max_price']:.6f}",
            "buy_then_sell_final_price": f"{buy_then_sell['final_price']:.6f}",
            "sell_then_buy_min_price": f"{sell_then_buy['min_price']:.6f}",
            "sell_then_buy_max_price": f"{sell_then_buy['max_price']:.6f}",
            "sell_then_buy_final_price": f"{sell_then_buy['final_price']:.6f}",
            "rejected_buy_base": f"{max(buy_then_sell['rejected_buy'], sell_then_buy['rejected_buy']):.6f}",
            "rejected_sell_base": f"{max(buy_then_sell['rejected_sell'], sell_then_buy['rejected_sell']):.6f}",
        }
    )

with SUMMARY_FILE.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=summary_rows[0].keys())
    writer.writeheader()
    writer.writerows(summary_rows)

print(f"Simulation summary saved to: {SUMMARY_FILE.resolve()}")
