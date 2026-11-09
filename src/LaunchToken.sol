// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";

/// @notice Cloneable launch token. The master is locked; only the factory named in the master can initialize a clone.
contract LaunchToken is IERC20, ILaunchToken {
    uint256 private constant Q128 = 1 << 128;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant HOLDERS = address(1);

    address public immutable factory;
    address public immutable poolManager;
    address public immutable hook;

    string private _name;
    string private _symbol;
    string public metadataURI;
    string public logo;
    string public description;
    Socials private _socials;

    address public creator;
    address public quote;
    bytes32 public poolId;
    uint256 public launchBlock;
    bool public poolReady;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    uint256 public rewardIndex;
    mapping(address => uint256) public indexOf;
    mapping(address => uint256) public accrued;
    uint256 public streamPerSecond;
    uint40 public streamEnd;
    uint40 public streamLast;
    uint256 public streamUnplaced;
    uint32 public streamDuration;
    uint16 public pushBountyBps;
    uint128 public pushFloor;

    bool private _locked;
    uint256 private _lockedSupply;

    error NotFactory();
    error Initialized();
    error PoolNotReady();
    error AddressOne();
    error Locked();

    event RewardsDistributed(uint256 amount, uint256 perSecond, uint40 endsAt);
    event RewardsClaimed(address indexed holder, address indexed to, uint256 amount);

    constructor(address factory_, address poolManager_, address hook_) {
        factory = factory_;
        poolManager = poolManager_;
        hook = hook_;
        _locked = true;
    }

    function initialize(
        address creator_,
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        Profile calldata profile,
        uint256 supply
    ) external {
        if (msg.sender != factory) revert NotFactory();
        if (_locked) revert Initialized();
        _locked = true;
        creator = creator_;
        _name = name_;
        _symbol = symbol_;
        metadataURI = metadataURI_;
        logo = profile.logo;
        description = profile.description;
        _socials = profile.socials;
        launchBlock = block.number;
        _mint(hook, supply);
        _lockedSupply = supply;
    }

    function initializePool(bytes32 poolId_, address quote_, uint32 streamDuration_, uint16 pushBountyBps_, uint128 pushFloor_)
        external
    {
        if (msg.sender != factory) revert NotFactory();
        if (poolReady) revert Initialized();
        poolReady = true;
        poolId = poolId_;
        quote = quote_;
        streamDuration = streamDuration_;
        pushBountyBps = pushBountyBps_;
        pushFloor = pushFloor_;
        streamLast = uint40(block.timestamp);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    function tokenURI() external view returns (string memory) {
        return metadataURI;
    }

    function metaURI() external view returns (string memory) {
        return metadataURI;
    }

    function deployer() external view returns (address) {
        return creator;
    }

    function custodian() external view returns (address) {
        return hook;
    }

    function socials() external view returns (string memory, string memory, string memory, string memory, string memory) {
        return (_socials.telegram, _socials.twitter, _socials.discord, _socials.website, _socials.extra);
    }

    function getTokenInfo()
        external
        view
        returns (address creator_, string memory logo_, string memory description_, Socials memory socials_)
    {
        return (creator, logo, description, _socials);
    }

    function taxRatePips() external view returns (uint256) {
        if (!poolReady) return 0;
        return ILaunchHook(hook).currentFeeRate(poolId, address(0));
    }

    function taxBps() external view returns (uint24) {
        if (!poolReady) return 0;
        return _pipsToBps(ILaunchHook(hook).currentFeeRate(poolId, address(0)));
    }

    function sellTaxRate() external view returns (uint24) {
        if (!poolReady) return 0;
        return _pipsToBps(ILaunchHook(hook).currentFeeRate(poolId, address(0)));
    }

    function buyTaxRate() external view returns (uint24) {
        if (!poolReady) return 0;
        return _pipsToBps(ILaunchHook(hook).currentBuyFeeRate(poolId));
    }

    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == hook || account == address(this) || account == HOLDERS || account == DEAD;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        _syncStream();
        _settle(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function distribute() external returns (uint256 received) {
        if (!poolReady) revert PoolNotReady();
        _syncStream();
        received = ILaunchHook(hook).claim(poolId, address(this));
        if (received == 0) return 0;
        uint256 active = streamEnd > streamLast ? streamPerSecond * (streamEnd - streamLast) : 0;
        if (active > 0 && (received + streamUnplaced) * 100 < active) {
            streamUnplaced += received;
            return received;
        }
        uint256 total = received + streamUnplaced + active;
        streamUnplaced = 0;
        uint256 duration = streamDuration == 0 ? 3600 : streamDuration;
        streamPerSecond = total / duration;
        streamEnd = uint40(block.timestamp + duration);
        streamLast = uint40(block.timestamp);
        emit RewardsDistributed(received, streamPerSecond, streamEnd);
    }

    function earned(address holder) external view returns (uint256) {
        if (isExcluded(holder)) return accrued[holder];
        uint256 idx = _previewIndex();
        return accrued[holder] + (balanceOf[holder] * (idx - indexOf[holder])) / Q128;
    }

    function claimRewards() external returns (uint256) {
        return claimRewards(msg.sender);
    }

    function claimRewards(address to) public returns (uint256 amount) {
        if (to == HOLDERS) revert AddressOne();
        _syncStream();
        _settle(msg.sender);
        amount = accrued[msg.sender];
        accrued[msg.sender] = 0;
        _pay(to, amount);
        emit RewardsClaimed(msg.sender, to, amount);
    }

    function streaming() external view returns (uint256 remaining, uint256 perSecond, uint256 unplaced) {
        uint256 end = streamEnd;
        uint256 last = streamLast;
        if (block.timestamp < end && end > last) {
            uint256 from = block.timestamp > last ? block.timestamp : last;
            remaining = streamPerSecond * (end - from);
        }
        return (remaining, streamPerSecond, streamUnplaced);
    }

    function initialSupply() external view returns (uint256) {
        return _lockedSupply;
    }

    receive() external payable {}

    function _transfer(address from, address to, uint256 amount) internal {
        _syncStream();
        _settle(from);
        _settle(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        _syncStream();
        _settle(to);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _syncStream() internal {
        uint256 last = streamLast;
        if (block.timestamp <= last || streamPerSecond == 0) return;
        uint256 until = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        if (until > last) {
            uint256 amount = streamPerSecond * (until - last);
            uint256 eligible = _eligibleSupply();
            if (eligible > 0 && amount > 0) rewardIndex += (amount * Q128) / eligible;
        }
        streamLast = uint40(until);
    }

    function _previewIndex() internal view returns (uint256 idx) {
        idx = rewardIndex;
        uint256 last = streamLast;
        if (block.timestamp <= last || streamPerSecond == 0) return idx;
        uint256 until = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        if (until <= last) return idx;
        uint256 eligible = _eligibleSupply();
        if (eligible == 0) return idx;
        idx += (streamPerSecond * (until - last) * Q128) / eligible;
    }

    function _settle(address account) internal {
        uint256 idx = rewardIndex;
        if (!isExcluded(account)) {
            uint256 delta = idx - indexOf[account];
            if (delta != 0 && balanceOf[account] != 0) accrued[account] += (balanceOf[account] * delta) / Q128;
        }
        indexOf[account] = idx;
    }

    function _eligibleSupply() internal view returns (uint256) {
        uint256 excluded = balanceOf[poolManager] + balanceOf[hook] + balanceOf[address(this)] + balanceOf[DEAD] + balanceOf[HOLDERS];
        uint256 supply = totalSupply;
        return supply > excluded ? supply - excluded : 0;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "reward transfer");
        } else {
            require(IERC20(quote).transfer(to, amount), "reward transfer");
        }
    }

    function _pipsToBps(uint256 pips) internal pure returns (uint24) {
        return uint24((pips + 99) / 100);
    }
}
