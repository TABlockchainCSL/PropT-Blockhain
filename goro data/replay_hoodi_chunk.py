"""Broadcast one contiguous token #20 daily-flow chunk to Hoodi and record receipts.

Reads private keys only from environment variables. Do not place keys in this file.

Strategy: fire-with-delay — broadcast all txns in the chunk with a small inter-send
delay (default 300 ms) so we don't hit public-RPC rate limits, then collect all
receipts in parallel polling. Multiple txns from the same account land in the same
or successive blocks; we never need to wait for one confirmation before sending the
next as long as nonces are strictly sequential.
"""

import csv
import json
import os
import time
from pathlib import Path

from web3 import Web3


BASE_DIR = Path(__file__).parent
FLOW_FILE = BASE_DIR / "pmm_token_20_post_launch_daily_flow.csv"
MAX_UINT256 = 2**256 - 1
ERC20_ABI = [
    {
        "type": "function",
        "name": "allowance",
        "stateMutability": "view",
        "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "approve",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
        "outputs": [{"name": "", "type": "bool"}],
    },
]
PMM_ABI = [
    {"type": "function", "name": "baseToken", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "address"}]},
    {"type": "function", "name": "quoteToken", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "address"}]},
    {"type": "function", "name": "baseBalance", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"type": "function", "name": "quoteBalance", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {"type": "function", "name": "getMidPrice", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "uint256"}]},
    {
        "type": "function",
        "name": "sellBaseToken",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "amount", "type": "uint256"}, {"name": "minReceiveQuote", "type": "uint256"}],
        "outputs": [{"name": "receiveQuote", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "buyBaseToken",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "amount", "type": "uint256"}, {"name": "maxPayQuote", "type": "uint256"}],
        "outputs": [{"name": "totalPayQuote", "type": "uint256"}],
    },
]


def required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def broadcast_with_retry(w3: Web3, raw_tx: bytes, retries: int = 3, retry_delay: float = 2.0) -> str:
    for attempt in range(retries):
        try:
            tx_hash = w3.eth.send_raw_transaction(raw_tx)
            return tx_hash.hex()
        except Exception as exc:
            msg = str(exc).lower()
            # already known = already in mempool, treat as success
            if "already known" in msg or "known transaction" in msg:
                return w3.keccak(raw_tx).hex()
            if attempt < retries - 1:
                time.sleep(retry_delay * (attempt + 1))
            else:
                raise


def collect_receipts(w3: Web3, pending: list[dict], timeout: int = 600, poll_latency: float = 2.0) -> list[dict]:
    """Poll for receipts of all pending txns; raise on first revert."""
    remaining = {row["tx_hash"]: row for row in pending}
    ledger: list[dict] = []
    deadline = time.time() + timeout

    while remaining and time.time() < deadline:
        for tx_hash in list(remaining.keys()):
            try:
                receipt = w3.eth.get_transaction_receipt(tx_hash)
            except Exception:
                continue
            if receipt is None:
                continue
            row = remaining.pop(tx_hash)
            row.update(
                {
                    "status": receipt["status"],
                    "block_number": receipt["blockNumber"],
                    "gas_used": receipt["gasUsed"],
                    "effective_gas_price": receipt["effectiveGasPrice"],
                    "gas_cost_wei": receipt["gasUsed"] * receipt["effectiveGasPrice"],
                }
            )
            ledger.append(row)
            if receipt["status"] != 1:
                return ledger  # caller checks for reverts
        if remaining:
            time.sleep(poll_latency)

    if remaining:
        raise RuntimeError(f"{len(remaining)} transactions unconfirmed after {timeout}s: {list(remaining.keys())}")

    # return in original nonce order
    ledger.sort(key=lambda r: r.get("nonce", 0))
    return ledger


def main() -> None:
    rpc_url = os.getenv("HOODI_RPC_URL", "https://rpc.hoodi.ethpandaops.io")
    pool_address = Web3.to_checksum_address(required("REPLAY_POOL"))
    private_key = required("INVESTOR_A_PK")
    start_day = int(required("REPLAY_START_DAY"))
    day_count = int(os.getenv("REPLAY_DAY_COUNT", "25"))
    max_gas_price = int(os.getenv("REPLAY_MAX_GAS_PRICE_WEI", "1200000000"))
    # delay between raw-tx broadcasts to stay under public RPC rate limits
    send_delay = float(os.getenv("REPLAY_SEND_DELAY_MS", "300")) / 1000.0
    output_file = Path(os.getenv("REPLAY_LEDGER_FILE", str(BASE_DIR / f"hoodi_token_20_chunk_{start_day:03d}.json")))

    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 60}))
    if not w3.is_connected():
        raise RuntimeError("cannot connect to Hoodi RPC")
    if w3.eth.chain_id != 560048:
        raise RuntimeError(f"unexpected chain ID: {w3.eth.chain_id}")
    if w3.eth.gas_price > max_gas_price:
        raise RuntimeError(f"gas price {w3.eth.gas_price} exceeds cap {max_gas_price}")

    account = w3.eth.account.from_key(private_key)
    pool = w3.eth.contract(pool_address, abi=PMM_ABI)
    base = w3.eth.contract(Web3.to_checksum_address(pool.functions.baseToken().call()), abi=ERC20_ABI)
    quote = w3.eth.contract(Web3.to_checksum_address(pool.functions.quoteToken().call()), abi=ERC20_ABI)
    gas_price = w3.eth.gas_price
    nonce = w3.eth.get_transaction_count(account.address, "pending")

    # ── Approvals (send-and-wait; only needed once) ───────────────────────
    for token in (base, quote):
        if token.functions.allowance(account.address, pool_address).call() < 2**128:
            tx = token.functions.approve(pool_address, MAX_UINT256).build_transaction(
                {"from": account.address, "nonce": nonce, "chainId": 560048, "gas": 100_000, "gasPrice": gas_price}
            )
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            print(f"  approval sent: {tx_hash.hex()}")
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120, poll_latency=2)
            if receipt["status"] != 1:
                raise RuntimeError(f"approval reverted: {tx_hash.hex()}")
            nonce += 1

    # ── Build + broadcast all swap txns ──────────────────────────────────
    with FLOW_FILE.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))[start_day : start_day + day_count]
    if not rows:
        raise RuntimeError("requested chunk has no daily observations")

    pending: list[dict] = []
    for offset, row in enumerate(rows):
        day_index = start_day + offset
        for kind, amount in (("sell", int(row["sell_volume"]) * 10**18), ("buy", int(row["buy_volume"]) * 10**18)):
            if amount == 0:
                continue
            call = (
                pool.functions.sellBaseToken(amount, 0)
                if kind == "sell"
                else pool.functions.buyBaseToken(amount, MAX_UINT256)
            )
            tx = call.build_transaction(
                {"from": account.address, "nonce": nonce, "chainId": 560048, "gas": 300_000, "gasPrice": gas_price}
            )
            signed = account.sign_transaction(tx)
            tx_hash = broadcast_with_retry(w3, signed.raw_transaction)
            pending.append(
                {
                    "kind": kind,
                    "date": row["block_date"],
                    "day_index": day_index,
                    "amount": str(amount),
                    "nonce": nonce,
                    "tx_hash": tx_hash,
                }
            )
            nonce += 1
            if send_delay > 0:
                time.sleep(send_delay)

    print(f"  broadcast complete: {len(pending)} swaps queued, collecting receipts...")

    # ── Collect receipts ──────────────────────────────────────────────────
    ledger = collect_receipts(w3, pending)

    reverted = [r for r in ledger if r.get("status") == 0]
    if reverted:
        output_file.write_text(json.dumps(ledger, indent=2), encoding="utf-8")
        raise RuntimeError(f"{len(reverted)} transactions reverted: {[r['tx_hash'] for r in reverted]}")

    ledger.append(
        {
            "kind": "chunk_summary",
            "mid_price": pool.functions.getMidPrice().call(),
            "base_reserve": pool.functions.baseBalance().call(),
            "quote_reserve": pool.functions.quoteBalance().call(),
        }
    )

    output_file.write_text(json.dumps(ledger, indent=2), encoding="utf-8")
    print(f"Chunk complete: {len(rows)} days, {len(pending)} swaps")
    print(f"Ledger saved to: {output_file}")
    print(f"Gas spent (wei): {sum(r.get('gas_cost_wei', 0) for r in ledger)}")


if __name__ == "__main__":
    main()
