// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/IKYCRegistry.sol";

/**
 * @title PropertyToken
 * @notice ERC-20 token representing fractional ownership of a single
 *         real estate property. One property = one token (RealT model).
 *
 * @dev - Deployed as BeaconProxy (all tokens share one implementation).
 *      - Transfers are restricted to KYC-verified addresses only.
 *      - Uses ERC20Votes for balance snapshots (dividends & voting).
 *      - Uses ERC20Permit for gasless approvals (useful for AMM integration).
 */
contract PropertyToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable
{
    IKYCRegistry public kycRegistry;
    uint256 public propertyId;
    uint8 public requiredKYCLevel;
    address public pauser;

    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);

    error SenderNotAuthorized(address sender);
    error RecipientNotAuthorized(address recipient);
    error InsufficientKYCLevel(address user, uint8 required, uint8 actual);
    error InvalidRequiredKYCLevel(uint8 level);
    error NotPauserOrOwner(address caller);

    modifier onlyPauserOrOwner() {
        if (msg.sender != pauser && msg.sender != owner()) {
            revert NotPauserOrOwner(msg.sender);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the token (called once by BeaconProxy on deployment).
     * @param _name Token name, e.g. "RealToken - Sudirman St. No. 1"
     * @param _symbol Token symbol, e.g. "RTJKS1"
     * @param _totalSupply How many fractional tokens to mint
     * @param _propertyId Property ID in the PropertyRegistry
     * @param _kycRegistry KYCRegistry proxy address
     * @param _requiredKYCLevel Minimum KYC level needed to transfer (1 or 2)
     * @param _owner Deployer who receives all initial tokens
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        uint256 _propertyId,
        address _kycRegistry,
        uint8 _requiredKYCLevel,
        address _owner
    ) external initializer {
        if (_requiredKYCLevel == 0 || _requiredKYCLevel > 2) {
            revert InvalidRequiredKYCLevel(_requiredKYCLevel);
        }

        __ERC20_init(_name, _symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init(_name);
        __ERC20Votes_init();
        __Ownable_init(_owner);

        kycRegistry = IKYCRegistry(_kycRegistry);
        propertyId = _propertyId;
        requiredKYCLevel = _requiredKYCLevel;

        _mint(_owner, _totalSupply);
        emit TokensMinted(_owner, _totalSupply);
    }

    /**
     * @dev Override _update to enforce authorization on every transfer.
     *      Minting (from == 0) and burning (to == 0) skip the check.
     *      Each address must be either:
     *        - A KYC-verified human (EOA) with sufficient level, OR
     *        - An admin-approved contract (DEX pool, marketplace, etc.)
     *      Also updates voting checkpoints via ERC20Votes.
     */
    function _update(
        address from,
        address to,
        uint256 value
    )
        internal
        override(
            ERC20Upgradeable,
            ERC20PausableUpgradeable,
            ERC20VotesUpgradeable
        )
    {
        // Only check authorization for regular transfers (not mint/burn)
        if (from != address(0) && to != address(0)) {
            _checkAuthorized(from, true);
            _checkAuthorized(to, false);
        }

        super._update(from, to, value);
    }

    /**
     * @dev Check if an address is authorized to send/receive tokens.
     *      Authorized means: KYC-verified with sufficient level, OR approved contract.
     */
    function _checkAuthorized(address addr, bool isSender) internal view {
        // Fast path: check if it's an approved contract (DEX, marketplace)
        if (kycRegistry.isApprovedContract(addr)) {
            return;
        }

        // Otherwise, must be a KYC-verified user with sufficient level
        uint8 level = kycRegistry.getKYCLevel(addr);
        if (level == 0) {
            if (isSender) {
                revert SenderNotAuthorized(addr);
            } else {
                revert RecipientNotAuthorized(addr);
            }
        }
        if (level < requiredKYCLevel) {
            revert InsufficientKYCLevel(addr, requiredKYCLevel, level);
        }
    }

    /// @dev Resolves the nonces conflict between ERC20Permit and Nonces
    function nonces(
        address owner
    )
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @notice Mint additional tokens (e.g. for staged fundraising)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /// @notice Pause all transfers (for emergencies).
    ///         Can be called by pauser (fast, no delay) or owner (via Timelock).
    function pause() external onlyPauserOrOwner {
        _pause();
    }

    /// @notice Resume transfers. Only owner (via Timelock) can unpause.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the pauser address. Only owner (via Timelock) can change.
    /// @param _pauser New pauser address (can be EOA or fast multisig)
    function setPauser(address _pauser) external onlyOwner {
        address oldPauser = pauser;
        pauser = _pauser;
        emit PauserUpdated(oldPauser, _pauser);
    }

    /// @dev Reserved storage gap for future upgrades
    uint256[46] private __gap;
}
