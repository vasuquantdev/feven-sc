// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

/// @notice Deploy the launchpad. The default pool manager is Uniswap v4 on Elysium.
/// forge script script/Deploy.s.sol --rpc-url https://rpc.elysium.kinetiq.xyz --broadcast --private-key $PRIVATE_KEY
contract Deploy is Script {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        address broadcaster = msg.sender;
        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0xe2e105d3f7209a9da11f83ccf3e7398a753823f1));
        uint256 nonce = vm.getNonce(broadcaster);
        address factoryAddr = vm.computeCreateAddress(broadcaster, nonce + 2);

        bytes memory hookInit = abi.encodePacked(
            type(LaunchHook).creationCode, abi.encode(poolManagerAddr, factoryAddr, vm.computeCreateAddress(broadcaster, nonce), broadcaster, uint32(600))
        );
        // nonce + 0 vault, + 1 registry, + 2 factory, + 3 hook (create2 still consumes a nonce)
        (bytes32 salt,) = _mine(broadcaster, HOOK_FLAGS, hookInit);

        vm.startBroadcast();
        ProtocolFeeVault vault = new ProtocolFeeVault(broadcaster);
        QuoteRegistry quotes = new QuoteRegistry(broadcaster);
        LaunchFactory factory = new LaunchFactory(IPoolManager(poolManagerAddr), vault, quotes, broadcaster);
        require(address(factory) == factoryAddr, "factory address");
        quotes.register(address(0), 18, "HYPE");
        LaunchHook hook = new LaunchHook{salt: salt}(IPoolManager(poolManagerAddr), address(factory), address(vault), broadcaster, 600);
        LaunchToken tokenMaster = new LaunchToken(address(factory), poolManagerAddr, address(hook));
        FeeSplitter splitterMaster = new FeeSplitter(address(factory));
        LaunchRouter router = new LaunchRouter(IPoolManager(poolManagerAddr));
        factory.publishModuleSet(address(hook), address(tokenMaster), address(splitterMaster));
        factory.publishConfig(_hypeTier());
        vm.stopBroadcast();

        console2.log("vault", address(vault));
        console2.log("quotes", address(quotes));
        console2.log("factory", address(factory));
        console2.log("hook", address(hook));
        console2.log("tokenMaster", address(tokenMaster));
        console2.log("splitterMaster", address(splitterMaster));
        console2.log("router", address(router));
    }

    function _hypeTier() internal pure returns (LaunchFactory.LaunchConfig memory cfg) {
        cfg.quote = address(0);
        cfg.baseSupply = 1_000_000_000 ether;
        cfg.tickSpacing = 200;
        cfg.startTick = 169800;
        cfg.graduationTicks = 28_200;
        cfg.lpLineTicks = 49_600;
        cfg.totalFeePips = 10_000;
        cfg.totalFeeMinPips = 10_000;
        cfg.protocolFeePips = 4_000;
        cfg.lpFeePips = 1_000;
        cfg.streamDuration = 3600;
        cfg.pushBountyBps = 25;
    }

    function _mine(address deployer, uint160 flags, bytes memory initCode) internal pure returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < 200_000; i++) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return (salt, predicted);
        }
        revert("hook salt");
    }
}
