// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 with customizable decimals.
contract TestnetERC20 is ERC20 {
    uint8 public immutable DECIMALS;
    address public kycRegistry;

    event KycRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
    }

    /// @notice Set the KYC registry advertised to PropertyPMM.
    function setKycRegistry(address newKycRegistry) external {
        emit KycRegistryUpdated(kycRegistry, newKycRegistry);
        kycRegistry = newKycRegistry;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        require(to != address(0), "INVALID_RECEIVER");
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != address(0), "INVALID_RECEIVER");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(to != address(0), "INVALID_RECEIVER");
        return super.transferFrom(from, to, amount);
    }
}
