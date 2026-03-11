# Interfaces

Shared interfaces for all modules. Import from here when you need to interact with core contracts.

## Available Interfaces

| Interface | What you get | Typical use case |
|-----------|-------------|-----------------|
| `IKYCRegistry` | `isVerified()`, `getKYCLevel()` | Check if a user is KYC-approved before doing something |
| `IPropertyToken` | ERC-20 + Votes + Permit | Read balances, snapshots, do transfers |
| `IPropertyRegistry` | `getProperty()`, `getPropertyByToken()` | Look up property metadata (value, IPFS docs, etc.) |
| `IPropertyTokenFactory` | `getTokenByPropertyId()`, `getDeployedTokens()` | Find which token belongs to which property |

## Usage Example

```solidity
import "../interfaces/IPropertyToken.sol";
import "../interfaces/IKYCRegistry.sol";
import "../interfaces/IPropertyRegistry.sol";

contract DividendDistributor {
    IPropertyToken public token;

    // Calculate dividend share from voting snapshot
    function getShare(address user, uint256 block) external view returns (uint256) {
        uint256 userVotes = token.getPastVotes(user, block);
        uint256 totalVotes = token.getPastTotalSupply(block);
        return userVotes * 1e18 / totalVotes; // share as fraction
    }
}
```

## Notes

- Structs, events, and errors are defined in the interfaces — contracts inherit them via `is IInterface`
- If you need a struct type (e.g. `Property`), reference it as `IPropertyRegistry.Property`
