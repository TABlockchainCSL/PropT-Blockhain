// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPropertyTokenFactory
 * @notice Interface for querying tokens deployed by the factory.
 */
interface IPropertyTokenFactory {
    struct CreateTokenParams {
        string name;
        string symbol;
        uint256 totalSupply;
        string propertyName;
        string propertyAddress;
        uint256 totalValue;
        string ipfsDocumentURI;
        uint8 requiredKYCLevel;
    }

    event PropertyTokenCreated(
        uint256 indexed propertyId,
        address indexed tokenAddress,
        string name,
        string symbol,
        uint256 totalSupply
    );

    /// @notice Get token address by property ID
    function getTokenByPropertyId(
        uint256 propertyId
    ) external view returns (address);

    /// @notice List all deployed tokens
    function getDeployedTokens() external view returns (address[] memory);

    /// @notice How many tokens have been deployed
    function getDeployedTokenCount() external view returns (uint256);

    /// @notice Address of the UpgradeableBeacon for PropertyToken
    function tokenBeacon() external view returns (address);
}
