#!/usr/bin/env bash
# =============================================================================
# PropT — 15-scenario manual test runner for InitialSale + PropertyPMM (Hoodi)
# -----------------------------------------------------------------------------
# Sends real transactions to the live Hoodi deployment. Negative scenarios are
# expected to REVERT and are wrapped so the script keeps going.
#
# Usage:
#   source .env            # must export PRIVATE_KEY, INVESTOR_A_PK, KYC_OPERATOR_PK
#   bash script/run-scenarios.sh                 # run all
#   bash script/run-scenarios.sh 5 6 7           # run only scenarios 5,6,7
#   DRY=1 bash script/run-scenarios.sh           # print commands, don't send
# =============================================================================
set -uo pipefail

# ----- Network & contracts (Hoodi, chainid 560048) ---------------------------
# All addresses are env-overridable so the script can target a freshly
# deployed InitialSale on a fork (export SALE=0x... before running).
RPC="${HOODI_RPC_URL:-https://rpc.hoodi.ethpandaops.io}"
PDEMO="${PDEMO:-0x82C96966167940B21D5382258730b4668E0fB336}"   # base / property token
TUSD="${TUSD:-0x829aD27d87C5bf4e70f7C7D40eB17a25e74f824e}"     # quote / stablecoin
SALE="${SALE:-0x61d811Cbc9F733421a08f6378Be57ee79270DfD2}"     # InitialSale
PMM="${PMM:-0x8EE71931414CCFe26c4807ce8705FB6F3cd5c6a0}"       # PropertyPMM
KYC="${KYC:-0xcF129c752C2957E98F57b670eab7fD68AB227BAA}"       # KYCRegistry

# ----- Signers (private keys come from the environment) -----------------------
: "${PRIVATE_KEY:?set PRIVATE_KEY (deployer / PMM owner)}"
: "${INVESTOR_A_PK:?set INVESTOR_A_PK (HOLDER / Sale owner / 0xC61D)}"
: "${KYC_OPERATOR_PK:?set KYC_OPERATOR_PK (KYC admin)}"
PK_DEPLOYER="$PRIVATE_KEY"
PK_HOLDER="$INVESTOR_A_PK"
PK_KYCOP="$KYC_OPERATOR_PK"

A_DEPLOYER=$(cast wallet address "$PK_DEPLOYER")
A_HOLDER=$(cast wallet address "$PK_HOLDER")
TREASURY="$A_DEPLOYER"   # InitialSale.treasury() == deployer

DRY="${DRY:-0}"

# ----- Helpers ---------------------------------------------------------------
hdr() { echo ""; echo "============================================================"; echo "# $*"; echo "============================================================"; }
note() { echo "    .. $*"; }

# send <pk> <to> <sig> [args...]   — a transaction that must succeed
send() {
  local pk=$1 to=$2 sig=$3; shift 3
  echo "  > send $to \"$sig\" $*"
  [ "$DRY" = "1" ] && return 0
  cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" >/dev/null \
    && echo "    OK" || { echo "    !! UNEXPECTED FAILURE"; return 1; }
}

# xrevert <pk> <to> <sig> [args...] — a transaction expected to REVERT
xrevert() {
  local pk=$1 to=$2 sig=$3; shift 3
  echo "  > [expect revert] $to \"$sig\" $*"
  [ "$DRY" = "1" ] && return 0
  if cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "    !! DID NOT REVERT (unexpected)"
  else
    echo "    OK (reverted as expected)"
  fi
}

callv() { cast call "$1" "$2" "${@:3}" --rpc-url "$RPC"; }   # read a view

want() { [ "${#WANT[@]}" -eq 0 ] && return 0; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

WANT=("$@")

echo "RPC=$RPC"
echo "deployer=$A_DEPLOYER  holder=$A_HOLDER  treasury=$TREASURY  DRY=$DRY"

# =============================================================================
# 1) Sale: deposit inventory  (HOLDER)                                    KF-10
# =============================================================================
if want 1; then hdr "1) Sale: deposit inventory (HOLDER)"
  send "$PK_HOLDER" "$PDEMO" "approve(address,uint256)" "$SALE" 100000ether
  send "$PK_HOLDER" "$SALE"  "deposit(uint256)"               100000ether
  note "tokensAvailable=$(callv "$SALE" 'tokensAvailable()(uint256)')"
fi

# =============================================================================
# 2) Sale: buy token, KYC buyer  (DEPLOYER)                               KF-10
#    price = 1 tUSD/token -> 5000 PDemo costs 5000 tUSD. Gives deployer base.
# =============================================================================
if want 2; then hdr "2) Sale: buy 5000 PDemo (DEPLOYER, KYC)"
  send "$PK_DEPLOYER" "$TUSD" "approve(address,uint256)" "$SALE" 5000ether
  send "$PK_DEPLOYER" "$SALE" "buy(uint256)"                   5000ether
  note "deployer PDemo=$(callv "$PDEMO" 'balanceOf(address)(uint256)' "$A_DEPLOYER")"
fi

# =============================================================================
# 3) NEG: Sale buy by non-KYC wallet -> revert                            KF-6
#    buy() no longer checks KYC explicitly; KYC is enforced by PropertyToken._update
#    on the payout (line 116). buy() pulls PAYMENT first (line 115), so to actually
#    exercise the KYC gate the non-KYC wallet must be funded with tUSD AND approve
#    the sale — otherwise it would revert on payment, not on KYC. Expected revert:
#    RecipientNotAuthorized (from the property-token payout).
# =============================================================================
NEWADDR=""; NEWPK=""
if want 3 || want 14; then
  read -r NEWADDR NEWPK < <(cast wallet new | awk '/Address/{a=$2} /Private key/{print a, $3}')
  echo "    throwaway non-KYC wallet: $NEWADDR (funding 0.01 ETH gas)"
  [ "$DRY" = "1" ] || { cast send "$NEWADDR" --value 0.01ether --private-key "$PK_DEPLOYER" --rpc-url "$RPC" >/dev/null && echo "    funded"; }
fi
if want 3; then hdr "3) NEG: Sale buy by non-KYC (funded+approved) -> revert (RecipientNotAuthorized)"
  if [ "$DRY" != "1" ]; then
    cast send "$TUSD" "transfer(address,uint256)" "$NEWADDR" 10ether --private-key "$PK_DEPLOYER" --rpc-url "$RPC" >/dev/null
    cast send "$TUSD" "approve(address,uint256)"  "$SALE"    10ether --private-key "$NEWPK"      --rpc-url "$RPC" >/dev/null
    echo "    non-KYC wallet funded with 10 tUSD + approved sale (payment will succeed, KYC payout must revert)"
  fi
  xrevert "$NEWPK" "$SALE" "buy(uint256)" 1ether
fi

# =============================================================================
# 4) Sale: withdraw proceeds to treasury  (HOLDER)                        KF-10
# =============================================================================
if want 4; then hdr "4) Sale: withdraw all proceeds to treasury (HOLDER)"
  note "proceeds before=$(callv "$SALE" 'availableProceeds()(uint256)')"
  send "$PK_HOLDER" "$SALE" "withdrawAllProceeds()"
fi

# =============================================================================
# 4b) Sale: authorized withdrawal of UNSOLD inventory after pausing.        KF-10
#     Owner pauses the sale, then pulls unsold property tokens back to a KYC
#     recipient. Includes the guard check: withdrawUnsold while active reverts
#     (SaleActive). Sale is re-enabled at the end to restore state.
# =============================================================================
if want 4b; then hdr "4b) Sale: withdrawUnsold after pause (HOLDER, authorized)"
  note "tokensAvailable before=$(callv "$SALE" 'tokensAvailable()(uint256)')"
  xrevert "$PK_HOLDER" "$SALE" "withdrawUnsold(address,uint256)" "$A_HOLDER" 1000ether   # active -> SaleActive
  send    "$PK_HOLDER" "$SALE" "setSaleActive(bool)" false
  send    "$PK_HOLDER" "$SALE" "withdrawUnsold(address,uint256)" "$A_HOLDER" 1000ether   # paused -> ok
  note "tokensAvailable after=$(callv "$SALE" 'tokensAvailable()(uint256)')"
  send    "$PK_HOLDER" "$SALE" "setSaleActive(bool)" true                                # restore
fi

# =============================================================================
# 5) PMM: provide liquidity  (DEPLOYER)                                    KF-1
#    valuation=100 -> quote = base*100. 50 PDemo + 5000 tUSD.
# =============================================================================
if want 5; then hdr "5) PMM: provide liquidity (DEPLOYER)"
  send "$PK_DEPLOYER" "$PDEMO" "approve(address,uint256)" "$PMM" 50ether
  send "$PK_DEPLOYER" "$TUSD"  "approve(address,uint256)" "$PMM" 5000ether
  send "$PK_DEPLOYER" "$PMM"   "provideLiquidity(uint256,uint256,uint256)" 50ether 5000ether 0
  note "LP shares(deployer)=$(callv "$PMM" 'balanceOf(address)(uint256)' "$A_DEPLOYER")"
fi

# =============================================================================
# 6) PMM: setValuationPrice  (DEPLOYER)  small move (<20%) applies directly KF-3
# =============================================================================
if want 6; then hdr "6) PMM: setValuationPrice 100 -> 110 (DEPLOYER)"
  send "$PK_DEPLOYER" "$PMM" "setValuationPrice(uint256)" 110ether
  note "valuationPrice=$(callv "$PMM" 'getValuationPrice()(uint256)')"
fi

# =============================================================================
# 7) PMM: set fees & taxes  (DEPLOYER)   [no single updateFeesAndTaxes()]  KF-7
#    Order matters: recipient must be set before enableTax().
# =============================================================================
if want 7; then hdr "7) PMM: set fees + taxes (DEPLOYER)"
  send "$PK_DEPLOYER" "$PMM" "setTaxRecipient(address)" "$A_DEPLOYER"
  send "$PK_DEPLOYER" "$PMM" "setBuyTaxRate(uint256)"   10000000000000000   # 1% (1e16)
  send "$PK_DEPLOYER" "$PMM" "setSellTaxRate(uint256)"  10000000000000000   # 1%
  send "$PK_DEPLOYER" "$PMM" "enableTax()"
fi

# =============================================================================
# 8) NEG: swap before trading enabled -> TRADE_NOT_ALLOWED  (HOLDER)       KF-9
#    MUST run before scenario 9.
# =============================================================================
if want 8; then hdr "8) NEG: swap before enableTrading -> revert (TRADE_NOT_ALLOWED)"
  xrevert "$PK_HOLDER" "$PMM" "buyBaseToken(uint256,uint256)" 1ether 1000ether
fi

# =============================================================================
# 9) PMM: enableTrading  (DEPLOYER, owner)                                 KF-9
# =============================================================================
if want 9; then hdr "9) PMM: enableTrading (DEPLOYER)"
  send "$PK_DEPLOYER" "$PMM" "enableTrading()"
  note "tradingEnabled=$(callv "$PMM" 'tradingEnabled()(bool)')"
fi

# =============================================================================
# 10) PMM: buy & sell base (collects taxes from #7)  (HOLDER)              KF-2
# =============================================================================
if want 10; then hdr "10) PMM: buy then sell 1 base (HOLDER)"
  note "quote to buy 1 = $(callv "$PMM" 'queryBuyBaseToken(uint256)(uint256)' 1ether)"
  send "$PK_HOLDER" "$TUSD"  "approve(address,uint256)" "$PMM" 1000ether
  send "$PK_HOLDER" "$PMM"   "buyBaseToken(uint256,uint256)" 1ether 1000ether
  note "quote for sell 1 = $(callv "$PMM" 'querySellBaseToken(uint256)(uint256)' 1ether)"
  send "$PK_HOLDER" "$PDEMO" "approve(address,uint256)" "$PMM" 1ether
  send "$PK_HOLDER" "$PMM"   "sellBaseToken(uint256,uint256)" 1ether 1
fi

# =============================================================================
# 11) NEG: valuation move > maxValuationDeltaBps -> pending, then accept    KF-5
#     Default maxDeltaBps = 2000 (20%). 110 -> 300 (>20%) trips the breaker.
# =============================================================================
if want 11; then hdr "11) PMM: big valuation move trips breaker -> acceptPendingValuation"
  send "$PK_DEPLOYER" "$PMM" "setValuationPrice(uint256)" 300ether
  note "circuitBreakerTripped=$(callv "$PMM" 'valuationCircuitBreakerTripped()(bool)' 2>/dev/null)"
  note "tradingEnabled (auto-off by breaker)=$(callv "$PMM" 'tradingEnabled()(bool)')"
  send "$PK_DEPLOYER" "$PMM" "acceptPendingValuation()"
  # The circuit breaker auto-disabled trading; acceptPendingValuation does NOT
  # re-enable it, so restore trading or scenario 12's swap would revert on
  # TRADE_NOT_ALLOWED instead of the staleness check we mean to exercise.
  send "$PK_DEPLOYER" "$PMM" "enableTrading()"
  note "valuationPrice=$(callv "$PMM" 'getValuationPrice()(uint256)')  tradingEnabled=$(callv "$PMM" 'tradingEnabled()(bool)')"
fi

# =============================================================================
# 12) NEG: swap while valuation stale -> STALE_VALUATION_PRICE  (HOLDER)    KF-4
#     Force staleness=1s, wait, swap (reverts), then restore staleness.
# =============================================================================
if want 12; then hdr "12) NEG: stale valuation -> revert (STALE_VALUATION_PRICE)"
  note "tradingEnabled (must be true to test staleness, not trade gate)=$(callv "$PMM" 'tradingEnabled()(bool)')"
  send "$PK_DEPLOYER" "$PMM" "setValuationValidation(uint256,uint256)" 1 2000   # maxStaleness=1s
  note "sleeping 4s to let valuation go stale..."; [ "$DRY" = "1" ] || sleep 4
  # Assert the revert REASON is genuinely staleness (not TRADE_NOT_ALLOWED etc.)
  if [ "$DRY" != "1" ]; then
    R=$(cast call "$PMM" "buyBaseToken(uint256,uint256)" 1ether 1000ether --from "$A_HOLDER" --rpc-url "$RPC" 2>&1)
    echo "$R" | grep -q "STALE_VALUATION_PRICE" \
      && echo "    OK reason confirmed: STALE_VALUATION_PRICE" \
      || echo "    !! WRONG REASON: $(echo "$R" | tail -1)"
  fi
  xrevert "$PK_HOLDER" "$PMM" "buyBaseToken(uint256,uint256)" 1ether 1000ether
  note "restoring staleness to 180 days"
  send "$PK_DEPLOYER" "$PMM" "setValuationValidation(uint256,uint256)" 15552000 2000
  send "$PK_DEPLOYER" "$PMM" "setValuationPrice(uint256)" 300ether          # refresh timestamp
fi

# =============================================================================
# 13) PMM: LP quote dividends  (DEPLOYER/owner)                            KF-8
#     NOTE: there is NO depositDividendsAndSync() on PMM. LP dividends are
#     funded via claimQuoteDividends() pulling from the external distributor.
#     The deployed testnet distributor pays 0 -> this is expected to revert
#     (NO_DIVIDEND_CLAIMED) until a real dividend distributor is wired up.
# =============================================================================
if want 13; then hdr "13) PMM: claimQuoteDividends -> claimLpQuoteDividends (conditional)"
  note "pendingQuoteDividends=$(callv "$PMM" 'pendingQuoteDividends(uint256)(uint256)' 10 2>/dev/null || echo n/a)"
  xrevert "$PK_DEPLOYER" "$PMM" "claimQuoteDividends(uint256)" 10
  note "if it had funded, then: cast send $PMM 'claimLpQuoteDividends()' (per-LP)"
fi

# =============================================================================
# 14) PMM: transfer LP shares KYC->KYC ok, KYC->non-KYC reverts (DEPLOYER)  KF-6
# =============================================================================
if want 14; then hdr "14) PMM: transfer LP shares (KYC ok / non-KYC revert)"
  send    "$PK_DEPLOYER" "$PMM" "transfer(address,uint256)" "$A_HOLDER" 1ether
  if [ -n "$NEWADDR" ]; then
    xrevert "$PK_DEPLOYER" "$PMM" "transfer(address,uint256)" "$NEWADDR" 1ether
  else
    note "skip non-KYC leg (run with scenario 3 to create the non-KYC wallet)"
  fi
fi

# =============================================================================
# 15) PMM: withdraw liquidity  (DEPLOYER)                                   KF-1
# =============================================================================
if want 15; then hdr "15) PMM: withdraw liquidity (DEPLOYER)"
  SHARES=$(callv "$PMM" 'balanceOf(address)(uint256)' "$A_DEPLOYER" | awk '{print $1}')
  note "burning shares=$SHARES"
  send "$PK_DEPLOYER" "$PMM" "withdrawLiquidity(uint256,uint256,uint256)" "$SHARES" 0 0
fi

echo ""; echo "DONE."
