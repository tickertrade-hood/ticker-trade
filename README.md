# ticker.trade

**Back a trader. The floor is their book.**

ticker.trade is a launchpad on [Robinhood Chain](https://docs.robinhood.com/chain/) where every token is backed by a real, on-chain trading vault. You buy in, and you can always cash out for your share of what's actually in the vault — whatever the price is doing. The trader who launched it can grow the vault by trading it, but can never touch your money.

Think of it as pump.fun, except the coin can't fall below what's actually in the pot — and that pot is a live portfolio you can see on-chain.

Founded by [@altheusresearch](https://x.com/altheusresearch).

- Live: **https://tradeticker.xyz**
- Twitter: **https://x.com/ticker_trade1**

## How it works

Every launched "ticker" has three pieces:

1. **A token** — a minimal ERC-20, minted and burned only by the hub as people buy and sell.
2. **A bonding curve** (in the hub) — a virtual constant-product curve sets the spot price. Every buy splits **80% into the vault** (the backing) and **20% into an instant-sell reserve**.
3. **A TraderVault** — one per ticker, holding USDG plus whitelisted assets (WETH today, tokenized stocks as their pools mature). The trader rotates the portfolio through a DEX; NAV is the vault's live value, priced by Chainlink.

The floor binds in both directions:

- **Below-NAV buys mint *at* NAV** with 100% going to the vault, so existing holders are never diluted — a below-floor price is a free option, not a trap.
- **Sells below NAV (or beyond the instant reserve) route to a redemption queue** that pays out at NAV, bounded to **20% of supply per epoch** with a 6-hour delay, so a bank run can't break the exit or jump the line.

The trader can trade but **cannot extract**: swaps are restricted to a whitelist, bounded to ≤0.8% versus the Chainlink price, capped at 200% of NAV per day, and there is no withdrawal path to the trader. They earn 30% of trading fees and the upside of growing their vault's floor.

For the full mechanism, threat model and the residual risks we chose to accept, see [`AUDIT.md`](./AUDIT.md).

## Contracts (`contracts/src`)

| Contract | Role |
|---|---|
| `RhTickerHub` | Curve, both-direction NAV floor, redemption queue, seed lock, graduation, fees. No owner, no proxy, no pause. |
| `TraderVault` | One per ticker. Trader swaps whitelisted assets via a venue, oracle-bounded + turnover-capped. No withdrawal path. |
| `AssetRegistry` | Immutable USDG quote + whitelisted asset feeds; values everything as ASSET/USD ÷ USDG/USD with staleness guards and ERC-8056 `uiMultiplier` handling. |
| `TickerLens` | Stateless batch reader powering the frontend / leaderboard, safe against a single stale feed. |
| `TickerToken` | Minimal per-ticker ERC-20; mint/burn only by the hub. |
| `venues/UniswapV3SpotVenue` | `ISpotVenue` adapter over Uniswap v3 — the vault is venue-agnostic and re-checks output against Chainlink, so a hostile venue can only under-deliver. |
| `venues/MarginSleeve` | Optional, capped, keeper-mediated hedge sleeve for an async perp venue (Lighter). Standalone prototype — see [`LIGHTER-ADAPTER.md`](./LIGHTER-ADAPTER.md). |
| `token/Tick` · `token/FeeStaking` · `token/FeeDistributor` | The $TICK fee token: stake TICK, earn real USDG protocol fees, streamed over time. See [`TOKENOMICS.md`](./TOKENOMICS.md). |

## $TICK

$TICK turns protocol revenue (70% of every 1% trade fee + launch fees, in USDG) into real yield: **stake TICK, earn a pro-rata share of the fees, streamed over 7 days.** No emissions — the yield is actual platform revenue. Fixed 1,000,000,000 supply. Full design in [`TOKENOMICS.md`](./TOKENOMICS.md).

## Security

This code is built to a high bar and has been through five rounds of adversarial review (see [`AUDIT.md`](./AUDIT.md)):

- **119 tests** — unit, security, scenario, and stateful invariants.
- **~250,000 invariant calls** per campaign, zero reverts, covering conservation, "the trader can never extract," "no sell prints below NAV," escrow accounting, and the staking token under a hostile keeper.
- **Live fork-tested** against real Robinhood Chain Chainlink feeds and USDG.

It has **not** had a third-party professional audit. Do your own research; nothing here is financial advice.

## Build & test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
cd contracts
forge install foundry-rs/forge-std   # first time only
forge build
forge test                            # full suite
FOUNDRY_PROFILE=stress forge test     # heavy fuzz + invariants
```

## Frontend

`web/` is a dependency-free static app (vanilla JS + vendored ethers). Serve it with any static server and it reads the chain directly. Open with `?testnet` to point at a Robinhood testnet instance, or configure `web/config.js` with your own deployment.

## Deploy

`contracts/script/Deploy.s.sol` deploys the registry, venue, hub and lens; `DeployStaking.s.sol` deploys the $TICK fee layer once the token exists. Set a `TREASURY` multisig before broadcasting to mainnet.

## License

MIT — see [`LICENSE`](./LICENSE).
