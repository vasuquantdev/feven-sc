// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @notice One-sided liquidity for a range that sits entirely on one token.
library LiquidityMath {
    uint256 internal constant Q96 = 2 ** 96;

    function forAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(sqrtB) - uint256(sqrtA)));
    }

    function forAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _toUint128(FullMath.mulDiv(amount1, Q96, uint256(sqrtB) - uint256(sqrtA)));
    }

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        require(x <= type(uint128).max, "liquidity overflow");
        y = uint128(x);
    }
}
