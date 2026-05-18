// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPropertyRegistry
 * @notice Interface for reading registered property metadata.
 *
 * Example:
 *   IPropertyRegistry.Property memory prop = registry.getProperty(id);
 *   // prop.totalValue    -> property value
 *   // prop.tokenAddress  -> ERC-20 token address
 *   // prop.ipfsDocumentURI -> IPFS document link
 */
interface IPropertyRegistry {
    struct Property {
        uint256 propertyId;
        string propertyName;
        string propertyAddress;
        uint256 totalValue;
        string ipfsDocumentURI;
        address tokenAddress;
        bool isActive;
        uint256 createdAt;
        uint256 updatedAt;
    }

    event PropertyRegistered(
        uint256 indexed propertyId, string propertyName, address indexed tokenAddress, string ipfsDocumentURI
    );
    event PropertyUpdated(uint256 indexed propertyId, string field);
    event IPFSDocumentUpdated(uint256 indexed propertyId, string oldURI, string newURI);
    event PropertyDeactivated(uint256 indexed propertyId);
    event PropertyReactivated(uint256 indexed propertyId);

    error PropertyNotFound(uint256 propertyId);
    error PropertyNotActive(uint256 propertyId);
    error TokenAlreadyRegistered(address tokenAddress);
    error EmptyString(string field);
    error ZeroValue(string field);
    error ZeroAddress();

    /// @notice Get property data by ID
    function getProperty(uint256 propertyId) external view returns (Property memory);

    /// @notice Get property data by its token address
    function getPropertyByToken(address tokenAddress) external view returns (Property memory);

    /// @notice How many properties are registered
    function getPropertyCount() external view returns (uint256);

    /// @notice List all property IDs
    function getAllPropertyIds() external view returns (uint256[] memory);

    /// @notice Register a new property
    function registerProperty(
        string calldata propertyName,
        string calldata propertyAddress,
        uint256 totalValue,
        string calldata ipfsDocumentURI,
        address tokenAddress
    ) external returns (uint256);

    /// @notice Next auto-increment ID
    function getNextPropertyId() external view returns (uint256);
}
