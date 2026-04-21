// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../interfaces/IKYCRegistry.sol";

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
    IVotes public immutable propertyToken;    // PropertyToken dari Orang 1
    IERC20 public immutable stablecoin;       // USDC atau stablecoin IDR
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
    event DividendsDeposited(
        uint256 indexed epochIndex,
        uint256 blockNumber,
        uint256 amount,
        uint256 totalSupply
    );
    event DividendsClaimed(
        address indexed investor,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 amountClaimed
    );

    // ── Errors ────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroSupply();
    error NothingToClaim();
    error InvestorNotKYCVerified(address investor);
    error ZeroAddress();
    error MaxEpochsZero();

    // ── Constructor ───────────────────────────────────────────────────
    constructor(
        address _propertyToken,
        address _stablecoin,
        address _kycRegistry,
        address _admin
    ) {
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
     * @param amount Amount of stablecoin to deposit as dividends
     */
    function depositDividends(uint256 amount)
        external
        onlyRole(DEPOSITOR_ROLE)
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();

        // Gunakan block sebelumnya agar getPastTotalSupply valid
        uint256 snapshotBlock = block.number - 1;
        uint256 supply = propertyToken.getPastTotalSupply(snapshotBlock);
        // slither-disable-next-line incorrect-equality
        if (supply < 1) revert ZeroSupply();

        // Hitung penambahan akumulator global (kalikan PRECISION dahulu)
        uint256 prevCumul = epochs.length > 0
            ? epochs[epochs.length - 1].dividendPerTokenCumul
            : 0;
        uint256 addition = (amount * PRECISION) / supply;

        // [EFFECT] — perbarui state sebelum transfer
        epochs.push(DividendEpoch({
            blockNumber: snapshotBlock,
            totalSupply: supply,
            amountDeposited: amount,
            dividendPerTokenCumul: prevCumul + addition
        }));

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

        // [CHECK] KYC
        if (kycRegistry.getKYCLevel(msg.sender) == 0)
            revert InvestorNotKYCVerified(msg.sender);

        uint256 start = claimedUpToEpoch[msg.sender];
        uint256 totalEpochs = epochs.length;
        if (start >= totalEpochs) revert NothingToClaim();

        // Cap the end index to avoid gas DoS from unbounded loop
        uint256 remaining = totalEpochs - start;
        uint256 end = maxEpochs >= remaining ? totalEpochs : start + maxEpochs;

        uint256 totalClaim = 0;
        for (uint256 i = start; i < end; ) {
            // slither-disable-next-line calls-loop
            uint256 bal = propertyToken.getPastVotes(
                msg.sender,
                epochs[i].blockNumber
            );
            if (bal > 0) {
                uint256 epochDpt = epochs[i].dividendPerTokenCumul
                    - (i > 0 ? epochs[i-1].dividendPerTokenCumul : 0);
                totalClaim += (bal * epochDpt) / PRECISION;
            }
            unchecked { ++i; }
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
    function pendingDividends(address investor, uint256 maxEpochs)
        external view returns (uint256 total)
    {
        uint256 start = claimedUpToEpoch[investor];
        uint256 totalEpochs = epochs.length;
        if (totalEpochs <= start) return 0;

        uint256 remaining = totalEpochs - start;
        uint256 end = maxEpochs >= remaining ? totalEpochs : start + maxEpochs;

        for (uint256 i = start; i < end; ) {
            // slither-disable-next-line calls-loop
            uint256 bal = propertyToken.getPastVotes(
                investor, epochs[i].blockNumber
            );
            if (bal > 0) {
                uint256 dpt = epochs[i].dividendPerTokenCumul
                    - (i > 0 ? epochs[i-1].dividendPerTokenCumul : 0);
                total += (bal * dpt) / PRECISION;
            }
            unchecked { ++i; }
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
    function getEpoch(uint256 idx)
        external view returns (DividendEpoch memory)
    {
        return epochs[idx];
    }
}
