// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Assets a launch is allowed to pair against. Native gas is address(0).
contract QuoteRegistry {
    struct Quote {
        uint8 decimals;
        bool enabled;
        bool exists;
    }

    mapping(address quote => Quote) public quotes;
    address public owner;

    event QuoteRegistered(address indexed quote, uint8 decimals, string symbol);
    event QuoteEnabled(address indexed quote, bool enabled);
    event OwnershipTransferred(address indexed previous, address indexed current);

    error NotOwner();
    error BadDecimals();
    error Exists();
    error UnknownQuote();
    error ZeroAddress();

    constructor(address owner_) {
        owner = owner_;
    }

    function register(address quote, uint8 decimals, string calldata symbol) external {
        if (msg.sender != owner) revert NotOwner();
        if (decimals < 6 || decimals > 18) revert BadDecimals();
        if (quotes[quote].exists) revert Exists();
        quotes[quote] = Quote({decimals: decimals, enabled: true, exists: true});
        emit QuoteRegistered(quote, decimals, symbol);
    }

    function setEnabled(address quote, bool enabled) external {
        if (msg.sender != owner) revert NotOwner();
        if (!quotes[quote].exists) revert UnknownQuote();
        quotes[quote].enabled = enabled;
        emit QuoteEnabled(quote, enabled);
    }

    function isEnabled(address quote) external view returns (bool) {
        return quotes[quote].enabled;
    }

    function transferOwnership(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }
}
