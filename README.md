# Feven

Feven is a Uniswap v4 launchpad. One transaction creates a token, opens a pool, and seeds it with the full token supply. The pool’s hook locks that seed position, charges the trading fee in the quote asset, and splits it between the creator side and the protocol.

This repository is an original implementation of that flow. It is not Montra’s bytecode and it is not audited.

## Network

Deployed on Elysium mainnet, chain id `99901`. Gas is HYPE. The pool manager is Uniswap v4 at `0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1`.

| Contract | Address |
|---|---|
| Launch factory | [`0x69292cAc35eb171756e2f3566B7A3743c8007A4E`](https://elysium.kinetiq.xyz/address/0x69292cAc35eb171756e2f3566B7A3743c8007A4E?tab=contract) |
| Launch hook | [`0x03fE4115BE83A42583E20fAfC018920eAa4978eC`](https://elysium.kinetiq.xyz/address/0x03fE4115BE83A42583E20fAfC018920eAa4978eC?tab=contract) |
| Token master | [`0x43557a40Dc80C69a3D2Ef2C382e7bB14A253Aec5`](https://elysium.kinetiq.xyz/address/0x43557a40Dc80C69a3D2Ef2C382e7bB14A253Aec5?tab=contract) |
| Fee splitter master | [`0x62D5F8073dc45a47c805fA1590a280343CE6e561`](https://elysium.kinetiq.xyz/address/0x62D5F8073dc45a47c805fA1590a280343CE6e561?tab=contract) |
| Router | [`0xfa4cf19A1D18f3376e5a64Fb5eA49E389fA168DE`](https://elysium.kinetiq.xyz/address/0xfa4cf19A1D18f3376e5a64Fb5eA49E389fA168DE?tab=contract) |
| Quote registry | [`0xe23Cd90Ea893d534Fce972e5DE89357f3f90037c`](https://elysium.kinetiq.xyz/address/0xe23Cd90Ea893d534Fce972e5DE89357f3f90037c?tab=contract) |
| Protocol fee vault | [`0x3c8cF4f138B8a5B3e35735Ca7D12302bfa17687a`](https://elysium.kinetiq.xyz/address/0x3c8cF4f138B8a5B3e35735Ca7D12302bfa17687a?tab=contract) |

Source for each contract is verified on the explorer. RPC: `https://rpc.elysium.kinetiq.xyz`.

## Launch

Call `LaunchFactory.launch`. The factory clones `LaunchToken` from the master, registers the pool with `LaunchHook`, initializes a dynamic-fee Uniswap v4 pool, and seeds a one-sided position that holds only the new token. The caller does not deposit quote as liquidity.

`supply` of `0` uses the config’s base supply. Any other supply must be a whole token amount between 1 and 1,000,000,000,000 tokens. The opening tick is scaled from the config tick when the supply differs from the base supply.

For a native quote, `msg.value` must equal `launchFee + firstBuyAmount`. The launch fee is currently 0. An optional first buy in the same transaction is exempt from the hook fee. `firstBuyMinOut` reverts the launch if the tokens received are below that amount. Unused native value and unused ERC-20 quote are returned to the caller.

Fee routing:

| `feeRecipients` | Who receives creator fees |
|---|---|
| Empty | The launching address |
| One address, with `feeShares[0] == 10000` | That address |
| `address(1)` | The token, as a holder reward stream |
| Two to four addresses | A `FeeSplitter` clone, with shares in basis points |

Passing `address(1)` in a longer list also points that share at the token. A recipient that is the token itself locks the fee route.

## Published tier

Config `0` is the live HYPE tier. The quote is native HYPE (`address(0)`).

| Parameter | Value |
|---|---|
| Base supply | 1,000,000,000 tokens |
| Tick spacing | 200 |
| Start tick | 169800 |
| Graduation distance | 28,200 ticks |
| LP-fee distance | 49,600 ticks |
| Total fee | 1% |
| Protocol fee | 0.4% of the traded leg |
| LP fee, after the LP line | 0.1% inside the pool |
| Holder stream | 3,600 seconds |
| Early-buy surcharge | Off |

For a native-quote pool the token is currency1, so a buy is `zeroForOne` and the tick falls as the token price rises. Graduation is reached when the tick has moved the graduation distance from the open. The next swap confirms it. The LP fee turns on only after the price has also crossed the LP line and stayed there for the hook’s hold, which is 600 seconds on this deployment.

Before that, the hook takes the full 1%: 0.6% to the creator side and 0.4% to the protocol vault. After the LP fee is active, 0.1% is charged by the pool and the hook fee drops so the total stays 1%. The protocol share stays 0.4% of the leg. Sales do not pay an early-buy surcharge. Fees on a live pool can only be lowered.

Creator fees accrue on the hook and are collected with `claim`. Protocol fees are collected with `collectProtocol`. If the recipient is the token, `distribute` pulls creator fees into a reward stream and holders call `claimRewards`. Accounts that cannot hold circulating supply, including the pool manager, the hook, and the token itself, are excluded from that stream. `harvestSeed` is permissionless and credits quote fees earned by the seed position to the creator tab.

`LaunchRouter.swapExactInput` is an exact-input swap against one launch pool, with a minimum output check. Native input must be sent as `msg.value`.

## Layout

| Path | Role |
|---|---|
| `src/LaunchFactory.sol` | Launch entry point and config registry |
| `src/LaunchHook.sol` | Pool hook: seed liquidity, fees, graduation |
| `src/LaunchToken.sol` | Cloneable token and holder reward stream |
| `src/FeeSplitter.sol` | Splits one pool’s creator fee across two to four recipients |
| `src/LaunchRouter.sol` | Exact-input swaps |
| `src/QuoteRegistry.sol` | Quotes the factory is allowed to launch against |
| `src/ProtocolFeeVault.sol` | Holds protocol fees |
| `script/Deploy.s.sol` | Deploys the system and mines the hook address |
| `test/Launch.t.sol` | Launch, fee, graduation, and reward tests |

`pushBountyBps` and `pushFloor` are stored on each token. Nothing in the current contracts pays a push bounty.

## Development

Solidity 0.8.26, optimizer on, 10,000 runs, via IR, Cancun. `foundry.toml` remaps `forge-std/` and `v4-core/`. Those libraries are installed locally under `lib/` and are not committed. v4-core needs its `solmate` dependency at `lib/v4-core/lib/solmate`.

```shell
forge test
forge script script/Deploy.s.sol --tc Deploy --rpc-url https://rpc.elysium.kinetiq.xyz --broadcast --private-key $PRIVATE_KEY
```

`--tc Deploy` is required. `HookDeployer` is a second contract in the same file, and the hook salt is mined against that deployer’s address so the hook’s permission bits are valid.

## Status

The Elysium deployment above is the live system. Treat the contracts as unaudited. Review the source and the tests before launching a token or routing value through them.
