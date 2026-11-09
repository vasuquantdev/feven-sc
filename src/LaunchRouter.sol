// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Exact-input swaps against one launch pool.
contract LaunchRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error Slippage();
    error Value();
    error RefundFailed();

    struct SwapCall {
        address payer;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        external
        payable
        returns (uint256 amountOut)
    {
        bool nativeIn = zeroForOne ? Currency.unwrap(key.currency0) == address(0) : Currency.unwrap(key.currency1) == address(0);
        if (nativeIn) {
            if (msg.value != amountIn) revert Value();
        } else if (msg.value != 0) {
            revert Value();
        }
        uint256 prior = address(this).balance - msg.value;
        amountOut = abi.decode(
            poolManager.unlock(abi.encode(SwapCall({payer: msg.sender, key: key, zeroForOne: zeroForOne, amountIn: amountIn, minOut: minOut}))),
            (uint256)
        );
        uint256 surplus = address(this).balance - prior;
        if (surplus != 0) {
            (bool ok,) = msg.sender.call{value: surplus}("");
            if (!ok) revert RefundFailed();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapCall memory call_ = abi.decode(data, (SwapCall));
        BalanceDelta delta = poolManager.swap(
            call_.key,
            SwapParams({
                zeroForOne: call_.zeroForOne,
                amountSpecified: -int256(call_.amountIn),
                sqrtPriceLimitX96: call_.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = call_.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = call_.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert Slippage();
        uint256 owed = uint256(uint128(-inDelta));
        uint256 out = uint256(uint128(outDelta));
        if (out < call_.minOut) revert Slippage();

        Currency input = call_.zeroForOne ? call_.key.currency0 : call_.key.currency1;
        Currency output = call_.zeroForOne ? call_.key.currency1 : call_.key.currency0;
        poolManager.sync(input);
        if (input.isAddressZero()) {
            poolManager.settle{value: owed}();
        } else {
            if (!IERC20(Currency.unwrap(input)).transferFrom(call_.payer, address(poolManager), owed)) revert Slippage();
            poolManager.settle();
        }
        poolManager.take(output, call_.payer, out);
        return abi.encode(out);
    }

    receive() external payable {}
}
