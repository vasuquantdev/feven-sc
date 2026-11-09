// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Receives the protocol's share of swap fees and the launch fee.
contract ProtocolFeeVault {
    address public owner;

    event OwnershipTransferred(address indexed previous, address indexed current);

    error NotOwner();

    constructor(address owner_) {
        owner = owner_;
    }

    receive() external payable {}

    function sweepNative(address to) external returns (uint256 amount) {
        if (msg.sender != owner) revert NotOwner();
        amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native transfer");
    }

    function sweepToken(address token, address to) external returns (uint256 amount) {
        if (msg.sender != owner) revert NotOwner();
        amount = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transfer(to, amount), "token transfer");
    }

    function transferOwnership(address next) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }
}
