// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ILaunchToken} from "../src/interfaces/ILaunchToken.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ProtocolFeeVault} from "../src/ProtocolFeeVault.sol";

contract LaunchTest is Test {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolManager internal manager;
    ProtocolFeeVault internal vault;
    QuoteRegistry internal quotes;
    LaunchFactory internal factory;
    LaunchHook internal hook;
    LaunchToken internal tokenMaster;
    FeeSplitter internal splitterMaster;
    LaunchRouter internal router;

    function setUp() public {
        manager = new PoolManager(address(this));
        vault = new ProtocolFeeVault(address(this));
        quotes = new QuoteRegistry(address(this));
        quotes.register(address(0), 18, "HYPE");
        factory = new LaunchFactory(manager, vault, quotes, address(this));
        hook = _deployHook();
        tokenMaster = new LaunchToken(address(factory), address(manager), address(hook));
        splitterMaster = new FeeSplitter(address(factory));
        factory.publishModuleSet(address(hook), address(tokenMaster), address(splitterMaster));
        factory.publishConfig(_tier());
        router = new LaunchRouter(manager);
    }

    function testLaunchSeedsThePool() public {
        (address token, bytes32 poolId) = _launch(0, 0);
        LaunchToken launched = LaunchToken(payable(token));
        assertEq(launched.creator(), address(this));
        assertEq(launched.totalSupply() > 0, true);
        assertEq(launched.balanceOf(address(hook)), 0);
        assertEq(launched.balanceOf(address(manager)), launched.totalSupply());
        (,, address recipient, uint24 totalFee,,, bool seeded) = hook.poolTerms(poolId);
        assertEq(recipient, address(this));
        assertEq(totalFee, 10_000);
        assertEq(seeded, true);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    function testFirstBuyIsFeeExemptAndLaterBuyPaysCreator() public {
        (address token, bytes32 poolId) = _launch(1 ether, 0);
        LaunchToken launched = LaunchToken(payable(token));
        uint256 creatorTokens = launched.balanceOf(address(this));
        assertGt(creatorTokens, 0);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 20 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        router.swapExactInput{value: 10 ether}(_key(token), true, 10 ether, 0);
        assertEq(before - buyer.balance, 10 ether);
        assertGt(launched.balanceOf(buyer), 0);

        uint256 claimed = hook.claim(poolId, address(this));
        assertEq(claimed, (10 ether * 6_000) / 1_000_000);
        assertEq(address(this).balance > 0, true);

        hook.collectProtocol(address(0));
        assertEq(address(vault).balance, (10 ether * 4_000) / 1_000_000);
    }

    function testWalletTransferSettles() public {
        (address token,) = _launch(1 ether, 0);
        LaunchToken launched = LaunchToken(payable(token));
        address other = makeAddr("other");
        uint256 amount = launched.balanceOf(address(this)) / 2;
        launched.transfer(other, amount);
        assertEq(launched.balanceOf(other), amount);
    }

    function testMasterCannotBeInitialized() public {
        ILaunchToken.Profile memory profile;
        vm.expectRevert(LaunchToken.NotFactory.selector);
        tokenMaster.initialize(address(this), "Nope", "NO", "", profile, 1 ether);
        vm.prank(address(factory));
        vm.expectRevert(LaunchToken.Initialized.selector);
        tokenMaster.initialize(address(this), "Nope", "NO", "", profile, 1 ether);
    }

    receive() external payable {}

    function _launch(uint256 firstBuy, uint256 minOut) internal returns (address token, bytes32 poolId) {
        LaunchFactory.LaunchParams memory p;
        p.name = "Feven";
        p.symbol = "FEVEN";
        p.metadataURI = "ipfs://feven";
        p.feeRecipients = new address[](0);
        p.feeShares = new uint16[](0);
        p.firstBuyAmount = firstBuy;
        p.firstBuyMinOut = minOut;
        (token, poolId) = factory.launch{value: firstBuy}(p);
    }

    function _tier() internal pure returns (LaunchFactory.LaunchConfig memory cfg) {
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

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _deployHook() internal returns (LaunchHook deployed) {
        bytes memory init = abi.encodePacked(
            type(LaunchHook).creationCode, abi.encode(address(manager), address(factory), address(vault), address(this), uint32(600))
        );
        (bytes32 salt, address predicted) = _mine(address(this), HOOK_FLAGS, init);
        deployed = new LaunchHook{salt: salt}(IPoolManager(address(manager)), address(factory), address(vault), address(this), 600);
        assertEq(address(deployed), predicted);
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
