// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../interfaces/IKYCRegistry.sol";

/// @notice Minimal pool surface used by {DividendDistribution-depositDividendsAndSync}.
interface IPMMClaim {
    function claimQuoteDividends(uint256 maxEpochs) external returns (uint256 quoteAmount);
}

/**
 * @title DividendDistribution
 * @notice Distributes rental income (stablecoin) to PropertyToken holders
 *         using a Pull Model with snapshot-based epochs.
 *
 * @dev Architecture decisions (from research):
 *      - Pull Model: O(1) deposit, O(epochs) claim — eliminates DoS risk
 *        from push-based iteration (Zhitomirskiy et al., 2023).
 *      - Snapshot-based: Uses ERC20Votes.getPastVotes() at a historical
 *        block to prevent dividend double-dipping and flash loan attacks
 *        (Zhang et al., 2024).
 *      - Checks-Effects-Interactions: All state updates happen before
 *        external calls to prevent re-entrancy (Chu et al., 2023).
 *      - PRECISION multiplier (1e18): Compensates for Solidity's lack of
 *        floating-point arithmetic in dividend-per-token calculations.
 */
contract DividendDistribution is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // ── Konstanta ─────────────────────────────────────────────────────
    uint256 public constant PRECISION = 1e18;

    // ── State Variables ───────────────────────────────────────────────
    IVotes public immutable propertyToken; // PropertyToken dari Orang 1
    IERC20 public immutable stablecoin; // USDC atau stablecoin IDR
    IKYCRegistry public immutable kycRegistry; // KYCRegistry dari Orang 1

    /**
     * @notice Represents one dividend distribution epoch.
     * @param blockNumber  Block at which balances are snapshotted
     * @param totalSupply  getPastTotalSupply(blockNumber) at snapshot
     * @param amountDeposited  Stablecoin amount deposited for this epoch
     * @param dividendPerTokenCumul  Cumulative dividend-per-token after this epoch
     */
    struct DividendEpoch {
        uint256 blockNumber;
        uint256 totalSupply;
        uint256 amountDeposited;
        uint256 dividendPerTokenCumul;
    }

    DividendEpoch[] public epochs;

    // Indeks epoch terakhir yang sudah diklaim per investor
    mapping(address => uint256) public claimedUpToEpoch;

    // ── Events ────────────────────────────────────────────────────────
    event DividendsDeposited(uint256 indexed epochIndex, uint256 blockNumber, uint256 amount, uint256 totalSupply);
    event DividendsClaimed(address indexed investor, uint256 fromEpoch, uint256 toEpoch, uint256 amountClaimed);
    event PoolSynced(address indexed pool, uint256 claimed);

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroSupply();
    error NothingToClaim();
    error InvestorNotKYCVerified(address investor);
    error ZeroAddress();
    error MaxEpochsZero();

    // ── Constructor ───────────────────────────────────────────────────
    constructor(address _propertyToken, address _stablecoin, address _kycRegistry, address _admin) {
        if (_propertyToken == address(0)) revert ZeroAddress();
        if (_stablecoin == address(0)) revert ZeroAddress();
        if (_kycRegistry == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        propertyToken = IVotes(_propertyToken);
        stablecoin = IERC20(_stablecoin);
        kycRegistry = IKYCRegistry(_kycRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DEPOSITOR_ROLE, _admin);
    }

    // ── depositDividends() ────────────────────────────────────────────
    /**
     * @notice Called by SPV/admin after receiving rental income.
     *         Caller must approve stablecoin to this contract first.
     * @dev No-sync variant. Use this when there is no pool to sync, or as a
     *      recovery path to deposit while draining a pool's epoch backlog
     *      out-of-band via the pool's own paginated claim.
     * @param amount Amount of stablecoin to deposit as dividends
     */
    function depositDividends(uint256 amount) external onlyRole(DEPOSITOR_ROLE) nonReentrant {
        _depositDividends(amount);
    }

    // ── depositDividendsAndSync() ─────────────────────────────────────
    /**
     * @notice Deposit dividends and atomically push them into a pool's LP
     *         accounting in the same transaction.
     * @dev Closes the post-deposit window where a pool's earned-but-unaccounted
     *      dividends could be captured before a separate manual claim. The new
     *      epoch is deposited and accounted to the pool in the same transaction.
     *      LP deposits ordered before this transaction remain outside this
     *      guarantee.
     *
     *      The pool's claim runs as a nested call back into {claimDividends},
     *      so this function is intentionally NOT `nonReentrant` — otherwise the
     *      callback would hit the held guard and revert. Reentrancy is bounded
     *      instead by `onlyRole(DEPOSITOR_ROLE)` + checks-effects-interactions
     *      in {_depositDividends} + the guards on {claimDividends}.
     *
     *      Hard-sync (no try/catch): if the pool claim reverts, the entire
     *      deposit reverts. `maxEpochs` is auto-filled to claim *all* of the
     *      pool's pending epochs, so no residual unaccounted dividend is left.
     * @param amount Stablecoin amount to deposit as dividends
     * @param pool   Pool to sync (must expose claimQuoteDividends)
     */
    // slither-disable-next-line reentrancy-no-eth
    function depositDividendsAndSync(uint256 amount, address pool) external onlyRole(DEPOSITOR_ROLE) {
        if (pool == address(0)) revert ZeroAddress();
        _depositDividends(amount);
        uint256 claimed = IPMMClaim(pool).claimQuoteDividends(type(uint256).max);
        emit PoolSynced(pool, claimed);
    }

    /// @dev Shared deposit logic. CEI: epoch is pushed before the token pull.
    function _depositDividends(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        // Gunakan block sebelumnya agar getPastTotalSupply valid
        uint256 snapshotBlock = block.number - 1;
        uint256 supply = propertyToken.getPastTotalSupply(snapshotBlock);
        // slither-disable-next-line incorrect-equality
        if (supply < 1) revert ZeroSupply();

        // Hitung penambahan akumulator global (kalikan PRECISION dahulu)
        uint256 prevCumul = epochs.length > 0 ? epochs[epochs.length - 1].dividendPerTokenCumul : 0;
        uint256 addition = (amount * PRECISION) / supply;

        // [EFFECT] — perbarui state sebelum transfer
        epochs.push(
            DividendEpoch({
                blockNumber: snapshotBlock,
                totalSupply: supply,
                amountDeposited: amount,
                dividendPerTokenCumul: prevCumul + addition
            })
        );

        // [INTERACTION] — taruh setelah semua state diperbarui
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);

        emit DividendsDeposited(epochs.length - 1, snapshotBlock, amount, supply);
    }

    // ── claimDividends() ─────────────────────────────────────────────
    /**
     * @notice Investor calls this to withdraw unclaimed dividends.
     * @dev Uses getPastVotes() to look up historical balance at each
     *      epoch's snapshot block — immune to flash loan manipulation.
     *      Pagination via maxEpochs prevents gas DoS when many epochs
     *      are unclaimed (Slither: calls-loop mitigation).
     * @param maxEpochs Maximum number of epochs to process in one tx
     */
    function claimDividends(uint256 maxEpochs) external nonReentrant {
        if (maxEpochs < 1) revert MaxEpochsZero();

        // [CHECK] KYC or approved contract authorization.
        if (!kycRegistry.isVerified(msg.sender) && !kycRegistry.isApprovedContract(msg.sender)) {
            revert InvestorNotKYCVerified(msg.sender);
        }

        uint256 start = claimedUpToEpoch[msg.sender];
        uint256 totalEpochs = epochs.length;
        if (start >= totalEpochs) revert NothingToClaim();

        // Cap the end index to avoid gas DoS from unbounded loop
        uint256 remaining = totalEpochs - start;
        uint256 end = maxEpochs >= remaining ? totalEpochs : start + maxEpochs;

        uint256 totalClaim = 0;
        for (uint256 i = start; i < end;) {
            // slither-disable-next-line calls-loop
            uint256 bal = propertyToken.getPastVotes(msg.sender, epochs[i].blockNumber);
            if (bal > 0) {
                uint256 epochDpt = epochs[i].dividendPerTokenCumul - (i > 0 ? epochs[i - 1].dividendPerTokenCumul : 0);
                totalClaim += (bal * epochDpt) / PRECISION;
            }
            unchecked {
                ++i;
            }
        }

        // [EFFECT] — perbarui state SEBELUM transfer (anti-reentrancy)
        claimedUpToEpoch[msg.sender] = end;

        // [INTERACTION]
        if (totalClaim > 0) {
            stablecoin.safeTransfer(msg.sender, totalClaim);
        }

        emit DividendsClaimed(msg.sender, start, end, totalClaim);
    }

    // ── View Functions ────────────────────────────────────────────────
    /**
     * @notice Check how much dividend an investor can claim.
     * @param investor  Address of the investor
     * @param maxEpochs Maximum epochs to iterate (pagination)
     * @return total Amount of stablecoin claimable
     */
    function pendingDividends(address investor, uint256 maxEpochs) external view returns (uint256 total) {
        uint256 start = claimedUpToEpoch[investor];
        uint256 totalEpochs = epochs.length;
        if (totalEpochs <= start) return 0;

        uint256 remaining = totalEpochs - start;
        uint256 end = maxEpochs >= remaining ? totalEpochs : start + maxEpochs;

        for (uint256 i = start; i < end;) {
            // slither-disable-next-line calls-loop
            uint256 bal = propertyToken.getPastVotes(investor, epochs[i].blockNumber);
            if (bal > 0) {
                uint256 dpt = epochs[i].dividendPerTokenCumul - (i > 0 ? epochs[i - 1].dividendPerTokenCumul : 0);
                total += (bal * dpt) / PRECISION;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get total number of dividend epochs.
     */
    function getEpochCount() external view returns (uint256) {
        return epochs.length;
    }

    /**
     * @notice Get details of a specific epoch.
     * @param idx Index of the epoch (0-based)
     */
    function getEpoch(uint256 idx) external view returns (DividendEpoch memory) {
        return epochs[idx];
    }
}
