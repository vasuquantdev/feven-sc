// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";

/// @notice Splits one pool's creator fee across two to four recipients.
contract FeeSplitter {
    address public immutable factory;
    address public hook;
    bytes32 public poolId;
    address public quote;
    address[] internal _recipients;
    uint16[] internal _shares;
    mapping(address => uint256) public owed;
    bool private _initialized;

    error NotFactory();
    error Initialized();
    error InvalidRecipients();
    error NotRecipient();
    error AddressOne();

    constructor(address factory_) {
        factory = factory_;
        _initialized = true;
    }

    function initialize(
        address hook_,
        bytes32 poolId_,
        address quote_,
        address[] memory recipients_,
        uint16[] memory shares_
    ) external {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert Initialized();
        if (recipients_.length < 2 || recipients_.length > 4 || recipients_.length != shares_.length) {
            revert InvalidRecipients();
        }
        uint256 total;
        for (uint256 i; i < recipients_.length; i++) {
            if (recipients_[i] == address(0) || recipients_[i] == address(1)) revert InvalidRecipients();
            for (uint256 j; j < i; j++) {
                if (recipients_[j] == recipients_[i]) revert InvalidRecipients();
            }
            total += shares_[i];
            if (shares_[i] == 0) revert InvalidRecipients();
        }
        if (total != 10_000) revert InvalidRecipients();
        _initialized = true;
        hook = hook_;
        poolId = poolId_;
        quote = quote_;
        _recipients = recipients_;
        _shares = shares_;
    }

    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    function shares() external view returns (uint16[] memory) {
        return _shares;
    }

    function distribute() external returns (uint256 amount) {
        amount = ILaunchHook(hook).claim(poolId, address(this));
        if (amount == 0) return 0;
        uint256 left = amount;
        uint256 n = _recipients.length;
        for (uint256 i; i < n; i++) {
            uint256 part = (amount * _shares[i]) / 10_000;
            owed[_recipients[i]] += part;
            left -= part;
        }
        if (left != 0) owed[_recipients[0]] += left;
    }

    function collect(address to, uint256 amount) external returns (uint256 paid) {
        if (to == address(0) || to == address(1)) revert AddressOne();
        uint256 o = owed[msg.sender];
        if (o == 0) revert NotRecipient();
        paid = amount == 0 || amount > o ? o : amount;
        owed[msg.sender] = o - paid;
        _pay(to, paid);
    }

    function rotate(address to) external {
        if (to == address(0) || to == address(1) || to == hook || to == factory) revert InvalidRecipients();
        uint256 n = _recipients.length;
        for (uint256 i; i < n; i++) {
            if (_recipients[i] == to) revert InvalidRecipients();
        }
        for (uint256 i; i < n; i++) {
            if (_recipients[i] == msg.sender) {
                _recipients[i] = to;
                owed[to] += owed[msg.sender];
                owed[msg.sender] = 0;
                return;
            }
        }
        revert NotRecipient();
    }

    receive() external payable {}

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "pay");
        } else {
            require(IERC20(quote).transfer(to, amount), "pay");
        }
    }
}
