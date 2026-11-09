// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";

/// @notice Uniswap v4 hook for a launch pool.
/// The seed position holds only the new token and is never removed.
/// Swap fees are taken in the quote and split between the creator side and the protocol.
contract LaunchHook is ILaunchHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint24 internal constant MAX_TOTAL_FEE = 100_000;
    uint24 internal constant MAX_EARLY_FEE = 990_000;
    uint32 internal constant MAX_EARLY_WINDOW = 1800;
    uint8 internal constant BELOW = 0;
    uint8 internal constant CROSSED = 1;
    uint8 internal constant GRADUATED = 2;
    uint8 internal constant LP_CROSSED = 3;
    uint8 internal constant LP_ACTIVE = 4;

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable vault;
    address public immutable owner;
    uint32 public immutable lpLineHold;
    bytes32 public constant SEED_SALT = bytes32(uint256(1));

    struct PoolConfig {
        Currency currency0;
        Currency currency1;
        address token;
        address quote;
        address recipient;
        address liquidityPolicy;
        bool quoteIsCurrency0;
        bool tokenIsCurrency0;
        bool feeLocked;
        bool liquiditySealed;
        bool registered;
        bool seeded;
        uint24 totalFee;
        uint24 totalFeeMin;
        uint24 protocolFee;
        uint24 lpFee;
        uint24 earlyStart;
        uint32 earlyWindow;
        uint40 earlyUntil;
        uint24 graduationTicks;
        uint24 lpLineTicks;
        int24 openingTick;
        int24 tickLower;
        int24 tickUpper;
        uint8 stage;
        uint40 lpCrossedAt;
        uint256 lpHeldSeconds;
        uint128 liquidity;
    }

    mapping(PoolId => PoolConfig) internal pools;
    mapping(PoolId => uint256) public pendingCreator;
    mapping(PoolId => uint256) public pendingProtocol;
    mapping(PoolId => uint256) public tab;
    mapping(address => uint256) public protocolTab;

    event PoolRegistered(PoolId indexed poolId, address indexed token, address recipient, uint24 earlyStart, uint32 earlyWindow);
    event PoolSeeded(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 dustBurned);
    event FeeAccrued(PoolId indexed poolId, bool zeroForOne, int256 amountSpecified, uint256 fee, uint256 protocolPart);
    event FeesSwept(PoolId indexed poolId, uint256 creatorAmount, uint256 protocolAmount);
    event CreatorFeesClaimed(PoolId indexed poolId, address indexed to, uint256 amount);
    event ProtocolCollected(address indexed currency, uint256 amount);
    event Graduated(PoolId indexed poolId);
    event LpFeeActivated(PoolId indexed poolId, uint24 lpFee);
    event TotalFeeUpdated(PoolId indexed poolId, uint24 totalFee);
    event ProtocolFeeUpdated(PoolId indexed poolId, uint24 protocolFee);
    event FeeLocked(PoolId indexed poolId);
    event RecipientUpdated(PoolId indexed poolId, address indexed recipient, bool feeLocked);
    event SeedFeesHarvested(PoolId indexed poolId, uint256 quoteToCreator, uint256 tokensBurned);

    error NotFactory();
    error NotPoolManager();
    error NotRecipient();
    error UnknownPool();
    error AlreadyRegistered();
    error NotSeeded();
    error LiquiditySealed();
    error BadTerms();
    error SeedLiquidityZero();
    error DonationsDisabled();
    error AddressOne();
    error BadAction();

    struct Action {
        uint8 kind;
        bytes32 poolId;
        address to;
        uint256 amount;
    }

    constructor(IPoolManager poolManager_, address factory_, address vault_, address owner_, uint32 lpLineHold_) {
        poolManager = poolManager_;
        factory = factory_;
        vault = vault_;
        owner = owner_;
        lpLineHold = lpLineHold_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: true,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function register(PoolKey calldata key, Terms calldata terms) external {
        if (msg.sender != factory) revert NotFactory();
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        if (p.registered) revert AlreadyRegistered();
        _validateTerms(terms);

        bool tokenIs0 = Currency.unwrap(key.currency0) == terms.token;
        p.currency0 = key.currency0;
        p.currency1 = key.currency1;
        p.token = terms.token;
        p.quote = terms.quote;
        p.recipient = terms.recipient;
        p.liquidityPolicy = terms.liquidityPolicy;
        p.quoteIsCurrency0 = Currency.unwrap(key.currency0) == terms.quote;
        p.tokenIsCurrency0 = tokenIs0;
        p.feeLocked = terms.feeLocked;
        p.liquiditySealed = terms.liquiditySealed;
        p.registered = true;
        p.totalFee = terms.totalFeePips;
        p.totalFeeMin = terms.totalFeeMinPips;
        p.protocolFee = terms.protocolFeePips;
        p.lpFee = terms.lpFeePips;
        p.earlyStart = terms.earlyBuyFeeStartPips;
        p.earlyWindow = terms.earlyBuyFeeWindow;
        p.earlyUntil = terms.earlyBuyFeeWindow == 0 ? 0 : uint40(block.timestamp + terms.earlyBuyFeeWindow);
        p.graduationTicks = terms.graduationTicks;
        p.lpLineTicks = terms.lpLineTicks;
        p.openingTick = terms.openingTick;
        if (tokenIs0) {
            p.tickLower = terms.openingTick;
            p.tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        } else {
            p.tickLower = TickMath.minUsableTick(key.tickSpacing);
            p.tickUpper = terms.openingTick;
        }
        if (p.tickLower >= p.tickUpper) revert BadTerms();
        _tstore(_launchSlot(id), 1);
        emit PoolRegistered(id, terms.token, terms.recipient, terms.earlyBuyFeeStartPips, terms.earlyBuyFeeWindow);
    }

    function seed(PoolKey calldata key) external {
        if (msg.sender != factory) revert NotFactory();
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        if (!p.registered || p.seeded) revert UnknownPool();

        uint256 balance = IERC20(p.token).balanceOf(address(this));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);
        uint128 liquidity = p.tokenIsCurrency0
            ? LiquidityMath.forAmount0(sqrtLower, sqrtUpper, balance)
            : LiquidityMath.forAmount1(sqrtLower, sqrtUpper, balance);
        if (liquidity == 0) revert SeedLiquidityZero();

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: SEED_SALT
            }),
            ""
        );
        _settleOwed(p.currency0, delta.amount0());
        _settleOwed(p.currency1, delta.amount1());

        uint256 dust = IERC20(p.token).balanceOf(address(this));
        if (dust != 0) ILaunchToken(p.token).burn(dust);
        p.seeded = true;
        p.liquidity = liquidity;
        emit PoolSeeded(id, p.tickLower, p.tickUpper, liquidity, dust);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (sender != factory) revert NotFactory();
        PoolConfig storage p = pools[key.toId()];
        if (!p.registered) revert UnknownPool();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != 200 || address(key.hooks) != address(this)) {
            revert BadTerms();
        }
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolConfig storage p = pools[key.toId()];
        if (!p.registered) revert UnknownPool();
        if (!p.seeded && sender != address(this)) revert NotSeeded();
        if (p.seeded && p.liquiditySealed && sender != address(this)) revert LiquiditySealed();
        if (p.seeded && sender != address(this) && p.liquidityPolicy != address(0)) {
            (bool ok, bytes memory data) = p.liquidityPolicy.staticcall(abi.encodeWithSignature("allowAdd(address,bytes32)", sender, PoolId.unwrap(key.toId())));
            if (!ok || data.length < 32 || abi.decode(data, (bool)) == false) revert LiquiditySealed();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert DonationsDisabled();
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        if (!p.seeded) revert NotSeeded();
        _confirm(key, p, id);

        uint24 lp = p.stage == LP_ACTIVE ? p.lpFee : 0;
        uint24 overrideFee = lp | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        bool exempt = sender == factory && _tload(_launchSlot(id)) == 1;
        if (exempt) {
            _tstore(_kindSlot(id), 2);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), overrideFee);
        }
        if (!_specifiedIsQuote(p, params)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), overrideFee);
        }

        (uint256 fee, uint256 proto) = _feeParts(p, _abs(params.amountSpecified), true, lp);
        _tstore(_feeSlot(id), fee);
        _tstore(_protoSlot(id), proto);
        _tstore(_kindSlot(id), 1);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), overrideFee);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        PoolConfig storage p = pools[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        _markProgress(p, tick);

        uint256 fee = _tload(_feeSlot(id));
        uint256 proto = _tload(_protoSlot(id));
        int128 unspecified;
        uint256 kind = _tload(_kindSlot(id));
        if (kind == 2) {
            fee = 0;
            proto = 0;
        } else if (kind != 1) {
            int128 raw = _unspecified(p, params, delta);
            uint256 leg = raw < 0 ? uint256(uint128(-raw)) : uint256(uint128(raw));
            uint24 lp = p.stage == LP_ACTIVE ? p.lpFee : 0;
            (fee, proto) = _feeParts(p, leg, _isBuy(p, params), lp);
            unspecified = _toInt128(fee);
        }

        if (fee != 0) {
            Currency quote = p.quoteIsCurrency0 ? p.currency0 : p.currency1;
            poolManager.mint(address(this), quote.toId(), fee);
            if (proto > fee) proto = fee;
            pendingProtocol[id] += proto;
            pendingCreator[id] += fee - proto;
        }
        _tstore(_feeSlot(id), 0);
        _tstore(_protoSlot(id), 0);
        _tstore(_kindSlot(id), 0);
        emit FeeAccrued(id, params.zeroForOne, params.amountSpecified, fee, proto);
        return (IHooks.afterSwap.selector, unspecified);
    }

    function sweep(bytes32 poolId) external returns (uint256 creatorAmount, uint256 protocolAmount) {
        return _sweep(PoolId.wrap(poolId));
    }

    function claim(bytes32 poolId, address to) external returns (uint256 amount) {
        PoolId id = PoolId.wrap(poolId);
        if (msg.sender != pools[id].recipient) revert NotRecipient();
        if (to == address(0) || to == address(1)) revert AddressOne();
        amount = abi.decode(poolManager.unlock(abi.encode(Action({kind: 1, poolId: poolId, to: to, amount: 0}))), (uint256));
    }

    function claimTab(bytes32 poolId, address to, uint256 amount) external returns (uint256 paid) {
        PoolId id = PoolId.wrap(poolId);
        if (msg.sender != pools[id].recipient) revert NotRecipient();
        if (to == address(0) || to == address(1)) revert AddressOne();
        paid = abi.decode(poolManager.unlock(abi.encode(Action({kind: 4, poolId: poolId, to: to, amount: amount}))), (uint256));
    }

    function harvestSeed(bytes32 poolId) external returns (uint256 quoteToCreator, uint256 tokensBurned) {
        (quoteToCreator, tokensBurned) = abi.decode(
            poolManager.unlock(abi.encode(Action({kind: 2, poolId: poolId, to: address(0), amount: 0}))), (uint256, uint256)
        );
    }

    function collectProtocol(address currency) external returns (uint256 amount) {
        amount = abi.decode(
            poolManager.unlock(
                abi.encode(Action({kind: 3, poolId: bytes32(uint256(uint160(currency))), to: currency, amount: 0}))
            ),
            (uint256)
        );
    }

    function lowerTotalFee(bytes32 poolId, uint24 totalFee) external {
        PoolId id = PoolId.wrap(poolId);
        PoolConfig storage p = pools[id];
        if (msg.sender != p.recipient) revert NotRecipient();
        if (p.feeLocked || totalFee >= p.totalFee || totalFee < p.totalFeeMin || totalFee > MAX_TOTAL_FEE) revert BadTerms();
        p.totalFee = totalFee;
        emit TotalFeeUpdated(id, totalFee);
    }

    function lockFee(bytes32 poolId) external {
        PoolId id = PoolId.wrap(poolId);
        PoolConfig storage p = pools[id];
        if (msg.sender != p.recipient) revert NotRecipient();
        p.feeLocked = true;
        emit FeeLocked(id);
    }

    function lowerProtocolFee(bytes32 poolId, uint24 protocolFee) external {
        if (msg.sender != owner) revert NotFactory();
        PoolId id = PoolId.wrap(poolId);
        PoolConfig storage p = pools[id];
        if (protocolFee >= p.protocolFee) revert BadTerms();
        p.protocolFee = protocolFee;
        emit ProtocolFeeUpdated(id, protocolFee);
    }

    function updateRecipient(bytes32 poolId, address newRecipient) external {
        PoolId id = PoolId.wrap(poolId);
        PoolConfig storage p = pools[id];
        if (msg.sender != p.recipient) revert NotRecipient();
        if (newRecipient == address(0) || newRecipient == address(1)) revert AddressOne();
        p.recipient = newRecipient == p.token ? p.token : newRecipient;
        if (newRecipient == p.token) p.feeLocked = true;
        emit RecipientUpdated(id, p.recipient, p.feeLocked);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Action memory action = abi.decode(data, (Action));
        PoolId id = PoolId.wrap(action.poolId);
        if (action.kind == 1) return abi.encode(_payOut(id, action.to, 0, true));
        if (action.kind == 4) return abi.encode(_payOut(id, action.to, action.amount, false));
        if (action.kind == 2) {
            (uint256 quoteAmount, uint256 burned) = _harvest(id);
            return abi.encode(quoteAmount, burned);
        }
        if (action.kind == 3) {
            address currency = action.to;
            uint256 amount = protocolTab[currency];
            protocolTab[currency] = 0;
            if (amount != 0) _redeem(Currency.wrap(currency), vault, amount);
            emit ProtocolCollected(currency, amount);
            return abi.encode(amount);
        }
        revert BadAction();
    }

    function recipient(bytes32 poolId) external view returns (address) {
        return pools[PoolId.wrap(poolId)].recipient;
    }

    function quoteOf(bytes32 poolId) external view returns (address) {
        return pools[PoolId.wrap(poolId)].quote;
    }

    function currentBuyFeeRate(bytes32 poolId) external view returns (uint256) {
        return _buyRate(pools[PoolId.wrap(poolId)]);
    }

    function currentFeeRate(bytes32 poolId, address) external view returns (uint256) {
        return pools[PoolId.wrap(poolId)].totalFee;
    }

    function stage(bytes32 poolId) external view returns (uint8) {
        return pools[PoolId.wrap(poolId)].stage;
    }

    function poolTerms(bytes32 poolId)
        external
        view
        returns (address token, address quote, address feeRecipient, uint24 totalFee, uint24 protocolFee, uint24 lpFee, bool seeded)
    {
        PoolConfig storage p = pools[PoolId.wrap(poolId)];
        return (p.token, p.quote, p.recipient, p.totalFee, p.protocolFee, p.lpFee, p.seeded);
    }

    function _payOut(PoolId id, address to, uint256 limit, bool harvestFirst) internal returns (uint256 amount) {
        if (harvestFirst) {
            _sweep(id);
            _harvest(id);
            _sweep(id);
        }
        amount = tab[id];
        if (limit != 0 && limit < amount) amount = limit;
        tab[id] -= amount;
        if (amount != 0) {
            Currency quote = pools[id].quoteIsCurrency0 ? pools[id].currency0 : pools[id].currency1;
            _redeem(quote, to, amount);
        }
        emit CreatorFeesClaimed(id, to, amount);
    }

    function _sweep(PoolId id) internal returns (uint256 creatorAmount, uint256 protocolAmount) {
        creatorAmount = pendingCreator[id];
        protocolAmount = pendingProtocol[id];
        if (creatorAmount == 0 && protocolAmount == 0) return (0, 0);
        pendingCreator[id] = 0;
        pendingProtocol[id] = 0;
        tab[id] += creatorAmount;
        protocolTab[pools[id].quote] += protocolAmount;
        emit FeesSwept(id, creatorAmount, protocolAmount);
    }

    function _harvest(PoolId id) internal returns (uint256 quoteToCreator, uint256 tokensBurned) {
        PoolConfig storage p = pools[id];
        if (!p.seeded) return (0, 0);
        PoolKey memory key = _key(p);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: 0, salt: SEED_SALT}),
            ""
        );
        int128 quoteDelta = p.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = p.tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        if (quoteDelta > 0) {
            quoteToCreator = uint256(uint128(quoteDelta));
            Currency quote = p.quoteIsCurrency0 ? p.currency0 : p.currency1;
            poolManager.mint(address(this), quote.toId(), quoteToCreator);
            pendingCreator[id] += quoteToCreator;
        }
        if (tokenDelta > 0) {
            tokensBurned = uint256(uint128(tokenDelta));
            poolManager.take(p.tokenIsCurrency0 ? p.currency0 : p.currency1, address(this), tokensBurned);
            ILaunchToken(p.token).burn(tokensBurned);
        }
        if (quoteToCreator != 0 || tokensBurned != 0) emit SeedFeesHarvested(id, quoteToCreator, tokensBurned);
    }

    function _confirm(PoolKey calldata key, PoolConfig storage p, PoolId id) internal {
        if (_tload(_touchSlot(id)) == 1) return;
        _tstore(_touchSlot(id), 1);
        if (p.stage == CROSSED) {
            p.stage = GRADUATED;
            emit Graduated(id);
        }
        if (p.stage == LP_CROSSED) {
            uint256 held = p.lpHeldSeconds;
            if (p.lpCrossedAt != 0 && block.timestamp > p.lpCrossedAt) held += block.timestamp - p.lpCrossedAt;
            if (held >= lpLineHold) {
                p.stage = LP_ACTIVE;
                p.lpHeldSeconds = held;
                p.lpCrossedAt = 0;
                poolManager.updateDynamicLPFee(key, p.lpFee);
                emit LpFeeActivated(id, p.lpFee);
            }
        }
    }

    function _markProgress(PoolConfig storage p, int24 tick) internal {
        bool pastGrad = _past(tick, _line(p.openingTick, p.graduationTicks, p.tokenIsCurrency0), p.tokenIsCurrency0);
        bool pastLp = _past(tick, _line(p.openingTick, p.lpLineTicks, p.tokenIsCurrency0), p.tokenIsCurrency0);
        if (p.stage == BELOW) p.stage = pastGrad ? CROSSED : BELOW;
        if (p.stage == CROSSED && !pastGrad) p.stage = BELOW;
        if (p.stage == GRADUATED && pastLp) {
            p.stage = LP_CROSSED;
            p.lpCrossedAt = uint40(block.timestamp);
        } else if (p.stage == LP_CROSSED && !pastLp) {
            if (p.lpCrossedAt != 0 && block.timestamp > p.lpCrossedAt) p.lpHeldSeconds += block.timestamp - p.lpCrossedAt;
            p.lpCrossedAt = 0;
            p.stage = GRADUATED;
        }
    }

    function _feeParts(PoolConfig storage p, uint256 leg, bool buying, uint24 lp)
        internal
        view
        returns (uint256 fee, uint256 proto)
    {
        uint256 rate = buying ? _buyRate(p) : p.totalFee;
        uint256 hookRate = rate > lp ? rate - lp : 0;
        fee = (leg * hookRate) / 1_000_000;
        proto = (leg * p.protocolFee) / 1_000_000;
        if (proto > fee) proto = fee;
    }

    function _buyRate(PoolConfig storage p) internal view returns (uint24) {
        uint24 total = p.totalFee;
        if (p.earlyUntil == 0 || block.timestamp >= p.earlyUntil) return total;
        uint256 startAt = uint256(p.earlyUntil) - p.earlyWindow;
        if (block.timestamp <= startAt) return p.earlyStart;
        uint256 remaining = uint256(p.earlyUntil) - block.timestamp;
        uint256 extra = ((uint256(p.earlyStart) - total) * remaining + p.earlyWindow - 1) / p.earlyWindow;
        return uint24(total + extra);
    }

    function _validateTerms(Terms calldata terms) internal pure {
        if (terms.protocolFeePips + terms.lpFeePips > terms.totalFeeMinPips) revert BadTerms();
        if (terms.totalFeeMinPips > terms.totalFeePips || terms.totalFeePips > MAX_TOTAL_FEE) revert BadTerms();
        if (terms.lpLineTicks < terms.graduationTicks) revert BadTerms();
        bool noEarly = terms.earlyBuyFeeStartPips == 0 && terms.earlyBuyFeeWindow == 0;
        bool earlyOk = terms.earlyBuyFeeStartPips > terms.totalFeePips && terms.earlyBuyFeeStartPips <= MAX_EARLY_FEE
            && terms.earlyBuyFeeWindow >= 1 && terms.earlyBuyFeeWindow <= MAX_EARLY_WINDOW;
        if (!noEarly && !earlyOk) revert BadTerms();
    }

    function _settleOwed(Currency currency, int128 delta) internal {
        if (delta == 0) return;
        if (delta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(delta)));
            return;
        }
        uint256 amount = uint256(uint128(-delta));
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _redeem(Currency currency, address to, uint256 amount) internal {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    function _key(PoolConfig storage p) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: p.currency0,
            currency1: p.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });
    }

    function _specifiedIsQuote(PoolConfig storage p, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == p.quoteIsCurrency0;
    }

    function _isBuy(PoolConfig storage p, SwapParams calldata params) internal view returns (bool) {
        return params.zeroForOne == p.quoteIsCurrency0;
    }

    function _unspecified(PoolConfig storage p, SwapParams calldata params, BalanceDelta delta) internal view returns (int128) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 ? delta.amount1() : delta.amount0();
    }

    function _past(int24 tick, int24 line, bool tokenIsCurrency0) internal pure returns (bool) {
        return tokenIsCurrency0 ? tick >= line : tick <= line;
    }

    function _line(int24 opening, uint24 distance, bool tokenIsCurrency0) internal pure returns (int24) {
        return tokenIsCurrency0 ? opening + int24(distance) : opening - int24(distance);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _toInt128(uint256 x) internal pure returns (int128) {
        require(x <= uint256(uint128(type(int128).max)));
        return int128(uint128(x));
    }

    function _launchSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, "launch"));
    }

    function _touchSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, "touch"));
    }

    function _feeSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, "fee"));
    }

    function _protoSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, "proto"));
    }

    function _kindSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, "kind"));
    }

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    receive() external payable {}
}
