# TICKER.TRADE — Robinhood Chain — Security Audit & Hardening Log

Self-audit + two adversarial agent reviews (one Solidity-focused, one economic/
oracle-focused) over the frozen source, backed by a 65-test suite and a
131k-call stateful invariant campaign. Date: 2026-07-09.

## Architecture (what changed vs the HyperEVM version)

The HyperEVM v0.2 backed each ticker with a **HyperCore native vault** and read
NAV from the `userVaultEquity` precompile (`0x…0802`), depositing via CoreWriter
(`0x3333…`). None of that exists on Robinhood Chain. The Robinhood build replaces
it with a fully on-chain, trustless equivalent:

| Concern | HyperEVM v0.2 | Robinhood build |
|---|---|---|
| Vault | HyperCore native vault | `TraderVault` contract (holds USDG + whitelisted stocks) |
| NAV source | `userVaultEquity` precompile | `AssetRegistry` Chainlink feeds (ASSET/USD ÷ USDG/USD) |
| "Trader can't withdraw" | enforced by HyperCore | enforced by `TraderVault` ACL + per-swap oracle bound + turnover cap |
| Deposit/withdraw | CoreWriter bridge | direct ERC20 transfers hub ↔ vault |
| Quote token | USDC | **USDG** (chain's primary stablecoin; USDC liquidity is thin) |

The curve / NAV-floor / redemption-queue / seed-lock / graduation mechanics are
ported 1:1 and their regression tests carried over.

## Machine-checked guarantees (foundry)

Stress profile: 5,000-run fuzz + invariants at 256 runs × 512 depth = **131,072
calls, 0 reverts**. Invariants held throughout:

- `invariant_hubQuoteConservation` — hub USDG balance == protoFees + Σ(exitReserve + creatorFees), exactly, after every op.
- `invariant_traderNeverExtracts` — traders' aggregate cash never exceeds their funding + claimed creator fees (they can never pull vault value).
- `invariant_noPrintBelowNav` — no executable curve sell prices below NAV.
- `invariant_escrowAccounting` — hub token custody == escrowed seed + queued redemptions, exactly.

## Findings & dispositions

### FALSE POSITIVES (disproven by the invariant campaign)

- **"Critical: exitReserve debited by `gross` but credited only 20% → cross-ticker drain."** The `quoteSell` floor routes any sell with `gross > exitReserve` to the redemption queue, so a curve sell can only ever draw down USDG the reserve actually holds. Conservation is machine-proven over 131k calls including the exact cross-ticker sequences described. Not a bug.
- **"Critical: navMint mint-basis inconsistent with redeem-basis → atomic NAV extraction."** `test_navMint_preserves_nav_exactly`, `test_discount_arb_cycle_is_negative_ev`, and `test_navMint_roundtrip_loses_money` all pass; `invariant_noPrintBelowNav` holds. Below-NAV mints put 100% into the vault at exactly NAV, so no same-tx extraction. The *real* version of this concern is the cross-time buy-side latency arb (E-1), fixed below.

### FIXED

- **S-2 (High) — `syncHeld` DoS.** Was permissionless; an attacker could donate 1 wei of a weekend-idle listed stock and `syncHeld` it into an otherwise-quote vault, so its stale feed would revert the whole vault's NAV every weekend (bricking buys/sells/redemptions). **Fix:** `syncHeld` is now trader/hub-only (`TraderVault.sol`). The trader has no incentive to grief their own book.
- **S-3 (Medium) — rounding-to-zero slippage bypass.** A swap tiny enough that `valueQ` or `fairOut` floored to 0 made the oracle slippage bound 0 (any output accepted) and evaded the turnover counter. **Fix:** `_boundedMinOut` reverts `BadAmount` when `valueQ == 0 || fairOut == 0`.
- **S-4 (Medium) — `MIN_REDEEM_VALUE` mis-scaled.** Was `10_000` raw = $0.01 in 6-dec USDG. Combined with `forceRaise`, a 1-cent floor made queue flooding cheap. **Fix:** raised to `10e6` = $10.
- **E-1/E-2 (High/Med) — at-NAV mint against a stale mark.** The sell side is delayed (6h) and gated (20%/epoch) but buys were instant and ungated, so on a discrete NAV jump (weekend gap-up, earnings, sequencer-outage resume) an arber could mint at a stale-low NAV and capture existing holders' gain. **Fix:** below-NAV mints now require `vault.mintFresh()` — every held stock feed (and the quote feed) must have updated within `MINT_FRESH = 30h`. Weekend/holiday marks are not mintable; above-NAV curve buys stay open (they carry a premium, so no theft). Regression: `test_navMint_blocked_when_feed_stale`.
- **E-3 (Med) — turnover cap too generous.** 300%/day turnover × 0.8% slippage = 2.4%/day worst-case trader bleed (~52% over the 30-day graduation window). **Fix:** `TURNOVER_BPS` lowered 30_000 → 10_000 (100%/day), capping worst-case bleed to 0.8%/day. No legitimate stock-rebalance strategy needs more.

### RESIDUAL RISKS (documented, accepted for a prototype; address before large TVL)

1. **No L2 Sequencer Uptime Feed on Robinhood Chain (confirmed absent).** We rely on per-feed staleness only. The `mintFresh` gate (30h) closes the *buy* side of a sequencer-resume jump; redemptions are already delayed + gated. A NAV-move-per-block circuit breaker would be the belt-and-suspenders upgrade. Ranked #1 residual.
2. **`forceSell` MEV.** Forced liquidations pass `minOut=0` and rely on the 0.8% oracle bound; a pool sandwich can extract up to 0.8% per forced sell, and forced sells skip the turnover cap. Bounded per-call by the shortfall (+5%) and, now, by the $10 redemption floor. Mitigation upgrade: pass an explicit hub-computed `minFair` and/or a `sqrtPriceLimitX96`.
3. **Issuer power over stock tokens.** Robinhood can pause (halts vault swaps + forceRaise; NAV valuation still reads), `adminBurn` (confiscation → NAV reprices down immediately — `test_scenario_issuer_adminBurn…`), and beacon-upgrade all stock tokens. External to this protocol; holders bear tokenized-stock issuer risk. If a stock token ever ships a transfer hook, add a same-tx hub guard (currently USDG + stock tokens are hookless).
4. **Symbol squatting.** `symbolTaken` is global/permanent for `LAUNCH_FEE + MIN_SEED` (~$560). First-come; no release path. Accepted.
5. **USDG/USD feed must be a real market feed, not a hardcoded $1.** Verified live: reads $0.9998 with real staleness. Re-check if the feed is ever repointed.

## Round 2 — regression audit of the fixes (2026-07-09)

A second adversarial agent reviewed the post-fix source specifically for regressions. It confirmed **no fix introduced a fund-loss/extraction path** (the four invariants still hold), disproved nothing new, and found the two round-1 fixes had over-tightened into **liveness** regressions:

- **R-A (fixed) — `MINT_FRESH=30h` too tight.** Measured live feed ages on Robinhood mainnet: a quiet ETF feed (SPY) sits **13h stale mid-session**, and a weekday overnight close approaches ~24h. A 30h gate would have reverted legitimate below-NAV buys pre-open. **Raised to 36h** — clears normal weekday activity, still blocks multi-day weekend/holiday marks (>48h). Regression tests added both ways: `test_navMint_allowed_within_weekday_overnight_gap` (30h → allowed) and `test_navMint_blocked_when_feed_stale` (40h → blocked). Residual: a weekday *overnight earnings gap* in the pre-open window is not fully closed by a pure time-staleness gate; mitigated by the 6h redeem delay + feeds catching up within minutes of open. A NAV-move circuit breaker is the belt-and-suspenders upgrade.
- **R-B (fixed) — turnover 100%/day blocked an honest same-day full rotation.** A trader de-risking and re-risking the same day needs 200%. **Raised `TURNOVER_BPS` to 200%/day** (worst-case bleed 1.6%/day, still on-chain-visible with NAV exit). Test rewritten to prove one full de-risk + re-risk fits and a third rotation reverts.
- **Verified safe (no change):** mint gate is single-path and non-bypassable (seed buy at launch has supply 0 → nav 0 → never navMint → never spuriously blocked); `syncHeld` gate leaves no untracked-value hole (swaps auto-track their output; donations only *raise* NAV); new `assetUpdatedAt`/`quoteUpdatedAt` views are fail-closed and listed-only; MIN_REDEEM $10 traps only sub-$10 below-NAV holders, who still have the curve-sell exit.

## New: `TickerLens` (read-only) + Robinhood-native frontend

- **`TickerLens.sol`** — stateless batch reader; `snapAll()` returns every ticker's live snapshot (price, NAV floor, AUM, premium, queue depth, mintFresh, graduation) in one call. Feed-dependent reads are `try/catch`-guarded so one stale ticker can't brick the board. Touches no core state, holds no privilege. 4 tests.
- **`web/`** — vanilla dapp (no build step, vendored ethers) tailored to Robinhood Chain: USDG settlement, real stock universe (AAPL/TSLA/NVDA/SPY/QQQ), chain-4663 wallet config, Robinhood-green editorial theme. Gamification derived purely from on-chain metrics: trader tiers (Rookie→Pro→Graduated→Legend), XP levels + composite score leaderboard, badges (AT FLOOR / HOT / FEED STALE / GRAD / QUEUE). Renders a labelled DEMO dataset until `CFG.hub/lens` are set post-deploy. Visually verified in headless Edge (board, leaderboard, detail).

## Final verification (2026-07-09, post-round-2)

- 76 tests green; stress profile (5,000 fuzz + 131,072 invariant calls) 0 reverts; live fork test green (AAPL $313.93, USDG $0.9998).

## Round 3 — 8-agent deep review (2026-07-09)

Eight parallel subagents: exhaustive security, gas/performance, line-coverage, frontend security, deploy-readiness + live pool check, and economic validation. Findings + dispositions:

### 🔴 PRODUCT BLOCKER (not a code bug) — Uniswap stock/USDG pools are empty on mainnet
A live on-chain census (factory.getPool across all fee tiers) found: **AAPLx and SPYx have NO Uniswap v3 pool** at any tier vs USDG or WETH; **TSLAx/USDG exists but has zero liquidity** (3 units USDG, 5 wei TSLA). Only USDG/WETH has real depth (~1,268 WETH / ~1.16M USDG). **Consequence: a trader cannot execute a USDG→stock swap on Robinhood Chain today** — `forceSell` and `swap` would revert, and vaults would sit 100% in USDG. The core launchpad (launch/buy/sell/redeem/settle) works perfectly on real infra (proven by `test_live_full_lifecycle` on a mainnet fork with real USDG), but the *trader-alpha* feature has no venue. **This is the gating go/no-go item** — see "Deployment decision" below. Options: (a) launch USDG-only until stock liquidity lands; (b) re-point the vault swap venue to Robinhood's tokenized-stock trading facility (RFQ/market-maker) or Lighter, a different integration than Uniswap `exactInputSingle`; (c) seed pools ourselves (makes us the LP). Do NOT ship expecting Uniswap stock trading to work.

### 🔴 CRITICAL (fixed) — frontend stored XSS
Ticker `name`/`symbol` (attacker-controlled via `launch`) flowed raw into `innerHTML` across board/leaderboard/detail/trade — a launched ticker named `<img onerror=...>` would run JS in every visitor's wallet-connected browser. **Fixed:** added `esc()` HTML-escaper on every chain-derived string (14 sinks), plus a CSP (`script-src 'self'`) in `index.html` and `serve.js`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and fixed a `serve.js` sibling-prefix path-traversal check.

### Fixed (contracts)
- **M-1 turnover midnight-straddle** — a UTC-midnight reset let a trader do 2× turnover in one minute. Economic agent confirmed a `createdAt`-anchor wouldn't help (trader knows their own anchor). **Fixed with a rolling-window** (accumulator decays linearly over 24h; no instant boundary grants a fresh budget). Test: `test_turnover_rolling_no_seam`.
- **M-3 trader-grown `held[]` NAV DoS** — the S-2 fix closed the *donation* path but the trader could still bloat `held[]` via `swap`. **Fixed** with `MAX_HELD=24` cap.
- **`poke()` now `nonReentrant`** — the only mutating entrypoint a hypothetical future stock-token hook could reach mid-swap (defense-in-depth; the security agent confirmed no corruption was reachable even without it).
- **Frontend sell had `minProceeds=0`** (no slippage guard on the instant-curve leg) — **fixed** to floor at `quote*(1-slippage)` (and 0 only when it routes to the NAV queue). Buy quote now warns on `StaleForMint` instead of showing a fillable quote that reverts. Wallet chain-switch re-verifies the network before signing.

### Performance (applied, behavior-identical)
- `_settleOne` hoists `circ` once (killed a double `totalSupply` read, ~10k gas/settle iteration).
- Fee-split sub-expression computed once in `buy`/`sell`.
- Confirmed the NAV `held[]` loop is bounded by the immutable whitelist (now hard-capped at 24); `RhTickerHub` runtime is 21.3KB (3.3KB under limit — watch on growth).

### Accepted / documented residuals (validated, bounded)
- **forceRaise MEV** — economic agent quantified it: gated by the 20%/epoch redemption cap to ~**$400/day-scale on a $250k vault**, NOT the "uncapped 200% bypass" first claimed. A flat 0.2% forced band was rejected — it would DoS legitimate redemptions during real off-hours gaps. Correct fix is a staleness-aware dynamic band + forced-turnover cap; deferred until the swap-venue question is resolved (moot while pools are empty). Documented.
- **Queue FIFO head-of-line blocking** — a large/starving head throttles those behind it (by design of the 20% gate; stale-feed halt is intended fail-closed). Documented; a skip-on-stuck or pull-based claim model is the future improvement.
- **Rounding** favors the vault (holders lose ≤1 unit/fill) — not attacker-favorable. Documented.

### Coverage after round 3
93 tests. `forge coverage`: AssetRegistry **29%→94%** branch (the pricing trust root), SafeTransfer 0%→100%, TickerToken 50%→100%, RhTickerHub 93%, TraderVault 77%, TickerLens 100%. Remaining uncovered branches are the `Reentered()` guards (structurally safe, need a reentrant mock) and a few edge reverts.

## Deployment decision (2026-07-09)
- **Registry + hub + lens deploy is clean** — `Deploy.s.sol` verified (all addresses valid EIP-55, arrays matched, chainid-guarded); the deploy simulates fine and reads live feeds. Ready to broadcast once given a funded key + `TREASURY` multisig.
- **BUT** the trader-trading feature is non-functional on Uniswap (empty pools). Recommendation: **do not broadcast the trading experience yet.** Either ship a "USDG vault / trading-disabled" v0 (all floor mechanics work — fork-proven), or resolve the swap venue (Lighter/RFQ integration) first. This is a product call for the owner, surfaced honestly rather than deployed broken.

## Round 4 — venue abstraction + Lighter sleeve (2026-07-09)

Research (primary Lighter docs + live on-chain) established that **Lighter cannot be a synchronous swap adapter**: contracts can't sign orders, it's async (deposit→off-chain order→settle→withdraw), stock markets are perps (not the real ERC20s), and position value isn't on-chain. Full write-up + threat model in `LIGHTER-ADAPTER.md`. Two things were built and audited:

### Part A — `ISpotVenue` abstraction (trustless, in the deploy path)
`TraderVault` no longer hardcodes Uniswap — it routes spot swaps through an untrusted `ISpotVenue.swapExactIn`, keeping all security in the vault (approve-exact → swap → revoke, output re-checked by balance-diff vs the Chainlink bound). Lets us point spot swaps at whatever venue has liquidity (Uniswap/1inch/Arcus/Rialto) — directly addressing the empty-Uniswap-pool blocker. Adapter `UniswapV3SpotVenue` built. **Audit verdict: SAFE** — a dedicated agent confirmed a hostile venue can only under-deliver (reverts), can't over-pull (approve-exact), can't reenter (vault holds its lock across the call), and can't fool the balance-diff check. `test_vault_slippageSelfCheck_vs_lyingRouter` proves it against a lying venue.

### Part B — `MarginSleeve` (async Lighter hedge sleeve, guarded prototype, standalone)
An optional, capped, keeper-mediated sleeve for Lighter perps — deliberately NOT wired into the trustless core. Three invariants, machine-checked (`MarginSleeve.t.sol` + a stateful `SleeveInvariants.t.sol` handler = 8,192 hostile-keeper calls, 0 reverts):
1. **Keeper can never receive funds** — no keeper-facing transfer; `sweepToOwner` is owner-hardcoded; withdrawals bind to the sleeve.
2. **Redeemable value = realized on-chain quote only**, never the keeper's reported equity — so a lying keeper can't cause over-redemption.
3. **Reported equity is display-only + circuit-broken** (±50% of collateral, staleness-gated).

Net keeper power: can lose ≤ the (capped) sleeve capital via bad trades, never extract, never inflate redeemable NAV.

**Audit findings applied:** constructor now rejects `owner==keeper`/zero addresses (S-9, prevents a deploy-typo extraction); `withdrawFromVenue` decrements by funds *actually received* rather than trusting the relayer (S-1/S-2); `reportedEquity` renamed **`displayEquityUnsafe`** with a screaming NatSpec so no future hub mistakes it for a redeemable number (S-4/S-7); `redeemableValue` NatSpec now states the `escrowedCollateral` relayer-trust explicitly (S-3). **Honest residual:** the sleeve's safety rests on the real Lighter relayer's withdrawal-address binding + collateral accounting, which is unverified (address not published) — flagged, and quarantined by "not wired into hub." The relayer trust is irreducible to using Lighter at all; the mitigation is the ≤20% hub-enforced cap.

### Verification (round 4)
106 tests. Venue path exercised by the whole suite (all swaps now go through the abstraction) + lying-venue guard. Sleeve: 9 unit tests + 3 stateful invariants (8,192 calls). Full stress re-run + live fork lifecycle green.

## Round 5 — full pre-mainnet adversarial sweep (2026-07-09)

Five parallel agents attacked every surface (core mechanics, trader/vault/oracle, Lighter sleeve, TICK staking, systemic/cross-contract). Two genuine exploits found + fixed, plus hardening. 117 tests.

### 🔴 CRITICAL (fixed) — flash-stake sandwich on FeeStaking
`fund()` credited rewards INSTANTLY pro-rata and `distribute()` is permissionless → an attacker could flash-borrow TICK, stake, crank distribute, claim, unstake in ONE tx and skim ~99% of every fee distribution from real stakers. **Fixed by rewriting `FeeStaking` to a streaming model (Synthetix StakingRewards):** rewards drip over `REWARD_DURATION = 7 days`, so a staker present for one block earns ~nothing. Proven: `test_flash_stake_earns_nothing` (whale flash-stake → claims 0; honest staker earns the stream over time).

### 🔴 HIGH (fixed) — forced-swap turnover bypass
`forceSell` skipped the turnover cap and `forceRaise` is permissionless, so a colluding trader could keep a standing self-redemption "starving" and route unbounded volume through the venue at the 0.8% skim, defeating the 1.6%/day bleed bound. **Fixed: every swap leg now charges turnover, forced included** (redemption needs are far below the daily cap, so legit servicing is never blocked). Test: `test_forceSell_charges_turnover`.

### Also fixed
- **R5-4 stale-mark swap extraction** — buying the vault INTO a stock valued it at a possibly-96h-stale feed. Now gated: rotating into a stock requires its feed fresh within `MINT_FRESH` (36h); selling a stock→quote (incl. forceSell for redemptions) stays ungated. Test: `test_swap_into_stale_stock_reverts`.
- **R5-2 rounding** — `minFair` now ceil-rounds so truncation favors the vault, not the pool.
- **R5 uiMultiplier==0** — clean `BadUiMultiplier` revert instead of a div-by-zero panic.
- **Sleeve M-1 escape hatch** — the owner (hub) can now also `withdrawFromVenue`, so a dark/passive keeper can't lock vault capital in the relayer forever.
- **Deploy 3.1** — mainnet `Deploy.s.sol` now REQUIRES `TREASURY` be explicitly set and ≠ the deployer (it's immutable in the hub — no silent hot-EOA fee sink).

### Accepted / documented residuals (real, need bigger work or are external)
- **Redemption-queue fairness (Agent 1 F1/F2/F4):** queued tokens stay in `circ` until settled, so a concurrent 80/20 buy can dilute a pending redeemer, and there's no user `minNav` on redeem; FIFO head-of-line lets a large redemption throttle those behind. No drain, bank-run-proof, and round-trips cost 2% fees — but it's a fairness/griefing gap. **Fix is a queue redesign (burn-on-enqueue + pull-based claims + `minNav`), planned for v2.**
- **Immutable feed (Agent 5, 5.1):** a deprecated/bad Chainlink feed can never be replaced → permanent per-asset halt. Plan: a narrowly-scoped, timelocked feed-repoint (only to another Chainlink aggregator for an already-listed asset; no fund access) — pairs with the append-only registry.
- **Stock-token issuer risk (Agent 5, 6.1):** the real RH stock tokens are pausable / blocklist / adminBurnable — Robinhood can freeze or seize, starving redemptions or cutting NAV. External and irreducible; must be surfaced prominently to users.
- **Empty stock pools (Agent 5, 2.2):** unchanged mainnet venue blocker — redemptions of a stock-heavy vault can stall until a liquid venue exists.
- **Lighter relayer unverified (Agent 3, H-1) + async settlement (M-2):** hard blockers before wiring the sleeve to mainnet; the sleeve stays standalone/opt-in until the real relayer ABI/address is confirmed.

### What the sweep confirmed strong
Cross-contract reentrancy is comprehensively defended (per-contract locks + balance-diff verification + post-callout state updates); the hub's single USDG balance is provably partitioned per-ticker with no cross-ticker draw; vaults are isolated instances; "no admin keys in the core" is true (treasury is fee-sink-only); the sleeve's keeper-can't-extract invariant holds under 131k hostile calls.

## Live-chain validation (fork test, 2026-07-09)

`test/fork/LiveRobinhood.t.sol` against `rpc.mainnet.chain.robinhood.com`:
- USDG confirmed 6-dec.
- AAPL/USD live = $312.13; USDG/USD live = $0.9998; both fresh + positive.
- `valueInQuote(AAPLx, 1e18)` = 312.19 USDG (correct through feed + uiMultiplier + USDG repeg); round-trip within 0.1%.
