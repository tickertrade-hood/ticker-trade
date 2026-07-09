// TICKER.TRADE — config. Open with ?local to use a local anvil stack (real
// contracts + mock USDG + a working faucet) for full click-through testing.
window.CFG_LOCAL = {
  chainId: 31337,
  chainIdHex: '0x7a69',
  chainName: 'Anvil Local',
  rpc: 'http://localhost:8545',
  rpcFallback: 'http://localhost:8545',
  explorer: '',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  hub: '0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e',
  lens: '0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0',
  registry: '0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6',
  usdg: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
  usdgDecimals: 6,
  slippageBps: 100,
  faucet: true, // mock USDG has a public mint()
  assets: [
    { sym: 'AAPL', name: 'Apple',  token: '', poolFee: 3000 },
    { sym: 'TSLA', name: 'Tesla',  token: '', poolFee: 3000 },
    { sym: 'NVDA', name: 'Nvidia', token: '', poolFee: 3000 },
  ],
};

// Robinhood testnet (chain 46630) — pre-computed deterministic addresses for the
// TestnetDeploy from deployer 0x4800…A743 (nonce 0). Live after you broadcast.
window.CFG_TESTNET = {
  chainId: 46630,
  chainIdHex: '0xb626',
  chainName: 'Robinhood Testnet',
  rpc: 'https://rpc.testnet.chain.robinhood.com',
  rpcFallback: 'https://rpc.testnet.chain.robinhood.com',
  explorer: 'https://explorer.testnet.chain.robinhood.com',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  hub: '0xf9B2D625d1C3721C681d68672Ad13373484a6a94',
  lens: '0x0846424662bE0B779E13B1882949888701d56b48',
  registry: '0x937FDA537624EfEf550dE4De78876eE1fc407a4A',
  usdg: '0xBe384C27E88072E5EA00EAa41B963E30cfBEb25B',
  usdgDecimals: 6,
  slippageBps: 100,
  faucet: true,
  deployBlock: 88500000, // events indexed from here (chart / feed)
  // $TICK fee-sharing (fill after DeployStaking): tick token + FeeStaking address
  tick: '', feeStaking: '',
  assets: [
    { sym: 'AAPL', name: 'Apple',  token: '', poolFee: 3000 },
    { sym: 'TSLA', name: 'Tesla',  token: '', poolFee: 3000 },
    { sym: 'NVDA', name: 'Nvidia', token: '', poolFee: 3000 },
  ],
};

window.CFG_MAINNET = {
  chainId: 4663,
  chainIdHex: '0x1237',
  chainName: 'Robinhood Chain',
  rpc: 'https://rpc.mainnet.chain.robinhood.com',
  rpcFallback: 'https://rpc.mainnet.chain.robinhood.com',
  explorer: 'https://robinhoodchain.blockscout.com',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },

  // ---- deploy outputs (fill in after broadcast; empty => DEMO mode) ----
  hub: '',
  lens: '',
  registry: '',

  // quote token
  usdg: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
  usdgDecimals: 6,

  slippageBps: 100, // 1%

  deployBlock: 0, // set to the hub deploy block after mainnet deploy (chart/feed range)
  // $TICK fee-sharing — paste the NOXA-launched token + the FeeStaking address
  tick: '', feeStaking: '',

  // vault-asset universe surfaced in the trader console (must match the
  // deployed AssetRegistry whitelist)
  assets: [
    { sym: 'AAPL', name: 'Apple',      token: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9', poolFee: 3000 },
    { sym: 'TSLA', name: 'Tesla',      token: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d', poolFee: 3000 },
    { sym: 'NVDA', name: 'Nvidia',     token: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC', poolFee: 3000 },
    { sym: 'SPY',  name: 'S&P 500',    token: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C', poolFee: 3000 },
    { sym: 'QQQ',  name: 'Nasdaq 100', token: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68', poolFee: 3000 },
  ],
};

// pick config: ?local -> local anvil, ?testnet -> Robinhood testnet, else mainnet
(function () {
  const q = new URLSearchParams(location.search);
  window.CFG = q.has('local') ? window.CFG_LOCAL
    : q.has('testnet') ? window.CFG_TESTNET
    : window.CFG_MAINNET;
})();
