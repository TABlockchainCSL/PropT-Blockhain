// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IPropertyRegistry.sol";

/**
 * @title PropertyRegistry
 * @notice Stores real estate property metadata on-chain.
 *         Ownership documents, photos, etc. live on IPFS —
 *         this contract only stores the CID/URI references.
 * @dev Upgradeable via UUPS proxy pattern.
 */
contract PropertyRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IPropertyRegistry {
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    uint256 private _nextPropertyId;
    mapping(uint256 => Property) private _properties;
    uint256[] private _propertyIds;

    // Reverse lookup: token address -> property ID
    mapping(address => uint256) private _tokenToProperty;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (replaces constructor for proxies)
    function initialize() external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRY_ADMIN_ROLE, msg.sender);
        _nextPropertyId = 1; // start from 1 so 0 can be used as sentinel
    }

    /**
     * @notice Register a new property.
     * @param propertyName Name of the property
     * @param propertyAddress Physical address
     * @param totalValue Total property value
     * @param ipfsDocumentURI IPFS CID for documents
     * @param tokenAddress Associated PropertyToken address
     * @return The newly assigned property ID
     */
    function registerProperty(
        string calldata propertyName,
        string calldata propertyAddress,
        uint256 totalValue,
        string calldata ipfsDocumentURI,
        address tokenAddress
    ) external onlyRole(REGISTRY_ADMIN_ROLE) returns (uint256) {
        if (bytes(propertyName).length == 0) revert EmptyString("propertyName");
        if (bytes(propertyAddress).length == 0) {
            revert EmptyString("propertyAddress");
        }
        if (bytes(ipfsDocumentURI).length == 0) {
            revert EmptyString("ipfsDocumentURI");
        }
        if (totalValue == 0) revert ZeroValue("totalValue");
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_tokenToProperty[tokenAddress] != 0) {
            revert TokenAlreadyRegistered(tokenAddress);
        }

        uint256 propertyId = _nextPropertyId++;

        _properties[propertyId] = Property({
            propertyId: propertyId,
            propertyName: propertyName,
            propertyAddress: propertyAddress,
            totalValue: totalValue,
            ipfsDocumentURI: ipfsDocumentURI,
            tokenAddress: tokenAddress,
            isActive: true,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        _propertyIds.push(propertyId);
        _tokenToProperty[tokenAddress] = propertyId;

        emit PropertyRegistered(propertyId, propertyName, tokenAddress, ipfsDocumentURI);
        return propertyId;
    }

    /**
     * @notice Update the IPFS document URI (e.g. new documents or photos).
     * @param propertyId Property ID
     * @param newURI New IPFS CID/URI
     */
    function updateIPFSDocument(uint256 propertyId, string calldata newURI) external onlyRole(REGISTRY_ADMIN_ROLE) {
        Property storage prop = _getActiveProperty(propertyId);
        if (bytes(newURI).length == 0) revert EmptyString("ipfsDocumentURI");

        string memory oldURI = prop.ipfsDocumentURI;
        prop.ipfsDocumentURI = newURI;
        prop.updatedAt = block.timestamp;

        emit IPFSDocumentUpdated(propertyId, oldURI, newURI);
    }

    /// @notice Update property name
    function updatePropertyName(uint256 propertyId, string calldata newName) external onlyRole(REGISTRY_ADMIN_ROLE) {
        Property storage prop = _getActiveProperty(propertyId);
        if (bytes(newName).length == 0) revert EmptyString("propertyName");

        prop.propertyName = newName;
        prop.updatedAt = block.timestamp;

        emit PropertyUpdated(propertyId, "propertyName");
    }

    /// @notice Update total property value
    function updatePropertyValue(uint256 propertyId, uint256 newValue) external onlyRole(REGISTRY_ADMIN_ROLE) {
        Property storage prop = _getActiveProperty(propertyId);
        if (newValue == 0) revert ZeroValue("totalValue");

        prop.totalValue = newValue;
        prop.updatedAt = block.timestamp;

        emit PropertyUpdated(propertyId, "totalValue");
    }

    /// @notice Deactivate a property (soft delete, data is preserved)
    function deactivateProperty(uint256 propertyId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        Property storage prop = _getActiveProperty(propertyId);
        prop.isActive = false;
        prop.updatedAt = block.timestamp;

        emit PropertyDeactivated(propertyId);
    }

    /// @notice Re-activate a previously deactivated property
    function reactivateProperty(uint256 propertyId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (_properties[propertyId].propertyId == 0) {
            revert PropertyNotFound(propertyId);
        }
        Property storage prop = _properties[propertyId];
        prop.isActive = true;
        prop.updatedAt = block.timestamp;

        emit PropertyReactivated(propertyId);
    }

    /// @notice Get property data by ID
    function getProperty(uint256 propertyId) external view returns (Property memory) {
        if (_properties[propertyId].propertyId == 0) {
            revert PropertyNotFound(propertyId);
        }
        return _properties[propertyId];
    }

    /// @notice Get property data by its token address
    function getPropertyByToken(address tokenAddress) external view returns (Property memory) {
        uint256 propertyId = _tokenToProperty[tokenAddress];
        if (propertyId == 0) revert PropertyNotFound(0);
        return _properties[propertyId];
    }

    /// @notice How many properties are registered
    function getPropertyCount() external view returns (uint256) {
        return _propertyIds.length;
    }

    /// @notice List all property IDs
    function getAllPropertyIds() external view returns (uint256[] memory) {
        return _propertyIds;
    }

    /// @notice Next auto-increment ID
    function getNextPropertyId() external view returns (uint256) {
        return _nextPropertyId;
    }

    /// @dev Helper to get a property that must exist and be active
    function _getActiveProperty(uint256 propertyId) internal view returns (Property storage) {
        if (_properties[propertyId].propertyId == 0) {
            revert PropertyNotFound(propertyId);
        }
        if (!_properties[propertyId].isActive) {
            revert PropertyNotActive(propertyId);
        }
        return _properties[propertyId];
    }

    /// @dev Only DEFAULT_ADMIN_ROLE can authorize upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Reserved storage gap for future upgrades
    uint256[45] private __gap;
}
