import csv
from collections import defaultdict
from datetime import date
from decimal import Decimal
from pathlib import Path


BASE_DIR = Path(__file__).parent
TRADING_DATA_FILE = BASE_DIR / "dune_query_6936221.csv"
SUPPLY_FILE = BASE_DIR / "asset_supply.csv"
OUTPUT_FILE = BASE_DIR / "asset_turnover_rate.csv"
PERIOD_OUTPUTS = {
    "day": BASE_DIR / "asset_turnover_rate_daily.csv",
    "month": BASE_DIR / "asset_turnover_rate_monthly.csv",
    "year": BASE_DIR / "asset_turnover_rate_yearly.csv",
}
FULL_TURNOVER_OUTPUT = BASE_DIR / "asset_full_turnover_timing.csv"
PMM_BASELINE_TOKEN_ID = "18"
PMM_FLOW_OUTPUT = BASE_DIR / f"pmm_token_{PMM_BASELINE_TOKEN_ID}_daily_flow.csv"
PMM_POST_LAUNCH_START = date(2024, 12, 25)
PMM_POST_LAUNCH_OUTPUT = BASE_DIR / f"pmm_token_{PMM_BASELINE_TOKEN_ID}_post_launch_daily_flow.csv"


def decimal_value(value: str) -> Decimal:
    return Decimal(value.replace(",", ""))


supplies = {}
with SUPPLY_FILE.open(newline="", encoding="utf-8") as file:
    for row in csv.DictReader(file):
        key = (row["token_standard"], row["token_id"])
        supplies[key] = decimal_value(row["total_supply"])

volumes = defaultdict(lambda: {"sell": Decimal(0), "buy": Decimal(0)})
period_volumes = {
    period: defaultdict(lambda: {"sell": Decimal(0), "buy": Decimal(0)})
    for period in PERIOD_OUTPUTS
}
with TRADING_DATA_FILE.open(newline="", encoding="utf-8") as file:
    for row in csv.DictReader(file):
        key = (row["token_standard"], row["token_id"])
        sell = decimal_value(row["amount_in"])
        buy = decimal_value(row["amount_out"])
        volumes[key]["sell"] += sell
        volumes[key]["buy"] += buy

        block_date = date.fromisoformat(row["block_date"])
        period_keys = {
            "day": block_date.isoformat(),
            "month": block_date.strftime("%Y-%m"),
            "year": str(block_date.year),
        }
        for period, period_key in period_keys.items():
            aggregate = period_volumes[period][(period_key, *key)]
            aggregate["sell"] += sell
            aggregate["buy"] += buy


def make_row(period, key, aggregate, total_supply):
    total_sell = aggregate["sell"]
    total_buy = aggregate["buy"]
    total_volume = total_sell + total_buy
    turnover_rate = total_volume / total_supply if total_supply else Decimal(0)
    adjusted_turnover_rate = turnover_rate - 1
    return {
        "period": period,
        "token_standard": key[0],
        "token_id": key[1],
        "total_sell": str(total_sell),
        "total_buy": str(total_buy),
        "total_volume": str(total_volume),
        "total_supply": str(total_supply),
        "turnover_rate": f"{turnover_rate:.8f}",
        "turnover_rate_percent": f"{turnover_rate * 100:.4f}",
        "adjusted_turnover_rate": f"{adjusted_turnover_rate:.8f}",
        "adjusted_turnover_rate_percent": f"{adjusted_turnover_rate * 100:.4f}",
    }


average_rates = {}
for period, aggregates in period_volumes.items():
    rates_by_asset = defaultdict(list)
    for (_, token_standard, token_id), aggregate in aggregates.items():
        total_supply = supplies.get((token_standard, token_id))
        if total_supply:
            total_volume = aggregate["sell"] + aggregate["buy"]
            rates_by_asset[(token_standard, token_id)].append(total_volume / total_supply)
    average_rates[period] = {
        key: sum(rates) / len(rates) for key, rates in rates_by_asset.items()
    }

rows = []
for key, total_supply in sorted(supplies.items(), key=lambda item: (item[0][0], int(item[0][1]))):
    row = make_row("all", key, volumes[key], total_supply)
    for period in PERIOD_OUTPUTS:
        average_rate = average_rates[period].get(key, Decimal(0))
        row[f"average_{period}_turnover_rate"] = f"{average_rate:.8f}"
        row[f"average_{period}_turnover_rate_percent"] = f"{average_rate * 100:.4f}"
    rows.append(row)

with OUTPUT_FILE.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)

for row in rows:
    print(
        f"{row['token_standard']} #{row['token_id']}: "
        f"{row['adjusted_turnover_rate']} ({row['adjusted_turnover_rate_percent']}%)"
    )

for period, output_file in PERIOD_OUTPUTS.items():
    period_rows = []
    for (period_key, token_standard, token_id), aggregate in sorted(period_volumes[period].items()):
        total_supply = supplies.get((token_standard, token_id))
        if total_supply is not None:
            period_rows.append(
                make_row(period_key, (token_standard, token_id), aggregate, total_supply)
            )
    with output_file.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=period_rows[0].keys())
        writer.writeheader()
        writer.writerows(period_rows)
    print(f"{period.title()} CSV saved to: {output_file.resolve()}")

daily_volumes_by_asset = defaultdict(list)
for (period_key, token_standard, token_id), aggregate in period_volumes["day"].items():
    daily_volumes_by_asset[(token_standard, token_id)].append(
        (date.fromisoformat(period_key), aggregate["sell"] + aggregate["buy"])
    )

full_turnover_rows = []
for key, total_supply in sorted(supplies.items(), key=lambda item: (item[0][0], int(item[0][1]))):
    cumulative_volume = Decimal(0)
    raw_reached_date = None
    adjusted_reached_date = None
    first_trade_date = None
    raw_trading_days = None
    adjusted_trading_days = None

    for trading_days, (trading_date, daily_volume) in enumerate(
        sorted(daily_volumes_by_asset[key]), start=1
    ):
        if first_trade_date is None:
            first_trade_date = trading_date
        cumulative_volume += daily_volume
        if raw_reached_date is None and cumulative_volume >= total_supply:
            raw_reached_date = trading_date
            raw_trading_days = trading_days
        if adjusted_reached_date is None and cumulative_volume >= total_supply * 2:
            adjusted_reached_date = trading_date
            adjusted_trading_days = trading_days

    def calendar_days(reached_date):
        if first_trade_date and reached_date:
            return (reached_date - first_trade_date).days + 1
        return ""

    full_turnover_rows.append(
        {
            "token_standard": key[0],
            "token_id": key[1],
            "total_supply": str(total_supply),
            "first_trade_date": first_trade_date.isoformat() if first_trade_date else "",
            "raw_full_turnover_reached_date": raw_reached_date.isoformat() if raw_reached_date else "",
            "raw_calendar_days_to_full_turnover": calendar_days(raw_reached_date),
            "raw_trading_days_to_full_turnover": raw_trading_days or "",
            "adjusted_full_turnover_reached_date": adjusted_reached_date.isoformat() if adjusted_reached_date else "",
            "adjusted_calendar_days_to_full_turnover": calendar_days(adjusted_reached_date),
            "adjusted_trading_days_to_full_turnover": adjusted_trading_days or "",
        }
    )

with FULL_TURNOVER_OUTPUT.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=full_turnover_rows[0].keys())
    writer.writeheader()
    writer.writerows(full_turnover_rows)
print(f"Full-turnover timing CSV saved to: {FULL_TURNOVER_OUTPUT.resolve()}")

# PMM calibration input: retain the observed gross buy/sell flow. The source
# data cannot distinguish primary from secondary activity, so no synthetic
# primary-sale subtraction is applied.
pmm_supply = supplies[("erc1155", PMM_BASELINE_TOKEN_ID)]
pmm_rows = []
for (period_key, token_standard, token_id), aggregate in sorted(period_volumes["day"].items()):
    if (token_standard, token_id) != ("erc1155", PMM_BASELINE_TOKEN_ID):
        continue
    sell_volume = aggregate["sell"]
    buy_volume = aggregate["buy"]
    gross_volume = sell_volume + buy_volume
    pmm_rows.append(
        {
            "block_date": period_key,
            "token_standard": token_standard,
            "token_id": token_id,
            "sell_volume": str(sell_volume),
            "buy_volume": str(buy_volume),
            "gross_volume": str(gross_volume),
            "net_buy_pressure": str(buy_volume - sell_volume),
            "total_supply": str(pmm_supply),
            "gross_daily_turnover_rate": f"{gross_volume / pmm_supply:.8f}",
            "data_source": "Goro market data via Dune query 6936221",
            "primary_secondary_treatment": "combined_observed_flow_no_synthetic_adjustment",
            "sample_window": "full_observed_sample",
        }
    )

with PMM_FLOW_OUTPUT.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=pmm_rows[0].keys())
    writer.writeheader()
    writer.writerows(pmm_rows)
print(f"PMM baseline flow CSV saved to: {PMM_FLOW_OUTPUT.resolve()}")

# Main PMM input excludes the launch window before the first observed sell.
post_launch_rows = []
for row in pmm_rows:
    if date.fromisoformat(row["block_date"]) >= PMM_POST_LAUNCH_START:
        post_launch_row = row.copy()
        post_launch_row["sample_window"] = "post_launch_from_2024-12-25"
        post_launch_rows.append(post_launch_row)

with PMM_POST_LAUNCH_OUTPUT.open("w", newline="", encoding="utf-8") as file:
    writer = csv.DictWriter(file, fieldnames=post_launch_rows[0].keys())
    writer.writeheader()
    writer.writerows(post_launch_rows)
print(f"PMM post-launch flow CSV saved to: {PMM_POST_LAUNCH_OUTPUT.resolve()}")

# Produce a post-launch PMM input for every supplied asset. The reproducible
# cutoff for each asset is its first date with positive observed sell volume.
for (token_standard, token_id), total_supply in supplies.items():
    asset_rows = []
    first_sell_date = None
    for (period_key, standard, asset_id), aggregate in sorted(period_volumes["day"].items()):
        if (standard, asset_id) != (token_standard, token_id):
            continue
        if first_sell_date is None and aggregate["sell"] > 0:
            first_sell_date = period_key
        if first_sell_date is None:
            continue
        sell_volume = aggregate["sell"]
        buy_volume = aggregate["buy"]
        gross_volume = sell_volume + buy_volume
        asset_rows.append(
            {
                "block_date": period_key,
                "token_standard": token_standard,
                "token_id": token_id,
                "sell_volume": str(sell_volume),
                "buy_volume": str(buy_volume),
                "gross_volume": str(gross_volume),
                "net_buy_pressure": str(buy_volume - sell_volume),
                "total_supply": str(total_supply),
                "gross_daily_turnover_rate": f"{gross_volume / total_supply:.8f}",
                "data_source": "Goro market data via Dune query 6936221",
                "primary_secondary_treatment": "combined_observed_flow_no_synthetic_adjustment",
                "sample_window": f"post_launch_from_{first_sell_date}",
            }
        )
    if asset_rows:
        asset_output = BASE_DIR / f"pmm_token_{token_id}_post_launch_daily_flow.csv"
        with asset_output.open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=asset_rows[0].keys())
            writer.writeheader()
            writer.writerows(asset_rows)

missing_supply = sorted(set(volumes) - set(supplies))
if missing_supply:
    print("No total_supply provided for:", ", ".join(f"{standard} #{token_id}" for standard, token_id in missing_supply))

print(f"CSV saved to: {OUTPUT_FILE.resolve()}")
