// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

abstract contract AMMRoles {
    address public owner;
    address public supervisor;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event SupervisorUpdated(address indexed oldSupervisor, address indexed newSupervisor);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlySupervisorOrOwner() {
        require(msg.sender == owner || msg.sender == supervisor, "NOT_SUPERVISOR_OR_OWNER");
        _;
    }

    constructor(address owner_, address supervisor_) {
        require(owner_ != address(0), "INVALID_OWNER");
        owner = owner_;
        supervisor = supervisor_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setSupervisor(address newSupervisor) external onlyOwner {
        emit SupervisorUpdated(supervisor, newSupervisor);
        supervisor = newSupervisor;
    }
}
