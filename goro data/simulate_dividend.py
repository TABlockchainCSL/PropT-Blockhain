"""
Dividend distribution simulation — Hoodi fork.

Setup:
  1. Generate 5 new investor wallets, fund with ETH
  2. Transfer PDemo from HOLDER, KYC-approve, self-delegate
  3. Run 12 monthly epochs; each investor claims on their own schedule
  4. Record every balance change and verify against expected amounts

Run against fork:
  HOODI_RPC_URL=http://localhost:8545 python3 simulate_dividend.py
Run against live Hoodi:
  python3 simulate_dividend.py   (uses https://rpc.hoodi.ethpandaops.io)
"""

import json
import os
import time
from pathlib import Path
from web3 import Web3

# ── Addresses ──────────────────────────────────────────────────────────────
PDEMO    = Web3.to_checksum_address("0x82C96966167940B21D5382258730b4668E0fB336")
TUSD     = Web3.to_checksum_address("0x829aD27d87C5bf4e70f7C7D40eB17a25e74f824e")
KYC_REG  = Web3.to_checksum_address("0xcF129c752C2957E98F57b670eab7fD68AB227BAA")
DIVIDEND = Web3.to_checksum_address("0x45AA5173F5d66C82351f1F09384E940287A5F83B")
PMM      = Web3.to_checksum_address("0x52e63C13981A90D58bc8A16A24a48896a3E8A276")

HOLDER_ADDR   = Web3.to_checksum_address("0xC61D7D631Ea17E6578A8B3c6973aa7300fd17813")
DEPLOYER_ADDR = Web3.to_checksum_address("0xa7095d976F5328be56CabDfA085230a2BA181DFc")
SPV_ADDR      = Web3.to_checksum_address("0x02CEaEcF4Dad7C14b766Ec1b7F0839009c7429b8")
KYC_OP_ADDR   = Web3.to_checksum_address("0x28D421Db4C5b1FC80A7f5690E5f4279fccF58624")

# ── ABIs ───────────────────────────────────────────────────────────────────
ERC20_ABI = [
    {"type":"function","name":"balanceOf","stateMutability":"view","inputs":[{"name":"","type":"address"}],"outputs":[{"type":"uint256"}]},
    {"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]},
    {"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]},
    {"type":"function","name":"allowance","stateMutability":"view","inputs":[{"name":"owner","type":"address"},{"name":"spender","type":"address"}],"outputs":[{"type":"uint256"}]},
]
VOTES_ABI = ERC20_ABI + [
    {"type":"function","name":"delegate","stateMutability":"nonpayable","inputs":[{"name":"delegatee","type":"address"}],"outputs":[]},
    {"type":"function","name":"delegates","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"type":"address"}]},
    {"type":"function","name":"getVotes","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"type":"uint256"}]},
]
KYC_ABI = [
    {"type":"function","name":"addUser","stateMutability":"nonpayable","inputs":[{"name":"user","type":"address"}],"outputs":[]},
    {"type":"function","name":"isVerified","stateMutability":"view","inputs":[{"name":"user","type":"address"}],"outputs":[{"type":"bool"}]},
    {"type":"function","name":"addApprovedContract","stateMutability":"nonpayable","inputs":[{"name":"contractAddr","type":"address"}],"outputs":[]},
]
DIV_ABI = [
    {"type":"function","name":"depositDividendsAndSync","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"},{"name":"pool","type":"address"}],"outputs":[]},
    {"type":"function","name":"depositDividends","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"}],"outputs":[]},
    {"type":"function","name":"claimDividends","stateMutability":"nonpayable","inputs":[{"name":"maxEpochs","type":"uint256"}],"outputs":[]},
    {"type":"function","name":"pendingDividends","stateMutability":"view","inputs":[{"name":"investor","type":"address"},{"name":"maxEpochs","type":"uint256"}],"outputs":[{"type":"uint256"}]},
    {"type":"function","name":"getEpochCount","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
    {"type":"function","name":"claimedUpToEpoch","stateMutability":"view","inputs":[{"name":"","type":"address"}],"outputs":[{"type":"uint256"}]},
]

ONE = 10 ** 18
MAX_UINT = 2 ** 256 - 1

# ── Distribution ───────────────────────────────────────────────────────────
# Transfer from HOLDER; balances in whole tokens
NEW_INVESTORS = {
    "Investor_A": 50_000,
    "Investor_B": 30_000,
    "Investor_C": 20_000,
    "Investor_D": 15_000,
    "Investor_E": 10_000,
}

# Monthly dividends: (label, rate% of 100,000 tUSD property value)
PROPERTY_VALUE = 100_000 * ONE
MONTHS = [
    ("Jun 2025", 0.74),
    ("Jul 2025", 0.80),
    ("Aug 2025", 0.81),
    ("Sep 2025", 0.84),
    ("Oct 2025", 0.59),
    ("Nov 2025", 0.57),
    ("Dec 2025", 0.67),
    ("Jan 2026", 0.67),
    ("Feb 2026", 0.50),
    ("Mar 2026", 0.59),
    ("Apr 2026", 0.62),
    ("May 2026", 0.63),
]

# Epoch numbers (1-indexed) on which each participant claims
CLAIM_SCHEDULE = {
    "HOLDER":     set(range(1, 13)),   # every month
    "Investor_A": {3, 6, 9, 12},
    "Investor_B": {6, 12},
    "Investor_C": {4, 8, 12},
    "Investor_D": {12},
    "Investor_E": {2, 7, 11},
    "DEPLOYER":   {5, 10, 12},
}


# ── Helpers ────────────────────────────────────────────────────────────────
def send(w3, account, fn, gas=300_000):
    tx = fn.build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address, "pending"),
        "gas": gas,
        "gasPrice": w3.eth.gas_price,
        "chainId": w3.eth.chain_id,
    })
    signed = account.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(h, timeout=120)
    assert receipt["status"] == 1, f"tx reverted: {h.hex()}"
    return receipt


def mine(w3, blocks=1):
    for _ in range(blocks):
        w3.provider.make_request("evm_mine", [])


def fmt(wei):
    return f"{wei / ONE:>14.4f}"


# ── Main ───────────────────────────────────────────────────────────────────
def main():
    rpc = os.getenv("HOODI_RPC_URL", "https://rpc.hoodi.ethpandaops.io")
    is_fork = "localhost" in rpc or "127.0.0.1" in rpc

    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 60}))
    assert w3.is_connected(), "cannot connect to RPC"
    print(f"Connected: chain={w3.eth.chain_id}  block={w3.eth.block_number}  fork={is_fork}")

    # Load known accounts
    holder_acc   = w3.eth.account.from_key(os.environ["INVESTOR_A_PK"])
    kyc_op_acc   = w3.eth.account.from_key(os.environ["KYC_OPERATOR_PK"])
    spv_acc      = w3.eth.account.from_key(os.environ["SPV_PK"])
    deployer_acc = w3.eth.account.from_key(os.environ["PRIVATE_KEY"])

    assert holder_acc.address   == HOLDER_ADDR,   "INVESTOR_A_PK mismatch"
    assert kyc_op_acc.address   == KYC_OP_ADDR,   "KYC_OPERATOR_PK mismatch"
    assert spv_acc.address      == SPV_ADDR,       "SPV_PK mismatch"
    assert deployer_acc.address == DEPLOYER_ADDR,  "PRIVATE_KEY mismatch"

    pdemo  = w3.eth.contract(PDEMO,    abi=VOTES_ABI)
    tusd   = w3.eth.contract(TUSD,     abi=ERC20_ABI)
    kyc    = w3.eth.contract(KYC_REG,  abi=KYC_ABI)
    div    = w3.eth.contract(DIVIDEND, abi=DIV_ABI)

    # ── 1. Generate new investor wallets ───────────────────────────────────
    print("\n── Generating investor wallets ──")
    # Deterministic: derive from fixed entropy so results are reproducible
    seeds = [
        b"goro-inv-a-2025",
        b"goro-inv-b-2025",
        b"goro-inv-c-2025",
        b"goro-inv-d-2025",
        b"goro-inv-e-2025",
    ]
    investor_accounts = {}
    for (name, _), seed in zip(NEW_INVESTORS.items(), seeds):
        pk = "0x" + w3.keccak(seed).hex()
        acc = w3.eth.account.from_key(pk)
        investor_accounts[name] = acc
        print(f"  {name}: {acc.address}")

    # Map all participants
    all_accounts = {
        "HOLDER":   holder_acc,
        "DEPLOYER": deployer_acc,
        **investor_accounts,
    }

    # ── 2. Fund investors with ETH ─────────────────────────────────────────
    print("\n── Funding investors with ETH ──")
    ETH_PER_INVESTOR = int(0.05 * ONE)  # 0.05 ETH each on live; enough for ~50 txns at 1 gwei
    if is_fork:
        for acc in list(all_accounts.values()) + list(investor_accounts.values()) + [spv_acc]:
            w3.provider.make_request("anvil_setBalance", [acc.address, hex(5 * ONE)])
        print("  anvil_setBalance 5 ETH → all accounts")
    else:
        # Send ETH from DEPLOYER to each investor that needs it
        for name, acc in investor_accounts.items():
            bal = w3.eth.get_balance(acc.address)
            if bal < ETH_PER_INVESTOR // 2:
                nonce = w3.eth.get_transaction_count(deployer_acc.address, "pending")
                tx = {"to": acc.address, "value": ETH_PER_INVESTOR, "gas": 21_000,
                      "gasPrice": w3.eth.gas_price, "nonce": nonce, "chainId": w3.eth.chain_id}
                signed = deployer_acc.sign_transaction(tx)
                h = w3.eth.send_raw_transaction(signed.raw_transaction)
                w3.eth.wait_for_transaction_receipt(h, timeout=120)
                print(f"  {name}: funded 0.05 ETH (tx {h.hex()[:12]}…)")
            else:
                print(f"  {name}: already has {bal/ONE:.4f} ETH, skip")

    # ── 3. KYC + transfer PDemo + delegate ────────────────────────────────
    print("\n── KYC / transfer / delegate ──")
    for name, tokens in NEW_INVESTORS.items():
        acc = investor_accounts[name]
        amount = tokens * ONE

        # KYC (skip if already verified)
        if not kyc.functions.isVerified(acc.address).call():
            send(w3, kyc_op_acc, kyc.functions.addUser(acc.address))

        # Transfer PDemo from HOLDER
        send(w3, holder_acc, pdemo.functions.transfer(acc.address, amount))

        # Self-delegate (investor signs their own tx)
        send(w3, acc, pdemo.functions.delegate(acc.address), gas=150_000)

        print(f"  {name}: KYC✓  {tokens:,} PDemo transferred  delegated✓")

    # Mine so voting power checkpoints are final before first epoch snapshot
    mine(w3, 2)

    # ── 3b. Skip existing epochs for all participants ──────────────────────
    # Old epochs had different/zero voting power → claim returns 0, but we
    # must advance claimedUpToEpoch pointers so they don't pollute our sim.
    existing_epochs = div.functions.getEpochCount().call()
    if existing_epochs > 0:
        print(f"\n── Skipping {existing_epochs} existing epoch(s) ──")
        skip_accs = [holder_acc, deployer_acc, spv_acc] + list(investor_accounts.values())
        for acc in skip_accs:
            claimed = div.functions.claimedUpToEpoch(acc.address).call()
            if claimed < existing_epochs:
                send(w3, acc, div.functions.claimDividends(existing_epochs), gas=500_000)
        print("  All participants advanced past existing epochs")

    # ── 4. Snapshot pre-simulation balances ───────────────────────────────
    print("\n── Pre-simulation tUSD balances ──")
    def tusd_bal(addr):
        return tusd.functions.balanceOf(addr).call()

    pre_balances = {name: tusd_bal(acc.address) for name, acc in all_accounts.items()}
    pre_balances["PMM"] = tusd_bal(PMM)
    for name, bal in pre_balances.items():
        addr = all_accounts[name].address if name in all_accounts else PMM
        votes = pdemo.functions.getVotes(addr).call()
        print(f"  {name:12s}: tUSD={fmt(bal)}  votes={votes//ONE:>9,}")

    # SPV approve max tUSD to DividendDistributor once
    if tusd.functions.allowance(SPV_ADDR, DIVIDEND).call() < 10_000 * ONE:
        send(w3, spv_acc, tusd.functions.approve(DIVIDEND, MAX_UINT), gas=100_000)
        print("\n  SPV approved tUSD → DividendDistributor")

    # ── 5. Run 12 epochs ──────────────────────────────────────────────────
    print("\n── Running 12 dividend epochs ──")
    ledger = []
    existing_epochs = div.functions.getEpochCount().call()
    print(f"  Existing epochs before simulation: {existing_epochs}")

    for epoch_num, (month, rate) in enumerate(MONTHS, start=1):
        amount = int(PROPERTY_VALUE * rate / 100)
        print(f"\n  Epoch {epoch_num:>2} [{month}]  deposit={amount/ONE:.2f} tUSD")

        # Mine a block so snapshot block is fresh
        mine(w3)

        # SPV deposits + syncs PMM
        pmm_quote_before = tusd_bal(PMM)
        receipt_dep = send(w3, spv_acc,
            div.functions.depositDividendsAndSync(amount, PMM), gas=500_000)

        pmm_quote_after = tusd_bal(PMM)
        pmm_received = pmm_quote_after - pmm_quote_before
        print(f"    deposit tx: {receipt_dep['transactionHash'].hex()}")
        print(f"    PMM received: {pmm_received/ONE:.4f} tUSD")

        epoch_record = {
            "epoch": epoch_num,
            "month": month,
            "amount_deposited": amount,
            "deposit_tx": receipt_dep["transactionHash"].hex(),
            "pmm_received": pmm_received,
            "claims": {},
        }

        # Claims for this epoch
        claimants_this_epoch = [
            name for name, schedule in CLAIM_SCHEDULE.items()
            if epoch_num in schedule
        ]

        for name in claimants_this_epoch:
            if name == "PMM":
                continue
            acc = all_accounts[name]
            bal_before = tusd_bal(acc.address)
            pending = div.functions.pendingDividends(acc.address, 100).call()
            receipt_claim = send(w3, acc,
                div.functions.claimDividends(100), gas=500_000)
            bal_after = tusd_bal(acc.address)
            claimed = bal_after - bal_before

            # Expected: sum of epochs since last claim
            epoch_record["claims"][name] = {
                "claimed": claimed,
                "pending_before": pending,
                "tx": receipt_claim["transactionHash"].hex(),
                "gas_used": receipt_claim["gasUsed"],
            }
            print(f"    {name:12s} claimed: {claimed/ONE:>10.4f} tUSD"
                  f"  (pending was {pending/ONE:.4f})")

        mine(w3)
        ledger.append(epoch_record)

    # ── 6. Final balances & summary ───────────────────────────────────────
    print("\n── Final tUSD balances ──")
    total_claimed = {name: 0 for name in list(all_accounts.keys()) + ["PMM"]}
    for rec in ledger:
        for name, c in rec["claims"].items():
            total_claimed[name] = total_claimed.get(name, 0) + c["claimed"]
        total_claimed["PMM"] += rec["pmm_received"]

    post_balances = {name: tusd_bal(acc.address) for name, acc in all_accounts.items()}
    post_balances["PMM"] = tusd_bal(PMM)

    # Compute total voting power for expected share
    all_addrs = {name: acc.address for name, acc in all_accounts.items()}
    all_addrs["PMM"] = PMM
    total_votes = sum(pdemo.functions.getVotes(addr).call() for addr in all_addrs.values())

    grand_total_deposited = sum(int(PROPERTY_VALUE * r / 100) for _, r in MONTHS)

    print(f"\n  {'Name':12s} {'Votes':>9} {'Share':>7} {'Expected':>14} {'Actual':>14} {'Δ wei':>10}")
    print("  " + "-" * 72)
    for name, addr in all_addrs.items():
        votes = pdemo.functions.getVotes(addr).call()
        share = votes / total_votes if total_votes else 0
        expected = int(grand_total_deposited * share)
        actual = total_claimed.get(name, 0)
        delta = actual - expected
        print(f"  {name:12s} {votes//ONE:>9,} {share*100:>6.2f}%"
              f" {expected/ONE:>14.4f} {actual/ONE:>14.4f} {delta:>10}")

    print(f"\n  Total deposited : {grand_total_deposited/ONE:.2f} tUSD")
    print(f"  Total claimed   : {sum(total_claimed.values())/ONE:.2f} tUSD")

    # Save ledger
    out = Path(__file__).parent / "dividend_simulation_ledger.json"
    out.write_text(json.dumps(
        [{**r, "deposit_tx": r["deposit_tx"],
          "pmm_received": str(r["pmm_received"]),
          "amount_deposited": str(r["amount_deposited"]),
          "claims": {k: {**v, "claimed": str(v["claimed"]), "pending_before": str(v["pending_before"])}
                     for k, v in r["claims"].items()}}
         for r in ledger],
        indent=2), encoding="utf-8")
    print(f"\n  Ledger saved: {out}")


if __name__ == "__main__":
    main()
