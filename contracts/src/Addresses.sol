// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Addresses — canonical Robinhood Chain mainnet (chainId 4663) addresses.
/// @notice Verified 2026-07-09 against docs.robinhood.com/chain/contracts,
///         Chainlink RDD (feeds-robinhood-mainnet.json) and live eth_call.
///         Quote token is USDG (Paxos Global Dollar) — the chain's primary
///         stablecoin; bridged USDC exists but is thin (~$10k). See RH-CHAIN.md.
library RhMainnet {
    uint256 internal constant CHAIN_ID = 4663;

    // stablecoin quote + its feed
    address internal constant USDG      = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD  = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // Uniswap v3
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant V3_FACTORY      = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    // WETH — the ONE vault asset with real liquidity today (~$1.5M USDG/WETH pool).
    // Not a uiMultiplier token; crypto feed updates frequently. Tradeable at launch.
    address internal constant WETH     = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant WETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    // sample tokenized stock/ETF tokens (BeaconProxy -> shared Stock impl)
    address internal constant AAPLx = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLAx = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant NVDAx = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant SPYx  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant QQQx  = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;

    // their Chainlink "Robinhood X / USD" feeds (8 dec)
    address internal constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant TSLA_USD = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant NVDA_USD = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant SPY_USD  = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address internal constant QQQ_USD  = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;
}
