# Robinhood Chain — deployment facts (verified 2026-07-09)

Arbitrum Orbit L2, mainnet live 2026-07-01. Permissionless contract deploys
(standard Solidity, no changes). ETH gas. Single Robinhood-operated sequencer
(no mempool; latency-race ordering). Chainlink is the official oracle layer.

## Network
- Mainnet chainId **4663** — RPC `https://rpc.mainnet.chain.robinhood.com` (Alchemy primary), explorer `https://robinhoodchain.blockscout.com`
- Testnet chainId **46630** — RPC `https://rpc.testnet.chain.robinhood.com`, faucet `https://faucet.testnet.chain.robinhood.com/`
- **No Chainlink L2 Sequencer Uptime Feed** exists for this chain (confirmed absent) — see AUDIT.md residual #1.

## Quote token: USDG (not USDC)
- **USDG (Paxos Global Dollar)** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6-dec — the chain's primary stablecoin. Bridged USDC exists (`0x80e0…6cA8`) but supply is ~$10k (thin); USDG is what the docs' Token Contracts page lists and what Uniswap depth will be in.
- USDG/USD feed `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` (8-dec) — verified live $0.9998.

## Tokenized stocks (vault assets)
- BeaconProxy → shared "Stock" impl (beacon-upgradeable by Robinhood). **Blocklist, not allowlist** — standard ERC-20s, arbitrary contracts CAN hold them (our TraderVault does). Admin powers: pause, `adminBurn` (confiscation), role-gated mint/burn, ERC-8056 `uiMultiplier` (splits/dividends). 18-dec.
- Sample tokens + "Robinhood X / USD" feeds (8-dec) hardcoded in `src/Addresses.sol`: AAPL, TSLA, NVDA, SPY, QQQ (20 stocks + 5 ETFs available total).

## Uniswap (trader swap venue) — ⚠️ POOLS EMPTY (verified 2026-07-09)
- v3 SwapRouter02 `0xCaf681a66D020601342297493863E78C959E5cb2`, Factory `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`. (v4 also deployed.) 1inch + **Lighter** also live.
- **CRITICAL:** an on-chain census found the tokenized-stock/USDG pools are empty or nonexistent — AAPLx & SPYx have NO pool at any fee tier; TSLAx/USDG has zero liquidity. Only USDG/WETH (~1,268 WETH / 1.16M USDG) has depth. **A trader cannot swap USDG→stock via Uniswap today.** The vault's `exactInputSingle` single-hop path can't reach stock liquidity. Resolve the swap venue (Lighter/RFQ) or seed pools before enabling trading. See AUDIT.md "PRODUCT BLOCKER".

## Deploy
```
forge script script/Deploy.s.sol --rpc-url robinhood            # dry run
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $PK
```
Set `TREASURY` env to a multisig. The hub has no admin surface; treasury is only the fee sink.
