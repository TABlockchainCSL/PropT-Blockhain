// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

abstract contract ReentrancyGuardLite {
    bool private entered;

    modifier nonReentrant() {
        require(!entered, "REENTRANT");
        entered = true;
        _;
        entered = false;
    }
}
