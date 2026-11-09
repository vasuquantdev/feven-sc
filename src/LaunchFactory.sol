// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";
import {ProtocolFeeVault} from "./ProtocolFeeVault.sol";
import {FeeSplitter} from "./FeeSplitter.sol";
import {Clones} from "./libraries/Clones.sol";
import {OpeningMath} from "./libraries/OpeningMath.sol";

/// @notice One-transaction token launch into a locked Uniswap v4 pool.
/// Original implementation of the public Montra launch flow. Deploy this yourself; it does not wrap Montra's bytecode.
contract LaunchFactory is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    address public constant HOLDERS = address(1);
    uint256 public constant MIN_SUPPLY = 1e18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 ether;

    IPoolManager public immutable poolManager;
    ProtocolFeeVault public immutable vault;

    QuoteRegistry public quoteRegistry;
    address public owner;
    uint256 public launchFee;
    address public launchFeeRecipient;
    bool public launchEnabled = true;

    struct LaunchConfig {
        uint256 moduleSetId;
        address quote;
        uint256 baseSupply;
        int24 tickSpacing;
        int24 startTick;
        uint24 graduationTicks;
        uint24 lpLineTicks;
        uint24 totalFeePips;
        uint24 totalFeeMinPips;
        uint24 protocolFeePips;
        uint24 lpFeePips;
        uint24 earlyBuyFeeStartPips;
        uint32 earlyBuyFeeWindow;
        address liquidityPolicy;
        bool liquiditySealed;
        uint32 streamDuration;
        uint16 pushBountyBps;
        uint128 pushFloor;
        bool enabled;
        bool exists;
    }

    struct ModuleSet {
        address hook;
        address tokenMaster;
        address splitterMaster;
        bool exists;
    }

    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        ILaunchToken.Profile profile;
        uint256 configId;
        uint256 supply;
        bytes32 salt;
        address[] feeRecipients;
        uint16[] feeShares;
        uint256 firstBuyAmount;
        uint256 firstBuyMinOut;
        Permit permit;
    }

    struct LaunchCall {
        PoolKey key;
        int24 startTick;
        uint256 firstBuy;
        address creator;
        bool tokenIsCurrency0;
    }

    mapping(uint256 id => LaunchConfig) internal _configs;
    mapping(uint256 id => ModuleSet) public moduleSets;
    uint256 public configCount;
    uint256 public moduleSetCount;

    event ModuleSetPublished(uint256 indexed id, address indexed hook, address indexed tokenMaster, address splitterMaster);
    event ConfigPublished(uint256 indexed id, LaunchConfig config);
    event ConfigEnabled(uint256 indexed id, bool enabled);
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        uint256 configId,
        address quote,
        bool quoteIsCurrency0,
        uint256 supply,
        int24 startTick,
        address feeRecipient,
        bool feeLocked,
        uint256 firstBuyIn,
        uint256 firstBuyOut
    );
    event FeeSplitterDeployed(bytes32 indexed poolId, address indexed splitter, address[] recipients, uint16[] shares);
    event LaunchEnabled(bool enabled);
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);
    event LaunchFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event OwnershipTransferred(address indexed previous, address indexed current);

    error NotOwner();
    error LaunchesPaused();
    error ConfigDisabled();
    error InvalidConfigId();
    error UnknownModuleSet();
    error QuoteNotEnabled(address quote);
    error IncorrectValue();
    error FirstBuySlippage(uint256 received, uint256 minimum);
    error SupplyNotWholeCoins(uint256 supply);
    error SupplyOutOfRange(uint256 supply);
    error InvalidFeeRoute();
    error InvalidFeeRecipient();
    error EmptyString();
    error LaunchFeeTransferFailed();
    error PermitFailed();
    error ZeroAddress();
    error NotPoolManager();
    error NotRecipient();

    constructor(IPoolManager poolManager_, ProtocolFeeVault vault_, QuoteRegistry quoteRegistry_, address owner_) {
        if (address(poolManager_) == address(0) || address(vault_) == address(0) || address(quoteRegistry_) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        vault = vault_;
        quoteRegistry = quoteRegistry_;
        owner = owner_;
        launchFeeRecipient = address(vault_);
    }

    function launch(LaunchParams calldata p) external payable returns (address token, bytes32 poolId) {
        if (!launchEnabled) revert LaunchesPaused();
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert EmptyString();
        LaunchConfig memory cfg = getConfig(p.configId);
        if (!cfg.exists || !cfg.enabled) revert ConfigDisabled();
        if (!quoteRegistry.isEnabled(cfg.quote)) revert QuoteNotEnabled(cfg.quote);

        uint256 supply = p.supply == 0 ? cfg.baseSupply : p.supply;
        if (supply % 1e18 != 0) revert SupplyNotWholeCoins(supply);
        if (supply < MIN_SUPPLY || supply > MAX_SUPPLY) revert SupplyOutOfRange(supply);

        bool nativeQuote = cfg.quote == address(0);
        if (nativeQuote) {
            if (msg.value != launchFee + p.firstBuyAmount) revert IncorrectValue();
        } else if (msg.value != launchFee) {
            revert IncorrectValue();
        }
        if (launchFee != 0) {
            (bool ok,) = launchFeeRecipient.call{value: launchFee}("");
            if (!ok) revert LaunchFeeTransferFailed();
        }

        ModuleSet memory mods = moduleSets[cfg.moduleSetId];
        if (!mods.exists) revert UnknownModuleSet();

        token = Clones.cloneDeterministic(mods.tokenMaster, keccak256(abi.encode(msg.sender, p.salt)));
        bool tokenIs0 = token < cfg.quote;
        int24 startTick = OpeningMath.adjustedTick(cfg.startTick, supply, cfg.baseSupply, tokenIs0);

        ILaunchToken(token).initialize(msg.sender, p.name, p.symbol, p.metadataURI, p.profile, supply);

        PoolKey memory key = PoolKey({
            currency0: tokenIs0 ? Currency.wrap(token) : Currency.wrap(cfg.quote),
            currency1: tokenIs0 ? Currency.wrap(cfg.quote) : Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(mods.hook)
        });
        PoolId id = key.toId();
        poolId = PoolId.unwrap(id);

        (address recipient, bool feeLocked) = _route(mods, p, token, cfg.quote, poolId);
        ILaunchHook(mods.hook).register(
            key,
            ILaunchHook.Terms({
                token: token,
                quote: cfg.quote,
                recipient: recipient,
                feeLocked: feeLocked,
                liquiditySealed: cfg.liquiditySealed,
                totalFeePips: cfg.totalFeePips,
                totalFeeMinPips: cfg.totalFeeMinPips,
                protocolFeePips: cfg.protocolFeePips,
                lpFeePips: cfg.lpFeePips,
                earlyBuyFeeStartPips: cfg.earlyBuyFeeStartPips,
                earlyBuyFeeWindow: cfg.earlyBuyFeeWindow,
                graduationTicks: cfg.graduationTicks,
                lpLineTicks: cfg.lpLineTicks,
                openingTick: startTick,
                liquidityPolicy: cfg.liquidityPolicy
            })
        );
        ILaunchToken(token).initializePool(poolId, cfg.quote, cfg.streamDuration, cfg.pushBountyBps, cfg.pushFloor);

        if (!nativeQuote && p.firstBuyAmount != 0) {
            if (p.permit.deadline != 0) {
                (bool permitted,) = cfg.quote.call(
                    abi.encodeWithSignature(
                        "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                        msg.sender,
                        address(this),
                        p.firstBuyAmount,
                        p.permit.deadline,
                        p.permit.v,
                        p.permit.r,
                        p.permit.s
                    )
                );
                if (!permitted) revert PermitFailed();
            }
            if (!IERC20(cfg.quote).transferFrom(msg.sender, address(this), p.firstBuyAmount)) revert PermitFailed();
        }

        uint256 bought = abi.decode(
            poolManager.unlock(
                abi.encode(
                    LaunchCall({
                        key: key, startTick: startTick, firstBuy: p.firstBuyAmount, creator: msg.sender, tokenIsCurrency0: tokenIs0
                    })
                )
            ),
            (uint256)
        );
        if (bought < p.firstBuyMinOut) revert FirstBuySlippage(bought, p.firstBuyMinOut);

        emit TokenLaunched(
            token,
            msg.sender,
            poolId,
            p.configId,
            cfg.quote,
            !tokenIs0,
            supply,
            startTick,
            recipient,
            feeLocked,
            p.firstBuyAmount,
            bought
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        LaunchCall memory call_ = abi.decode(data, (LaunchCall));
        poolManager.initialize(call_.key, TickMath.getSqrtPriceAtTick(call_.startTick));
        ILaunchHook(address(call_.key.hooks)).seed(call_.key);
        uint256 out;
        if (call_.firstBuy != 0) out = _firstBuy(call_);
        return abi.encode(out);
    }

    function publishModuleSet(address hook, address tokenMaster, address splitterMaster) external returns (uint256 id) {
        if (msg.sender != owner) revert NotOwner();
        if (hook == address(0) || tokenMaster == address(0) || splitterMaster == address(0)) revert ZeroAddress();
        if (uint160(hook) & 0x3fff != 0x38EC) revert InvalidFeeRecipient();
        if (ILaunchHook(hook).factory() != address(this)) revert InvalidFeeRecipient();
        id = moduleSetCount++;
        moduleSets[id] = ModuleSet({hook: hook, tokenMaster: tokenMaster, splitterMaster: splitterMaster, exists: true});
        emit ModuleSetPublished(id, hook, tokenMaster, splitterMaster);
    }

    function publishConfig(LaunchConfig calldata cfg) external returns (uint256 id) {
        if (msg.sender != owner) revert NotOwner();
        if (!moduleSets[cfg.moduleSetId].exists) revert UnknownModuleSet();
        if (!quoteRegistry.isEnabled(cfg.quote)) revert QuoteNotEnabled(cfg.quote);
        if (cfg.tickSpacing != 200 || cfg.startTick % 200 != 0) revert InvalidConfigId();
        if (cfg.baseSupply < MIN_SUPPLY || cfg.baseSupply % 1e18 != 0) revert SupplyOutOfRange(cfg.baseSupply);
        if (cfg.protocolFeePips + cfg.lpFeePips > cfg.totalFeeMinPips || cfg.totalFeeMinPips > cfg.totalFeePips
            || cfg.totalFeePips > 100_000 || cfg.lpLineTicks < cfg.graduationTicks) revert InvalidFeeRoute();
        bool noEarly = cfg.earlyBuyFeeStartPips == 0 && cfg.earlyBuyFeeWindow == 0;
        bool earlyOk = cfg.earlyBuyFeeStartPips > cfg.totalFeePips && cfg.earlyBuyFeeStartPips <= 990_000
            && cfg.earlyBuyFeeWindow >= 1 && cfg.earlyBuyFeeWindow <= 1800;
        if (!noEarly && !earlyOk) revert InvalidFeeRoute();
        if (cfg.streamDuration == 0 || cfg.pushBountyBps > 1_000) revert InvalidFeeRoute();

        id = configCount++;
        _configs[id] = cfg;
        _configs[id].enabled = true;
        _configs[id].exists = true;
        _configs[id].tickSpacing = 200;
        emit ConfigPublished(id, _configs[id]);
    }

    function getConfig(uint256 id) public view returns (LaunchConfig memory cfg) {
        cfg = _configs[id];
        if (!cfg.exists) revert InvalidConfigId();
    }

    function getModuleSet(uint256 id) external view returns (ModuleSet memory) {
        if (!moduleSets[id].exists) revert UnknownModuleSet();
        return moduleSets[id];
    }

    function predictTokenAddress(address sender, bytes32 salt, uint256 configId) external view returns (address) {
        LaunchConfig memory cfg = getConfig(configId);
        return Clones.predictDeterministicAddress(
            moduleSets[cfg.moduleSetId].tokenMaster, keccak256(abi.encode(sender, salt)), address(this)
        );
    }

    function deploySplitter(uint256 moduleSetId, bytes32 poolId, bytes32 salt, address[] calldata recipients, uint16[] calldata shares)
        external
        returns (address splitter)
    {
        ModuleSet memory mods = moduleSets[moduleSetId];
        if (!mods.exists) revert UnknownModuleSet();
        if (ILaunchHook(mods.hook).recipient(poolId) != msg.sender) revert NotRecipient();
        address quote = ILaunchHook(mods.hook).quoteOf(poolId);
        splitter = _deploySplitter(mods, poolId, salt, quote, recipients, shares);
    }

    function setLaunchEnabled(bool enabled) external {
        if (msg.sender != owner) revert NotOwner();
        launchEnabled = enabled;
        emit LaunchEnabled(enabled);
    }

    function setLaunchFee(uint256 newFee) external {
        if (msg.sender != owner) revert NotOwner();
        emit LaunchFeeUpdated(launchFee, newFee);
        launchFee = newFee;
    }

    function setLaunchFeeRecipient(address recipient) external {
        if (msg.sender != owner) revert NotOwner();
        if (recipient == address(0)) revert ZeroAddress();
        emit LaunchFeeRecipientUpdated(launchFeeRecipient, recipient);
        launchFeeRecipient = recipient;
    }

    function setQuoteRegistry(QuoteRegistry next) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(next) == address(0)) revert ZeroAddress();
        quoteRegistry = next;
    }

    function transferOwnership(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    receive() external payable {}

    function _firstBuy(LaunchCall memory call_) internal returns (uint256 out) {
        bool quoteIs0 = !call_.tokenIsCurrency0;
        BalanceDelta delta = poolManager.swap(
            call_.key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(call_.firstBuy),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = quoteIs0 ? delta.amount0() : delta.amount1();
        int128 outDelta = quoteIs0 ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert FirstBuySlippage(0, 1);
        uint256 owed = uint256(uint128(-inDelta));
        Currency quote = quoteIs0 ? call_.key.currency0 : call_.key.currency1;
        Currency token = quoteIs0 ? call_.key.currency1 : call_.key.currency0;
        poolManager.sync(quote);
        if (quote.isAddressZero()) {
            poolManager.settle{value: owed}();
            if (address(this).balance > 0) {
                (bool ok,) = call_.creator.call{value: address(this).balance}("");
                require(ok, "refund");
            }
        } else {
            IERC20(Currency.unwrap(quote)).transfer(address(poolManager), owed);
            poolManager.settle();
        }
        out = uint256(uint128(outDelta));
        poolManager.take(token, call_.creator, out);
    }

    function _route(ModuleSet memory mods, LaunchParams calldata p, address token, address quote, bytes32 poolId)
        internal
        returns (address recipient, bool feeLocked)
    {
        uint256 n = p.feeRecipients.length;
        if (n == 0) return (msg.sender, false);
        if (n == 1) {
            if (p.feeShares.length != 1 || p.feeShares[0] != 10_000) revert InvalidFeeRoute();
            recipient = p.feeRecipients[0] == HOLDERS ? token : p.feeRecipients[0];
            _checkRecipient(recipient, quote);
            return (recipient, recipient == token);
        }
        if (n > 4 || p.feeShares.length != n) revert InvalidFeeRoute();
        address[] memory recips = new address[](n);
        for (uint256 i; i < n; i++) {
            recips[i] = p.feeRecipients[i] == HOLDERS ? token : p.feeRecipients[i];
            _checkRecipient(recips[i], quote);
        }
        recipient = _deploySplitter(mods, poolId, keccak256(abi.encode(msg.sender, p.salt, poolId)), quote, recips, p.feeShares);
        return (recipient, true);
    }

    function _deploySplitter(
        ModuleSet memory mods,
        bytes32 poolId,
        bytes32 salt,
        address quote,
        address[] memory recipients,
        uint16[] memory shares
    ) internal returns (address splitter) {
        splitter = Clones.cloneDeterministic(mods.splitterMaster, salt);
        FeeSplitter(payable(splitter)).initialize(mods.hook, poolId, quote, recipients, shares);
        emit FeeSplitterDeployed(poolId, splitter, recipients, shares);
    }

    function _checkRecipient(address recipient, address quote) internal view {
        if (recipient == address(0) || recipient == HOLDERS || recipient == address(this) || recipient == address(poolManager)
            || recipient == address(vault) || recipient == quote) revert InvalidFeeRecipient();
    }
}
