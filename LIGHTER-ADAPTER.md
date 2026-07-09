# Lighter integration spec — TICKER.TRADE on Robinhood Chain

Status: **spec + guarded prototype** (2026-07-09). Not deployed.
Grounded in a primary-source review of Lighter's docs/API and live on-chain checks.

## TL;DR

**Lighter cannot be a Uniswap-style synchronous swap adapter.** Three hard facts from Lighter's own docs kill that shape:

1. **Contracts can't trade.** "Smart contracts cannot place orders — only private key holders (EOAs or API signers) can sign transactions." Orders are off-chain signed messages (API key + nonce) sent to Lighter's sequencer. A vault contract can't produce them.
2. **It's async.** The on-chain surface is only *deposit* and *withdraw* against the **Lighter Relayer**. Trading is: on-chain deposit → off-chain signed order → sequencer match (sub-10ms soft finality) → batched ZK settlement → on-chain withdraw. There is no atomic `swap()` that fills in the same tx.
3. **Stock markets are perps, and position value is off-chain.** Lighter's tokenized-stock markets are USDG-margined **perpetual futures** (synthetic exposure, not the real ERC20 our spot vault holds). Position value / PnL live in the off-chain L2 state — **not readable by an on-chain `view`** for NAV.

So any Lighter integration reintroduces exactly what we removed leaving HyperCore: an **off-chain keeper/signer** and a **pushed (not staticcall-able) NAV oracle**. That is a strictly weaker trust model than the trustless spot core. The design below therefore **quarantines** Lighter as an *optional, capped hedge sleeve* that can never touch the trustless spot NAV.

## Two-part design

### Part A — venue abstraction (built, trustless) — `ISpotVenue`
The vault no longer hardcodes Uniswap. It routes spot swaps through `ISpotVenue.swapExactIn(...)`. The venue is **untrusted**: the vault approves exactly `amountIn`, and re-verifies the output by its own balance diff against the Chainlink bound (`SlippageVsOracle`). This means:
- We can point spot swaps at **whatever venue has liquidity** — Uniswap v3 (`UniswapV3SpotVenue`, built), or later 1inch / Arcus / Rialto — without touching the vault. (Directly addresses the round-3 finding that Uniswap's stock/USDG pools are empty.)
- A hostile/lying venue can only *under*-deliver (rejected by the vault) — never over-pull. Proven by `test_vault_slippageSelfCheck_vs_lyingRouter`.

This is the recommended path for **spot** stock exposure and preserves the trustless NAV.

### Part B — async hedge sleeve (built as a guarded prototype) — `MarginSleeve`
For synthetic/leveraged exposure or hedging via Lighter perps, an **optional, capped** `MarginSleeve` per vault. It captures the minimal on-chain Lighter surface (`ILighterRelayer`: deposit/withdraw/collateralOf) and the keeper trust, behind hard guardrails.

**Roles.** `owner` = the vault/hub. `keeper` = the trader's off-chain signer (holds the Lighter API key). `relayer` = Lighter's on-chain escrow.

**The three enforced invariants (`MarginSleeve`, tested in `MarginSleeve.t.sol`):**
1. **The keeper can never receive funds.** No function transfers quote to the keeper. Lighter binds withdrawals to the depositing address (the sleeve), so venue funds return to the sleeve; only the `owner` can `sweepToOwner`, and only to itself. → `test_keeper_cannot_extract`.
2. **Redeemable value = realized on-chain quote only** (`idleQuote + escrowedCollateral`), **never** the keeper's `reportedEquity`. A compromised keeper reporting a fake number cannot cause over-redemption. → `test_reportedEquity_not_redeemable`.
3. **Reported equity is display-only and circuit-broken** — bounded to ±50% of on-chain collateral and staleness-gated (1h). A gain only becomes redeemable once **settled on-chain** (relayer collateral actually rises). → `test_reportEquity_deviation_circuitBreaker`, `test_realized_gain_becomes_redeemable_only_when_settled`.

**Net keeper power:** it can *lose* up to the sleeve's funded capital via bad Lighter trades (so cap the sleeve at a small fraction of the vault, e.g. ≤20%), but it can never steal to itself and never inflate what holders redeem. Losses are bounded to sleeve capital — the rest of the vault is untouched (`test_realized_loss_is_bounded_to_sleeve_capital`).

## How it would integrate (not yet wired into the hub)

The prototype `MarginSleeve` is standalone by design — it is **not** bolted into `RhTickerHub`, so it cannot destabilize the audited trustless core. To adopt it, a future hub version would:
1. Deploy one `MarginSleeve` per opting-in ticker, `owner = hub`, `keeper = trader`.
2. Add a hub-enforced **cap**: `sleeve capital ≤ SLEEVE_CAP_BPS × vaultValue` (e.g. 2000 = 20%).
3. Include `sleeve.redeemableValue()` in NAV — **realized only**. Never `reportedEquity`.
4. Route redemption cranks to `sleeve.sweepToOwner` when the spot vault's quote is short (like the existing `forceRaise`, but pulling realized sleeve funds).
5. Keep the off-chain keeper infra (API-key signer + an equity-reporter bot) out of the trust base for redemptions.

## Threat model (sleeve)

| Actor / failure | Can it happen? | Bound |
|---|---|---|
| Keeper steals to own wallet | **No** | No keeper-facing transfer exists; withdrawals bound to sleeve; sweep is owner-only |
| Keeper inflates NAV → over-redeem | **No** | Redeemable = realized on-chain quote; reported equity excluded |
| Keeper loses money trading badly | Yes | Capped at sleeve capital (owner-set cap); rest of vault safe |
| Keeper reports absurd equity | Display only, and | Circuit-broken to ±50% collateral + 1h staleness |
| Relayer/Lighter insolvency or sequencer halt | External risk | Sleeve capital at risk = the deposited amount; escape-hatch withdrawal per Lighter design |
| Owner (hub) misbehaves | Out of scope | Hub is immutable/no-admin by design |

## Honest recommendation

- **v1: spot only, via `ISpotVenue`.** Trustless NAV, no keeper. Blocker is liquidity, not code — point the venue at whatever spot book (Uniswap/1inch/Arcus/Rialto) actually has depth, or seed one.
- **v2 (optional): capped Lighter hedge sleeve** for shorts/leverage, using `MarginSleeve` with a ≤20% cap and realized-only NAV. It is genuinely useful (the "back a trader who can short" story) but it is a *higher-trust, opt-in* component — do not market it as trustless, and cap the blast radius.
- Do **not** attempt a "Lighter as the spot venue" integration for the real tokenized stocks — Lighter trades perps, not the ERC20s, and can't be called by a contract.

## Files
- `src/interfaces/ISpotVenue.sol`, `src/venues/UniswapV3SpotVenue.sol` — Part A (built, in the deploy path).
- `src/interfaces/ILighterRelayer.sol`, `src/venues/MarginSleeve.sol` — Part B (built prototype, standalone).
- `test/MarginSleeve.t.sol` — the invariant proofs above.

Unverified: the real Lighter Relayer contract address on chain 4663 (not published), and the exact deposit/withdraw ABI (the interface here is the minimal shape from docs). Re-verify against the deployed relayer before any mainnet wiring.
