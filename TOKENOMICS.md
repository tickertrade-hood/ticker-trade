# $TICK — protocol token & fee-sharing design

Status: design + built staking engine (2026-07-09). Not deployed.

## The core idea: real yield, not emissions
The protocol already earns **real USDG revenue**:
- **70% of every 1% trade fee** across all tickers, and
- **a $50 launch fee** per ticker created.

`$TICK` turns that revenue stream into token value the honest way: **stake $TICK → earn a pro-rata share of that USDG.** No inflationary emissions funding the yield — the yield is actual protocol fees. (This is the xSUSHI / GMX-fee model, not a farm.)

## Why a fixed 1B supply is correct *here* (and wrong for tickers)
Trader tickers are **bonding-curve tokens** — minted/burned as money flows in/out, so they can carry a real floor. `$TICK` is the opposite: a **governance + fee-right token** with a **fixed 1,000,000,000 supply**, no curve, no floor — its value comes purely from the fee stream it entitles you to. Fixed supply is exactly right for a value-accrual token and exactly wrong for a backed ticker. Don't confuse the two.

## What $TICK does (three utilities)
1. **Fee-share staking (built).** Stake $TICK in `FeeStaking` → claim your share of protocol USDG fees anytime. Real yield.
2. **Governance over the asset whitelist.** As we move to an append-only, timelocked asset registry (v2), $TICK stakers vote on which new stocks/ETFs/crypto get listed. This ties the token directly to the thing that grows the platform.
3. **(Optional) launch boosts / fee discounts.** Stakers can get reduced trading fees or boosted creator-fee share — a demand sink that rewards holding.

## Fee flow (how revenue reaches stakers)
```
trades + launches  ──1% fee, $50 launch──►  RhTickerHub.protoFees  (USDG)
        withdrawProtocolFees()  ──►  FeeDistributor  (treasury = distributor)
                                   ├─ stakeBps  ──►  FeeStaking.fund()  → stakers claim USDG
                                   └─ 1-stakeBps ──►  team/ecosystem multisig
```
The split (`stakeBps`) is set once at deploy — e.g. **70% to stakers, 30% to the team/ecosystem**. The distributor is permissionless to crank; nobody can redirect the staker share.

## Distribution (suggested — 1,000,000,000 TICK)
| Bucket | % | Purpose |
|---|---|---|
| Community / airdrop to early users + traders | 30% | reward the people who launch & trade first |
| Staking & liquidity incentives | 20% | bootstrap staking + a TICK/USDG pool |
| Team | 18% | 1-yr cliff, 3-yr vest |
| Treasury / ecosystem | 22% | grants, market-making, future |
| Public launch / LP | 10% | initial float + price discovery |

(Team/treasury vested; nothing that lets insiders dump day one.)

## Value accrual, in one line
More tickers launched + more trading → more USDG fees → more yield to $TICK stakers → more reason to hold & stake → the token's value tracks *platform usage*, not hype. That's the flywheel.

## What's built vs. next
- **Built:** `Tick` (fixed-supply ERC20), `FeeStaking` (stake TICK, earn USDG, real-yield accumulator), `FeeDistributor` (splits protocol fees → stakers + team). Tested.
- **Next:** wire `treasury = FeeDistributor` on the next deploy; add ve-lock + governance for asset listing (pairs with the append-only registry); optional fee-discount hook in the hub.

## Honest notes
- The yield is only as big as real usage — at zero volume, staking yield is zero. This is a feature (no fake emissions), but don't market a fixed APR.
- $TICK is a governance/fee token, **not** a security claim on the vaults — vault money always belongs to ticker holders, never to $TICK.
- Regulatory: a fee-sharing token is more scrutinized than a pure-utility one. Get counsel before a public $TICK sale.
