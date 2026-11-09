// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @notice Opening-tick adjustment so a custom supply keeps the same market cap.
library OpeningMath {
    int24 internal constant SPACING = 200;

    function adjustedTick(int24 baseTick, uint256 supply, uint256 baseSupply, bool tokenIsCurrency0)
        internal
        pure
        returns (int24)
    {
        int24 tick = baseTick;
        if (supply != baseSupply) {
            uint160 sqrtBase = TickMath.getSqrtPriceAtTick(baseTick);
            uint256 sqrtSupply = _sqrt(supply);
            uint256 sqrtBaseSupply = _sqrt(baseSupply);
            uint256 next = tokenIsCurrency0
                ? FullMath.mulDiv(sqrtBase, sqrtBaseSupply, sqrtSupply)
                : FullMath.mulDiv(sqrtBase, sqrtSupply, sqrtBaseSupply);
            if (next < TickMath.MIN_SQRT_PRICE || next >= TickMath.MAX_SQRT_PRICE) revert TickOutOfRange(int256(baseTick));
            tick = TickMath.getTickAtSqrtPrice(uint160(next));
        }
        tick = align(tick);
        int24 minTick = TickMath.minUsableTick(SPACING);
        int24 maxTick = TickMath.maxUsableTick(SPACING);
        if (tick <= minTick || tick >= maxTick) revert TickOutOfRange(tick);
        return tick;
    }

    function align(int24 tick) internal pure returns (int24) {
        int24 spacing = SPACING;
        if (tick >= 0) {
            int24 rem = tick % spacing;
            if (rem * 2 >= spacing) return tick + (spacing - rem);
            return tick - rem;
        }
        int24 absTick = -tick;
        int24 absRem = absTick % spacing;
        if (absRem == 0) return tick;
        if (absRem * 2 >= spacing) return tick - (spacing - absRem);
        return tick + absRem;
    }

    function sqrtPrice(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    error TickOutOfRange(int256 tick);

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
