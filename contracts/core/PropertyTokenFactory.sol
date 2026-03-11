// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../interfaces/IPropertyTokenFactory.sol";
import "../interfaces/IPropertyRegistry.sol";
import "../interfaces/IKYCRegistry.sol";
import "./PropertyToken.sol";

/**
 * @title PropertyTokenFactory
 * @notice Factory for deploying new PropertyToken proxies via UpgradeableBeacon.
 *         Automatically registers each new token in PropertyRegistry.
 *         One property = one ERC-20 token (RealT model).
 * @dev - Upgradeable via UUPS proxy pattern.
 *      - Deploys BeaconProxy instances, so upgrading the beacon updates ALL tokens.
 *      - Still imports PropertyToken.sol for abi.encodeCall (no bytecode bloat
 *        since we don't use `new PropertyToken()`).
 */
contract PropertyTokenFactory is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IPropertyTokenFactory
{
    IKYCRegistry public kycRegistry;
    IPropertyRegistry public propertyRegistry;
    address public tokenBeacon;

    address[] private _deployedTokens;
    mapping(uint256 => address) private _propertyIdToToken;

    error EmptyString(string field);
    error ZeroValue(string field);
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the factory.
     * @param _kycRegistry KYCRegistry proxy address
     * @param _propertyRegistry PropertyRegistry proxy address
     * @param _tokenBeacon UpgradeableBeacon that holds the PropertyToken implementation
     */
    function initialize(
        address _kycRegistry,
        address _propertyRegistry,
        address _tokenBeacon
    ) external initializer {
        if (_kycRegistry == address(0)) revert ZeroAddress();
        if (_propertyRegistry == address(0)) revert ZeroAddress();
        if (_tokenBeacon == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);

        kycRegistry = IKYCRegistry(_kycRegistry);
        propertyRegistry = IPropertyRegistry(_propertyRegistry);
        tokenBeacon = _tokenBeacon;
    }

    /**
     * @notice Deploy a new property token proxy and register it in the registry.
     * @param params All the params needed (name, symbol, supply, etc.)
     * @return tokenAddress Address of the newly deployed token proxy
     * @return propertyId Property ID in the registry
     */
    function createPropertyToken(
        CreateTokenParams calldata params
    )
        external
        onlyOwner
        nonReentrant
        returns (address tokenAddress, uint256 propertyId)
    {
        _validateParams(params);

        propertyId = propertyRegistry.getNextPropertyId();

        // Encode the initialize() call for the BeaconProxy
        bytes memory initData = abi.encodeCall(
            PropertyToken.initialize,
            (
                params.name,
                params.symbol,
                params.totalSupply,
                propertyId,
                address(kycRegistry),
                params.requiredKYCLevel,
                msg.sender
            )
        );

        // Deploy a BeaconProxy that delegates to the shared implementation
        BeaconProxy proxy = new BeaconProxy(tokenBeacon, initData);
        tokenAddress = address(proxy);

        propertyRegistry.registerProperty(
            params.propertyName,
            params.propertyAddress,
            params.totalValue,
            params.ipfsDocumentURI,
            tokenAddress
        );

        _deployedTokens.push(tokenAddress);
        _propertyIdToToken[propertyId] = tokenAddress;

        emit PropertyTokenCreated(
            propertyId,
            tokenAddress,
            params.name,
            params.symbol,
            params.totalSupply
        );

        return (tokenAddress, propertyId);
    }

    /// @notice Get token address by property ID
    function getTokenByPropertyId(
        uint256 propertyId
    ) external view returns (address) {
        return _propertyIdToToken[propertyId];
    }

    /// @notice List all tokens that have been deployed
    function getDeployedTokens() external view returns (address[] memory) {
        return _deployedTokens;
    }

    /// @notice How many tokens have been deployed
    function getDeployedTokenCount() external view returns (uint256) {
        return _deployedTokens.length;
    }

    /// @dev Validate all input params before deploying
    function _validateParams(CreateTokenParams calldata params) internal pure {
        if (bytes(params.name).length == 0) revert EmptyString("name");
        if (bytes(params.symbol).length == 0) revert EmptyString("symbol");
        if (params.totalSupply == 0) revert ZeroValue("totalSupply");
        if (bytes(params.propertyName).length == 0)
            revert EmptyString("propertyName");
        if (bytes(params.propertyAddress).length == 0)
            revert EmptyString("propertyAddress");
        if (params.totalValue == 0) revert ZeroValue("totalValue");
        if (bytes(params.ipfsDocumentURI).length == 0)
            revert EmptyString("ipfsDocumentURI");
    }

    /// @dev Only owner can authorize upgrades
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;
}
