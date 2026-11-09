// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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

        assertEq(hook.collectProtocol(address(0)), (10 ether * 4_000) / 1_000_000);
        assertEq(address(vault).balance, (10 ether * 4_000) / 1_000_000);
        assertEq(hook.claim(poolId, address(this)), 0);
        assertEq(hook.collectProtocol(address(0)), 0);
    }

    function testFuzz_BuyFeeIsExact(uint96 raw) public {
        uint256 amount = bound(raw, 0.01 ether, 20 ether);
        (address token, bytes32 poolId) = _launch(0, 0);
        _buy(token, amount, makeAddr("fuzz"));
        uint256 fee = (amount * 10_000) / 1_000_000;
        uint256 protocol = (amount * 4_000) / 1_000_000;
        if (protocol > fee) protocol = fee;
        assertEq(hook.claim(poolId, address(this)), fee - protocol);
        assertEq(hook.collectProtocol(address(0)), protocol);
    }

    function testSellPaysQuoteFee() public {
        (address token, bytes32 poolId) = _launch(1 ether, 0);
        address buyer = makeAddr("seller");
        _buy(token, 10 ether, buyer);
        hook.claim(poolId, address(this));
        hook.collectProtocol(address(0));

        LaunchToken launched = LaunchToken(payable(token));
        uint256 half = launched.balanceOf(buyer) / 2;
        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        launched.approve(address(router), half);
        router.swapExactInput(_key(token), false, half, 0);
        vm.stopPrank();
        assertGt(buyer.balance, ethBefore);

        uint256 creator = hook.claim(poolId, address(this));
        uint256 protocol = hook.collectProtocol(address(0));
        assertGt(creator, 0);
        assertApproxEqAbs(creator * 4_000, protocol * 6_000, 6_000);
    }

    function testAntiSnipeDecaysToTheBaseFee() public {
        LaunchFactory.LaunchConfig memory cfg = _tier();
        cfg.earlyBuyFeeStartPips = 100_000;
        cfg.earlyBuyFeeWindow = 60;
        uint256 id = factory.publishConfig(cfg);
        (address token, bytes32 poolId) = _open(id, bytes32("snipe"), 0, 0);
        assertEq(hook.currentBuyFeeRate(poolId), 100_000);

        _buy(token, 10 ether, makeAddr("early"));
        assertEq(hook.claim(poolId, address(this)), 0.96 ether);
        assertEq(hook.collectProtocol(address(0)), 0.04 ether);

        uint256 openedAt = block.timestamp;
        vm.warp(openedAt + 30);
        assertEq(hook.currentBuyFeeRate(poolId), 55_000);
        vm.warp(openedAt + 60);
        assertEq(hook.currentBuyFeeRate(poolId), 10_000);

        _buy(token, 10 ether, makeAddr("late"));
        assertEq(hook.claim(poolId, address(this)), 0.06 ether);
        assertEq(hook.collectProtocol(address(0)), 0.04 ether);
    }

    function testSplitterAndRotate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address[] memory recipients = new address[](2);
        uint16[] memory shares = new uint16[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        shares[0] = 7_000;
        shares[1] = 3_000;
        (address token, bytes32 poolId) = _open(0, bytes32("split"), 0, 0, recipients, shares);
        _buy(token, 10 ether, makeAddr("buyer"));
        FeeSplitter splitter = FeeSplitter(payable(hook.recipient(poolId)));
        splitter.distribute();
        assertEq(splitter.owed(alice), 0.042 ether);
        assertEq(splitter.owed(bob), 0.018 ether);
        vm.prank(alice);
        vm.expectRevert(FeeSplitter.InvalidRecipients.selector);
        splitter.rotate(bob);
        vm.prank(alice);
        assertEq(splitter.collect(alice, 0), 0.042 ether);
        assertEq(alice.balance, 0.042 ether);
    }

    function testHolderRewardsStream() public {
        address[] memory recipients = new address[](1);
        uint16[] memory shares = new uint16[](1);
        recipients[0] = address(1);
        shares[0] = 10_000;
        (address token, bytes32 poolId) = _open(0, bytes32("holders"), 1 ether, 1 ether, recipients, shares);
        LaunchToken launched = LaunchToken(payable(token));
        address buyer = makeAddr("holder");
        _buy(token, 10 ether, buyer);
        assertEq(launched.eligibleSupply(), launched.balanceOf(address(this)) + launched.balanceOf(buyer));
        assertEq(launched.earned(address(manager)), 0);

        uint256 received = launched.distribute();
        assertEq(received, 0.06 ether);
        vm.warp(block.timestamp + 3600);
        uint256 creatorReward = launched.claimRewards();
        vm.prank(buyer);
        uint256 buyerReward = launched.claimRewards();
        assertGt(creatorReward, 0);
        assertGt(buyerReward, 0);
        assertApproxEqAbs(creatorReward + buyerReward, received, 3600);
        assertEq(hook.recipient(poolId), token);
    }

    function testErc20QuoteKeepsDonatedBalance() public {
        MockQuote quote = new MockQuote();
        quotes.register(address(quote), 18, "KQ");
        LaunchFactory.LaunchConfig memory cfg = _tier();
        cfg.quote = address(quote);
        uint256 id = factory.publishConfig(cfg);
        quote.mint(address(factory), 5 ether);
        quote.mint(address(this), 1 ether);
        quote.approve(address(factory), 1 ether);
        (address token, bytes32 poolId) = _open(id, bytes32("erc20"), 1 ether, 0);
        assertEq(quote.balanceOf(address(factory)), 5 ether);
        assertGt(LaunchToken(payable(token)).balanceOf(address(this)), 0);

        address buyer = makeAddr("ercBuyer");
        quote.mint(buyer, 10 ether);
        bool quoteIs0 = address(quote) < token;
        vm.startPrank(buyer);
        quote.approve(address(router), 10 ether);
        router.swapExactInput(_poolKey(token, address(quote)), quoteIs0, 10 ether, 0);
        vm.stopPrank();
        assertEq(hook.claim(poolId, address(this)), 0.06 ether);
        assertEq(quote.balanceOf(address(this)), 0.06 ether);
        assertEq(hook.collectProtocol(address(quote)), 0.04 ether);
        assertEq(quote.balanceOf(address(vault)), 0.04 ether);
    }

    function testDonatedNativeIsNotRefunded() public {
        vm.deal(address(factory), 5 ether);
        _launch(1 ether, 0);
        assertEq(address(factory).balance, 5 ether);
    }

    function testLaunchGuards() public {
        address predicted = factory.predictTokenAddress(address(this), bytes32(uint256(7)), 0);
        (address token,) = _open(0, bytes32(uint256(7)), 0, 0);
        assertEq(token, predicted);

        factory.setLaunchEnabled(false);
        vm.expectRevert(LaunchFactory.LaunchesPaused.selector);
        _launch(0, 0);
        factory.setLaunchEnabled(true);

        LaunchFactory.LaunchParams memory p;
        p.name = "Feven";
        p.symbol = "FEVEN";
        p.metadataURI = "ipfs://feven";
        p.firstBuyAmount = 1 ether;
        p.firstBuyMinOut = type(uint256).max;
        vm.expectPartialRevert(LaunchFactory.FirstBuySlippage.selector);
        factory.launch{value: 1 ether}(p);

        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
        vm.expectRevert(QuoteRegistry.ZeroAddress.selector);
        quotes.transferOwnership(address(0));
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setLaunchFeeRecipient(address(factory));
    }

    function testFeeCanOnlyMoveDownAndRecipientCannotBeTheHook() public {
        LaunchFactory.LaunchConfig memory cfg = _tier();
        cfg.totalFeePips = 20_000;
        uint256 id = factory.publishConfig(cfg);
        (, bytes32 poolId) = _open(id, bytes32("fee"), 0, 0);
        hook.lowerTotalFee(poolId, 15_000);
        vm.expectRevert(LaunchHook.BadTerms.selector);
        hook.lowerTotalFee(poolId, 16_000);
        vm.expectRevert(LaunchHook.BadTerms.selector);
        hook.lowerTotalFee(poolId, 9_000);
        hook.lockFee(poolId);
        vm.expectRevert(LaunchHook.BadTerms.selector);
        hook.lowerTotalFee(poolId, 12_000);
        vm.expectRevert(LaunchHook.AddressOne.selector);
        hook.updateRecipient(poolId, address(hook));
        vm.expectRevert(LaunchHook.NotOwner.selector);
        vm.prank(makeAddr("stranger"));
        hook.lowerProtocolFee(poolId, 1);
    }

    function testDonateReverts() public {
        (address token,) = _launch(0, 0);
        DonateCaller caller = new DonateCaller();
        vm.expectRevert();
        caller.donate(manager, _key(token));
    }

    function testRealCurveGraduatesAndReportsGas() public {
        vm.deal(address(this), 500 ether);
        uint256 gasBefore = gasleft();
        (address token, bytes32 poolId) = _launch(1 ether, 0);
        uint256 launchGas = gasBefore - gasleft();
        int24 openTick = _tick(poolId);

        address buyer = makeAddr("mover");
        vm.deal(buyer, 400 ether);
        gasBefore = gasleft();
        _buy(token, 10 ether, buyer);
        uint256 buyGas = gasBefore - gasleft();
        int24 after10 = _tick(poolId);
        _buy(token, 200 ether, buyer);
        int24 afterBig = _tick(poolId);

        LaunchToken launched = LaunchToken(payable(token));
        gasBefore = gasleft();
        launched.transfer(buyer, 1 ether);
        uint256 transferGas = gasBefore - gasleft();

        console2.log("launchGas", launchGas);
        console2.log("buy10Gas", buyGas);
        console2.log("transferGas", transferGas);
        console2.log("openTick", openTick);
        console2.log("tickAfter10Hype", after10);
        console2.log("tickAfter211Hype", afterBig);

        assertLt(after10, openTick);
        assertEq(hook.stage(poolId), 1);
        _nextTx(poolId);
        _buy(token, 1 ether, buyer);
        assertEq(hook.stage(poolId), 2);
    }

    function testLpFeeActivatesAfterTheHold() public {
        LaunchFactory.LaunchConfig memory cfg = _tier();
        cfg.graduationTicks = 200;
        cfg.lpLineTicks = 400;
        uint256 id = factory.publishConfig(cfg);
        (address token, bytes32 poolId) = _open(id, bytes32("lp"), 0, 0);
        address buyer = makeAddr("lpBuyer");
        vm.deal(buyer, 100 ether);
        _buy(token, 20 ether, buyer);
        assertEq(hook.stage(poolId), 1);
        _nextTx(poolId);
        _buy(token, 1 ether, buyer);
        assertEq(hook.stage(poolId), 3);
        vm.warp(block.timestamp + 601);
        _nextTx(poolId);
        _buy(token, 1 ether, buyer);
        assertEq(hook.stage(poolId), 4);

        hook.collectProtocol(address(0));
        _nextTx(poolId);
        _buy(token, 10 ether, buyer);
        assertEq(hook.collectProtocol(address(0)), (10 ether * 4_000) / 1_000_000);
        assertEq(hook.claim(poolId, address(this)) > (10 ether * 5_000) / 1_000_000, true);
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

    function _open(uint256 configId, bytes32 salt, uint256 firstBuy, uint256 value)
        internal
        returns (address token, bytes32 poolId)
    {
        return _open(configId, salt, firstBuy, value, new address[](0), new uint16[](0));
    }

    function _open(
        uint256 configId,
        bytes32 salt,
        uint256 firstBuy,
        uint256 value,
        address[] memory recipients,
        uint16[] memory shares
    ) internal returns (address token, bytes32 poolId) {
        LaunchFactory.LaunchParams memory p;
        p.name = "Feven";
        p.symbol = "FEVEN";
        p.metadataURI = "ipfs://feven";
        p.configId = configId;
        p.salt = salt;
        p.feeRecipients = recipients;
        p.feeShares = shares;
        p.firstBuyAmount = firstBuy;
        (token, poolId) = factory.launch{value: value}(p);
    }

    function _buy(address token, uint256 amount, address buyer) internal {
        vm.deal(buyer, buyer.balance + amount);
        vm.prank(buyer);
        router.swapExactInput{value: amount}(_key(token), true, amount, 0);
    }

    function _poolKey(address token, address quote) internal view returns (PoolKey memory) {
        bool tokenIs0 = token < quote;
        return PoolKey({
            currency0: Currency.wrap(tokenIs0 ? token : quote),
            currency1: Currency.wrap(tokenIs0 ? quote : token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _tick(bytes32 poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
    }

    function _nextTx(bytes32 poolId) internal {
        uint256 base = uint256(keccak256(abi.encode(poolId)));
        for (uint256 i; i < 5; i++) {
            bytes32 slot;
            unchecked {
                slot = bytes32(base + i);
            }
            assembly ("memory-safe") {
                tstore(slot, 0)
            }
        }
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

contract MockQuote {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DonateCaller {
    function donate(IPoolManager manager, PoolKey calldata key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        IPoolManager(msg.sender).donate(key, 1, 1, "");
        return "";
    }
}
