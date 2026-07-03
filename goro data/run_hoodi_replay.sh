#!/usr/bin/env bash
# Drive the Hoodi token #20 PMM replay in chunks.
# Usage:
#   export INVESTOR_A_PK=0x...
#   export REPLAY_POOL=0x52e63C13981A90D58bc8A16A24a48896a3E8A276
#   export HOODI_RPC_URL=https://rpc.hoodi.ethpandaops.io   # optional override
#   bash run_hoodi_replay.sh [START_DAY [END_DAY [CHUNK_SIZE]]]
#
# Txns are broadcast with a 300ms inter-send delay then receipts collected in
# parallel — no need to wait per-tx. Multiple txns land in the same or
# successive Hoodi blocks; nonce ordering handles sequencing.
#
# Reads private key ONLY from INVESTOR_A_PK env var. Never echoed here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_ENV="$SCRIPT_DIR/../.env"
[ -f "$ROOT_ENV" ] && set -a && source "$ROOT_ENV" && set +a
HOODI_RPC="${HOODI_RPC_URL:-https://rpc.hoodi.ethpandaops.io}"
PMM="${REPLAY_POOL:-0x52e63C13981A90D58bc8A16A24a48896a3E8A276}"
HOLDER="0xC61D7D631Ea17E6578A8B3c6973aa7300fd17813"
TOTAL_DAYS=517         # rows in daily flow CSV (index 0–516)
START_DAY="${1:-25}"   # resume point after previous session
END_DAY="${2:-$((TOTAL_DAYS - 1))}"
CHUNK_SIZE="${3:-25}"  # 25 days = up to 50 swaps broadcast in one burst

# ── Preflight ──────────────────────────────────────────────────────────────
if [ -z "${INVESTOR_A_PK:-}" ]; then
    echo "ERROR: INVESTOR_A_PK is not set. Export it before running this script." >&2
    exit 1
fi
if [ -z "${REPLAY_POOL:-}" ]; then
    echo "ERROR: REPLAY_POOL is not set. Export it before running this script." >&2
    exit 1
fi

echo "=== Hoodi Replay Wrapper ==="
echo "  Pool:       $PMM"
echo "  Holder:     $HOLDER"
echo "  RPC:        $HOODI_RPC"
echo "  Days:       $START_DAY → $END_DAY  (chunk $CHUNK_SIZE)"
echo ""

# ── Nonce gate ─────────────────────────────────────────────────────────────
wait_for_nonce_settle() {
    local latest pending_hex pending attempts=0
    echo -n "  Waiting for pending nonce to settle..."
    while true; do
        latest=$(cast nonce "$HOLDER" --rpc-url "$HOODI_RPC" 2>/dev/null || echo "0")
        pending_hex=$(cast rpc eth_getTransactionCount "$HOLDER" pending --rpc-url "$HOODI_RPC" 2>/dev/null || echo '"0x0"')
        pending=$(printf '%d' "$pending_hex" 2>/dev/null || python3 -c "print(int('$pending_hex'.strip('\"'), 16))" 2>/dev/null || echo "$latest")
        if [ "$latest" -eq "$pending" ]; then
            echo " settled at nonce $latest"
            return 0
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo ""
            echo "ERROR: Nonce did not settle after 5 minutes (latest=$latest, pending=$pending)" >&2
            exit 1
        fi
        sleep 5
        echo -n "."
    done
}

# ── PMM snapshot ───────────────────────────────────────────────────────────
pmm_snapshot() {
    local base quote price
    base=$(cast call "$PMM" 'baseBalance()(uint256)' --rpc-url "$HOODI_RPC" 2>/dev/null || echo "N/A")
    quote=$(cast call "$PMM" 'quoteBalance()(uint256)' --rpc-url "$HOODI_RPC" 2>/dev/null || echo "N/A")
    price=$(cast call "$PMM" 'getMidPrice()(uint256)' --rpc-url "$HOODI_RPC" 2>/dev/null || echo "N/A")
    echo "  baseBalance  = $base"
    echo "  quoteBalance = $quote"
    echo "  midPrice     = $price"
}

# ── Initial state ──────────────────────────────────────────────────────────
echo ">>> Pre-replay PMM snapshot:"
pmm_snapshot
echo ""

# ── Chunk loop ─────────────────────────────────────────────────────────────
day=$START_DAY
total_gas=0

while [ "$day" -le "$END_DAY" ]; do
    remaining=$((END_DAY - day + 1))
    chunk=$CHUNK_SIZE
    [ "$remaining" -lt "$chunk" ] && chunk=$remaining

    echo ">>> Chunk: days $day – $((day + chunk - 1)) ($chunk days)"

    REPLAY_START_DAY="$day" \
    REPLAY_DAY_COUNT="$chunk" \
    HOODI_RPC_URL="$HOODI_RPC" \
    REPLAY_POOL="$PMM" \
    INVESTOR_A_PK="$INVESTOR_A_PK" \
    REPLAY_LEDGER_FILE="$SCRIPT_DIR/hoodi_token_20_chunk_$(printf '%03d' "$day").json" \
        python3 "$SCRIPT_DIR/replay_hoodi_chunk.py"

    # parse gas from ledger
    ledger_file="$SCRIPT_DIR/hoodi_token_20_chunk_$(printf '%03d' "$day").json"
    if [ -f "$ledger_file" ]; then
        chunk_gas=$(python3 -c "
import json, sys
data = json.load(open('$ledger_file'))
print(sum(r.get('gas_cost_wei', 0) for r in data))
" 2>/dev/null || echo 0)
        total_gas=$((total_gas + chunk_gas))
        echo "  Chunk gas (wei): $chunk_gas  |  Running total: $total_gas"
    fi

    day=$((day + chunk))

    if [ "$day" -le "$END_DAY" ]; then
        echo ">>> PMM state after chunk:"
        pmm_snapshot
        echo ""
    fi
done

# ── Final state ────────────────────────────────────────────────────────────
echo ""
echo "=== Replay complete: days $START_DAY–$END_DAY ==="
echo "Total gas spent (wei): $total_gas"
echo ""
echo ">>> Final PMM snapshot:"
pmm_snapshot
