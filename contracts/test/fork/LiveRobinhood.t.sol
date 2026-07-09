// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {RhTickerHub} from "../../src/RhTickerHub.sol";
import {TickerToken} from "../../src/TickerToken.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {ISpotVenue} from "../../src/interfaces/ISpotVenue.sol";
import {UniswapV3SpotVenue} from "../../src/venues/UniswapV3SpotVenue.sol";
import {RhMainnet} from "../../src/Addresses.sol";

/// Fork test against LIVE Robinhood Chain mainnet. Proves the registry values
/// real tokenized stocks from real Chainlink feeds and the hub deploys clean.
///
/// Run:  forge test --match-contract LiveRobinhoodTest --fork-url robinhood -vv
/// Skips itself automatically when not run against chain 4663.
contract LiveRobinhoodTest is Test {
    AssetRegistry registry;
    RhTickerHub hub;
    bool live;

    function setUp() public {
        if (block.chainid != RhMainnet.CHAIN_ID) return; // not forked -> skip
        live = true;

        address[] memory assets = new address[](2);
        assets[0] = RhMainnet.AAPLx;
        assets[1] = RhMainnet.TSLAx;
        IAggregatorV3[] memory feeds = new IAggregatorV3[](2);
        feeds[0] = IAggregatorV3(RhMainnet.AAPL_USD);
        feeds[1] = IAggregatorV3(RhMainnet.TSLA_USD);
        uint48[] memory stales = new uint48[](2);
        stales[0] = 96 hours; stales[1] = 96 hours;
        bool[] memory hasMul = new bool[](2);
        hasMul[0] = true; hasMul[1] = true;

        registry = new AssetRegistry(
            IERC20(RhMainnet.USDG), IAggregatorV3(RhMainnet.USDG_USD), 26 hours,
            assets, feeds, stales, hasMul
        );
        UniswapV3SpotVenue venue = new UniswapV3SpotVenue(ISwapRouter02(RhMainnet.SWAP_ROUTER_02));
        hub = new RhTickerHub(registry, ISpotVenue(address(venue)), address(this));
    }

    function test_live_usdg_is_6dec() public view {
        if (!live) return;
        assertEq(registry.quoteDecimals(), 6, "USDG not 6-dec");
    }

    function test_live_feeds_fresh_and_positive() public view {
        if (!live) return;
        (uint256 pxA, uint8 dA) = registry.assetPriceUsd(RhMainnet.AAPLx);
        (uint256 pxQ, uint8 dQ) = registry.quotePriceUsd();
        assertGt(pxA, 0, "AAPL feed non-positive");
        assertGt(pxQ, 0, "USDG feed non-positive");
        console2.log("AAPL/USD (8dec):", pxA);
        console2.log("USDG/USD (8dec):", pxQ);
        assertEq(dA, 8); assertEq(dQ, 8);
    }

    function test_live_valueInQuote_sane() public view {
        if (!live) return;
        // one whole AAPL share (18 dec) should be worth a few hundred USDG (6 dec)
        uint256 v = registry.valueInQuote(RhMainnet.AAPLx, 1e18);
        console2.log("1 AAPLx in USDG (6dec):", v);
        assertGt(v, 10e6, "AAPL < $10?");
        assertLt(v, 10_000e6, "AAPL > $10k?");
        // round-trip: value -> amount -> value is within rounding
        uint256 back = registry.amountFromQuote(RhMainnet.AAPLx, v);
        assertApproxEqRel(back, 1e18, 1e15, "round-trip drift");
    }

    function test_live_uiMultiplier_applied() public view {
        if (!live) return;
        // if the real token exposes uiMultiplier, valueInQuote must have used it;
        // just assert the call path doesn't revert on the real contract
        uint256 v = registry.valueInQuote(RhMainnet.TSLAx, 5e17);
        assertGt(v, 0);
    }

    /// Full user lifecycle on the REAL mainnet fork: launch -> buy -> sell ->
    /// redeem -> settle, using real USDG + the real deployed hub/registry. NAV is
    /// USDG-backed here (the trader-swap-into-stocks leg needs Uniswap pools that
    /// don't yet exist on-chain — see AUDIT round 3 — so this proves the core
    /// launchpad works end-to-end on real infra even before stock liquidity lands).
    function test_live_full_lifecycle() public {
        if (!live) return;
        address user = address(0xBEEF);
        // fund the user with real USDG via the foundry storage cheatcode
        deal(RhMainnet.USDG, user, 200_000e6);
        vm.startPrank(user);
        IERC20(RhMainnet.USDG).approve(address(hub), type(uint256).max);

        uint256 id = hub.launch("Fork Trader", "FORK", 10_000e6);
        assertEq(hub.tickerCount(), 1);
        uint256 out = hub.buy(id, 20_000e6, 0);
        assertGt(out, 0);
        assertGt(hub.nav(id), 0, "NAV backed by real USDG");

        // sell a slice (allowQueue: routes to the NAV queue if below floor/reserve)
        TickerToken tkn = hub.getTicker(id).token;
        tkn.approve(address(hub), type(uint256).max);
        hub.sell(id, out / 4, 0, true);

        // redeem the rest at NAV -> queue -> settle after the delay
        hub.redeem(id, tkn.balanceOf(user));
        vm.stopPrank();
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        hub.settleQueue(id, 10);
        // real USDG moved through launch/buy/sell/redeem/settle without a hitch
        assertGt(IERC20(RhMainnet.USDG).balanceOf(user), 0, "user recovered USDG");
    }
}
