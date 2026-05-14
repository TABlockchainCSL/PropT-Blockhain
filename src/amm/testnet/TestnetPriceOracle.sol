// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract TestnetPriceOracle is IPriceOracle {
    address public owner;
    uint256 public price;
    uint256 public updatedAt;

    event PriceUpdated(uint256 price, uint256 updatedAt);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        _setPrice(initialPrice, block.timestamp);
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        _setPrice(newPrice, block.timestamp);
    }

    function setPriceWithTimestamp(uint256 newPrice, uint256 newUpdatedAt) external onlyOwner {
        require(newUpdatedAt <= block.timestamp, "FUTURE_TIMESTAMP");
        _setPrice(newPrice, newUpdatedAt);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    function getPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function _setPrice(uint256 newPrice, uint256 newUpdatedAt) internal {
        require(newPrice > 0, "INVALID_PRICE");
        price = newPrice;
        updatedAt = newUpdatedAt;
        emit PriceUpdated(newPrice, newUpdatedAt);
    }
}
