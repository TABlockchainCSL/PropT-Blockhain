# AMM Module

This folder contains a minimal PMM-style AMM adapted from DODO-style pricing for a simple ERC20 `base/quote` market.

## Contracts

- `MinimalDodoPMM.sol`
  - Main AMM contract.
  - Orchestrates liquidity, trading, reserve accounting, and token transfers.
  - Public LP token is inherited from `base/EmbeddedLPToken.sol`.
  - Supports:
    - public LP mint/burn through `provideLiquidity` and `withdrawLiquidity`
    - PMM-based `buyBaseToken` and `sellBaseToken`
    - LP fee
    - maintainer fee
    - quote-only tax on buy/sell
    - owner/supervisor trading controls
    - token recovery for stray balances
  - Assumes standard 18-decimal ERC20s. Fee-on-transfer/rebasing behavior is rejected by balance-delta checks.

- `base/`
  - `AMMRoles.sol` owns owner/supervisor access control.
  - `AMMConfig.sol` owns governance configuration, oracle validation, and pricing-context assembly.
  - `EmbeddedLPToken.sol` owns the pool's ERC20-style LP share token.
  - `ReentrancyGuardLite.sol` owns the local non-reentrancy modifier.

- `interfaces/IERC20Minimal.sol`
  - ERC20 interface used by the pool. Tokens must expose `decimals()` and return `18`.

- `interfaces/IPriceOracle.sol`
  - Oracle interface. The pool expects `getPrice()` to return `(price, updatedAt)`.
  - `price` is the base price in quote terms, scaled by `1e18`.
  - `updatedAt` is treated as the last real-estate valuation/appraisal update time.
  - `updatedAt` must be non-zero, not in the future, and within the accepted valuation age.
  - Valuations remain tradable until expiry, but older valuations raise the effective PMM `k` and increase price impact.

- `libraries/DecimalMath.sol`
  - Fixed-point helpers using `1e18`.

- `libraries/MathHelpers.sol`
  - Generic math helpers like `sqrt` and `ceilDiv`.

- `libraries/PMMMath.sol`
  - Core PMM math used for pricing and target rebalancing.

- `libraries/PMMQuoter.sol`
  - Pure buy/sell quote logic and target-state calculation.

- `libraries/ValuationMath.sol`
  - Computes the age-adjusted PMM `k` from valuation age, growth rate, and configured cap.

- `types/PMMTypes.sol`
  - Shared `RStatus`, pool state, pricing state, and quote structs.

## Design Notes

### PMM State Machine

The pool keeps DODO's original `RStatus` vocabulary to stay aligned with the PMM literature and implementation lineage. The names are compact but not self-explanatory, so the operational meaning is:

| `RStatus` | Inventory frame | Price frame | Typical transition |
| --- | --- | --- | --- |
| `ONE` | `baseBalance == baseTarget` and `quoteBalance == quoteTarget` | at guide price | balanced pool |
| `ABOVE_ONE` | base depleted, quote heavy | above guide price | user buys base from the pool |
| `BELOW_ONE` | quote depleted, base heavy | below guide price | user sells base to the pool |

The pair `(baseBalance, quoteBalance)` tracks actual reserves, while `(targetBaseTokenAmount, targetQuoteTokenAmount)` tracks the PMM equilibrium reserves. The targets also absorb LP fees: sell-side LP fees increase the quote target, and buy-side LP fees increase the base target. This compounds LP value into the curve and is the reason new liquidity is only accepted when `rStatus == ONE`; otherwise a new LP could enter while accrued fees and inventory imbalance are still embedded in the target state.

### Staleness-Adjusted Slippage

The real-estate oracle does not behave like a real-time crypto price feed. Its `updatedAt` timestamp represents the latest appraisal or valuation update. Instead of forcing a hard cutoff immediately after an update becomes old, the pool computes:

```text
effectiveK(t) = min(baseK + growthPerSecond * age, maxK)
```

where `age = block.timestamp - updatedAt`. A larger `effectiveK` steepens the PMM curve, so the same trade size receives higher price impact as the valuation ages. The default constructor sets `growthPerSecond = ceil((maxK - baseK) / oracleMaxStaleness)`, which makes `effectiveK` reach `maxK` around the same time the oracle reaches its maximum accepted staleness. This aligns the slippage gradient with the oracle-validity window.

Linear growth is intentional: it is monotonic, capped, cheap to compute, and easy to audit. More realistic exponential or piecewise decay models can be swapped into `ValuationMath` later, but the current design prioritizes predictable bounds over model complexity.

### Fee and Tax Accounting

LP and maintainer fees follow the asset flowing into the pool:

- buys pay LP/maintainer fees in base, because base leaves the pool and the fee is retained from that side of the trade;
- sells pay LP/maintainer fees in quote, because quote leaves the pool and the fee is retained from that side of the trade.

This follows the DODO-style inflow-fee convention and keeps LP fee accrual symmetric across the two arms of the curve. Transaction tax is quote-denominated on both buy and sell paths so the regulatory-readiness module always accounts in the quote asset.

### Embedded LP Token

The pool contract is also the ERC20-style LP share token through `EmbeddedLPToken`. This keeps deployment simple and avoids a separate LP-token registry. The tradeoff is that `balanceOf(account)` refers to LP shares, not the pool's base or quote token balances.

### Trading Controls

Trading controls use a least-privilege circuit-breaker pattern:

| Action | Owner | Supervisor |
| --- | --- | --- |
| enable trading/buying/selling | yes | no |
| disable trading/buying/selling | yes | yes |

The supervisor can pause risk quickly but cannot unpause the market.

## Verified Invariants

The invariant suite exercises the pool through liquidity, swap, LP transfer, oracle update, fee update, and pause/unpause paths. The core properties are:

- tracked base/quote balances never exceed actual token balances held by the pool;
- an empty pool resets reserves, targets, and `RStatus` to the balanced state;
- a non-empty pool always has non-zero tracked base and quote reserves;
- `effectiveK` always stays within `[k, maxK]` while the oracle is valid;
- fee, tax, and `k` parameters stay within configured bounds;
- tracked actor LP balances sum to `totalSupply`;
- successful query outputs remain bounded by available reserves.

## Tests

AMM tests live in [`test/amm/MinimalDodoPMM.t.sol`](../../test/amm/MinimalDodoPMM.t.sol).

The suite covers:

- initial pool bootstrap state
- LP minting, LP token transfer, allowance-based transfer, and LP withdrawal
- proportional LP withdrawal from unbalanced pools
- final LP withdrawal resets targets and disables trading
- liquidity edge cases like zero-liquidity input and unbalanced-state deposits
- zero-amount swap rejection
- oracle validation for zero, expired, future-dated, and out-of-range prices
- age-adjusted `k` behavior for older appraisals
- buy path accounting
- sell path accounting
- maintainer fee behavior on both buy and sell
- tax behavior on both buy and sell
- trading pause switches and directional buy/sell switches
- access control and parameter guards
- recovery of stray tokens without draining tracked reserves
- one fuzz test to check quote monotonicity as order size grows

Run tests with:

```bash
forge test -vvv
```

## Scripts

Deployment script:

- [`script/DeployMinimalDodoPMM.s.sol`](../../script/DeployMinimalDodoPMM.s.sol)
  - Deploys a new pool.
  - Current defaults:
    - `lpFeeRate = 5e15` = `0.5%`
    - `maintainerFeeRate = 0`
    - `k = 1e17`
    - owner = deployer
    - supervisor = deployer
    - maintainer = `address(0)`

Operational scripts:

- [`script/amm/ProvideLiquidity.s.sol`](../../script/amm/ProvideLiquidity.s.sol)
  - Approves base and quote tokens to the pool.
  - Calls `provideLiquidity(baseAmountMax, quoteAmountMax, minShares)`.

- [`script/amm/EnableTrading.s.sol`](../../script/amm/EnableTrading.s.sol)
  - Enables trading after the pool has been funded.

- [`script/amm/ConfigureTax.s.sol`](../../script/amm/ConfigureTax.s.sol)
  - Sets `taxRecipient`, `buyTaxRate`, `sellTaxRate`.
  - Can enable or disable tax.

- [`script/amm/BuyBaseToken.s.sol`](../../script/amm/BuyBaseToken.s.sol)
  - Approves quote token to the pool.
  - Reads `queryBuyBaseToken`.
  - Executes `buyBaseToken`.

- [`script/amm/SellBaseToken.s.sol`](../../script/amm/SellBaseToken.s.sol)
  - Approves base token to the pool.
  - Reads `querySellBaseToken`.
  - Executes `sellBaseToken`.

- [`script/amm/WithdrawLiquidity.s.sol`](../../script/amm/WithdrawLiquidity.s.sol)
  - Burns LP shares and withdraws pro-rata base/quote reserves.

- [`script/amm/AMMScriptBase.s.sol`](../../script/amm/AMMScriptBase.s.sol)
  - Shared helper used by the scripts above.
  - Reads common env vars and resolves pool/base/quote handles.

## Typical Flow

1. Deploy the pool with `DeployMinimalDodoPMM.s.sol`.
2. Provide initial liquidity with `ProvideLiquidity.s.sol`.
3. Enable trading with `EnableTrading.s.sol`.
4. Optionally configure tax with `ConfigureTax.s.sol`.
5. Users trade through `BuyBaseToken.s.sol` or `SellBaseToken.s.sol`.
6. LPs withdraw with `WithdrawLiquidity.s.sol`.

## Required Env Vars

Common env vars used by the scripts:

- `PRIVATE_KEY`
- `POOL` for pool interaction scripts
- `BASE_TOKEN`
- `QUOTE_TOKEN`
- `ORACLE`
- `BASE_AMOUNT`
- `QUOTE_AMOUNT`
- `SHARES`
- `TAX_RECIPIENT`
- `BUY_TAX_RATE`
- `SELL_TAX_RATE`

Some env vars are only needed for specific scripts.
