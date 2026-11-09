// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface ILaunchHook {
    struct Terms {
        address token;
        address quote;
        address recipient;
        bool feeLocked;
        bool liquiditySealed;
        uint24 totalFeePips;
        uint24 totalFeeMinPips;
        uint24 protocolFeePips;
        uint24 lpFeePips;
        uint24 earlyBuyFeeStartPips;
        uint32 earlyBuyFeeWindow;
        uint24 graduationTicks;
        uint24 lpLineTicks;
        int24 openingTick;
        address liquidityPolicy;
    }

    function register(PoolKey calldata key, Terms calldata terms) external;
    function seed(PoolKey calldata key) external;
    function claim(bytes32 poolId, address to) external returns (uint256 amount);
    function recipient(bytes32 poolId) external view returns (address);
    function quoteOf(bytes32 poolId) external view returns (address);
    function factory() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function currentBuyFeeRate(bytes32 poolId) external view returns (uint256);
    function currentFeeRate(bytes32 poolId, address) external view returns (uint256);
}
