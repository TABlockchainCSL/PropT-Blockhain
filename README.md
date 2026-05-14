# PropT Blockchain AMM

Foundry project for a minimal DODO-style PMM pool used by the PropT trading data work.

## Contracts

- `src/amm/MinimalDodoPMM.sol` - PMM pool with an embedded ERC20-style LP share token.
- `src/amm/base/` - small base contracts for roles, configuration, reentrancy guard, and LP-token behavior.
- `src/amm/interfaces/IPriceOracle.sol` - oracle interface. `getPrice()` returns `(price, updatedAt)` with price scaled to `1e18`.
- `src/amm/libraries/PMMMath.sol` - PMM pricing and target math.
- `src/amm/libraries/PMMQuoter.sol` - pure quote and target-state logic for buy/sell paths.
- `src/amm/libraries/ValuationMath.sol` - age-adjusted `k` calculation for real-estate valuation decay.
- `src/amm/types/PMMTypes.sol` - shared PMM enums and quote/state structs.

The pool intentionally supports only standard 18-decimal ERC20 base/quote tokens. Fee-on-transfer, rebasing, and non-standard transfer behavior are rejected by balance-delta checks.
See [`src/amm/README.md`](src/amm/README.md) for the detailed design notes, including the PMM state machine, staleness-adjusted slippage model, fee accounting, circuit-breaker roles, and verified invariants.

## Safety Notes

- Swaps require a non-zero trade amount.
- Oracle prices must be non-zero, within owner-configured bounds, not timestamped in the future, and within the accepted valuation age.
- Real-estate appraisal age is handled by an age-adjusted PMM `k`: older valuations are still tradable until expiry, but receive higher price impact through staleness-adjusted slippage.
- LP withdrawals are proportional and allowed while the pool is unbalanced.
- Trading is disabled automatically when the final LP share is withdrawn.
- New liquidity can only be added when the pool is balanced.
- Maintainer fees require a non-zero maintainer address.

## Common Commands

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

## Deployment

```bash
forge script script/DeployMinimalDodoPMM.s.sol:DeployMinimalDodoPMMScript \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Required deployment environment:

- `PRIVATE_KEY`
- `BASE_TOKEN`
- `QUOTE_TOKEN`
- `ORACLE`

Operational scripts live in `script/amm`.
