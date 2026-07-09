// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";
import {TraderVault} from "../src/TraderVault.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {TickerToken} from "../src/TickerToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ISpotVenue} from "../src/interfaces/ISpotVenue.sol";
import {MockERC20, MockStock, MockFeed, MockSpotVenue} from "./mocks/Mocks.sol";

/// Shared fixture: USDG quote + AAPL/TSLA stock tokens (uiMultiplier) + WETH,
/// Chainlink-style feeds, hostile-configurable router, immutable registry + hub.
contract BaseSetup is Test {
    MockERC20 usdg;
    MockStock aapl;
    MockStock tsla;
    MockERC20 weth;

    MockFeed usdgFeed; // $1.00
    MockFeed aaplFeed; // $200
    MockFeed tslaFeed; // $250
    MockFeed wethFeed; // $1700

    MockSpotVenue router;
    AssetRegistry registry;
    RhTickerHub hub;

    address treasury = makeAddr("treasury");
    address trader = makeAddr("trader");   // launches + trades the default ticker
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint48 constant STALE_STOCK = 96 hours; // covers weekends + market holidays
    uint48 constant STALE_CRYPTO = 24 hours;
    uint48 constant STALE_QUOTE = 26 hours;

    function setUp() public virtual {
        vm.warp(1_780_000_000); // non-zero realistic start

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockStock("Apple Stock Token", "AAPLx");
        tsla = new MockStock("Tesla Stock Token", "TSLAx");
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        usdgFeed = new MockFeed(8, 1e8);
        aaplFeed = new MockFeed(8, 200e8);
        tslaFeed = new MockFeed(8, 250e8);
        wethFeed = new MockFeed(8, 1700e8);

        address[] memory assets = new address[](3);
        assets[0] = address(aapl);
        assets[1] = address(tsla);
        assets[2] = address(weth);
        IAggregatorV3[] memory feeds = new IAggregatorV3[](3);
        feeds[0] = IAggregatorV3(address(aaplFeed));
        feeds[1] = IAggregatorV3(address(tslaFeed));
        feeds[2] = IAggregatorV3(address(wethFeed));
        uint48[] memory stales = new uint48[](3);
        stales[0] = STALE_STOCK;
        stales[1] = STALE_STOCK;
        stales[2] = STALE_CRYPTO;
        bool[] memory hasMul = new bool[](3);
        hasMul[0] = true;
        hasMul[1] = true;
        hasMul[2] = false;

        registry = new AssetRegistry(
            IERC20(address(usdg)), IAggregatorV3(address(usdgFeed)), STALE_QUOTE,
            assets, feeds, stales, hasMul
        );

        router = new MockSpotVenue();
        router.setRegistry(registry);

        hub = new RhTickerHub(registry, ISpotVenue(address(router)), treasury);

        address[5] memory funded = [trader, alice, bob, attacker, address(this)];
        for (uint256 i = 0; i < funded.length; i++) {
            usdg.mint(funded[i], 50_000_000e6);
            vm.prank(funded[i]);
            usdg.approve(address(hub), type(uint256).max);
        }
    }

    // ---------- helpers ----------

    function launchDefault() internal returns (uint256 id) {
        vm.prank(trader);
        id = hub.launch("Alpha Trader", "ALPHA", 10_000e6);
    }

    function tok(uint256 id) internal view returns (TickerToken) {
        return hub.getTicker(id).token;
    }

    function vaultOf(uint256 id) internal view returns (TraderVault) {
        return hub.getTicker(id).vault;
    }

    function vaultValue(uint256 id) internal view returns (uint256) {
        return vaultOf(id).totalValueInQuote();
    }

    function exitReserveOf(uint256 id) internal view returns (uint256) {
        return hub.getTicker(id).exitReserve;
    }

    function creatorFeesOf(uint256 id) internal view returns (uint256) {
        return hub.getTicker(id).creatorFees;
    }

    function graduatedOf(uint256 id) internal view returns (bool) {
        return hub.getTicker(id).graduated;
    }

    function queueLen(uint256 id) internal view returns (uint256) {
        RhTickerHub.Ticker memory t = hub.getTicker(id);
        return t.queueTail - t.queueHead;
    }

    /// trader deploys the vault's whole USDG balance into `asset`
    function traderAllIn(uint256 id, address asset) internal {
        TraderVault v = vaultOf(id);
        uint256 bal = usdg.balanceOf(address(v));
        vm.prank(trader);
        v.swap(address(usdg), asset, bal, 0, 500);
    }

    /// move NAV above curve price: trader buys AAPL, then AAPL rips
    function pumpNavAbovePrice(uint256 id) internal {
        traderAllIn(id, address(aapl));
        aaplFeed.set(aaplFeed.answer() * 6);
        assertGt(hub.nav(id), hub.price(id), "discount state not reached");
    }

    /// crank the queue across epochs until empty (or fail after 40 epochs).
    /// NOTE: time tracked in a local - never warp with block.timestamp in a loop.
    function drainQueue(uint256 id) internal {
        uint256 tstamp = block.timestamp;
        for (uint256 e = 0; e < 40; e++) {
            tstamp += 1 days;
            vm.warp(tstamp);
            _refreshFeeds();
            // raise liquidity if the vault is deployed in assets
            _tryForceRaise(id);
            try hub.settleQueue(id, 50) {} catch {}
            if (queueLen(id) == 0) return;
        }
        revert("queue never drained");
    }

    /// keep all feeds fresh after warps (prices unchanged)
    function _refreshFeeds() internal {
        usdgFeed.set(usdgFeed.answer());
        aaplFeed.set(aaplFeed.answer());
        tslaFeed.set(tslaFeed.answer());
        wethFeed.set(wethFeed.answer());
    }

    function _dueNeeded(uint256 id) internal view returns (uint256 needed) {
        RhTickerHub.Ticker memory t = hub.getTicker(id);
        if (t.queueHead >= t.queueTail) return 0;
        (, uint256 qty, uint64 settleAt) = hub.queue(id, t.queueHead);
        if (settleAt > block.timestamp) return 0;
        uint256 remaining = hub.gateRemaining(id);
        uint256 fill = qty < remaining ? qty : remaining;
        needed = fill * hub.nav(id) / 1e18;
    }

    function _tryForceRaise(uint256 id) internal {
        uint256 needed = _dueNeeded(id);
        if (needed == 0) return;
        address v = address(vaultOf(id));
        address[3] memory sellable = [address(aapl), address(tsla), address(weth)];
        for (uint256 i = 0; i < sellable.length; i++) {
            uint256 liquid = usdg.balanceOf(v);
            if (liquid >= needed) return;
            if (IERC20(sellable[i]).balanceOf(v) == 0) continue;
            _raiseSlice(id, sellable[i], v, needed - liquid);
        }
    }

    function _raiseSlice(uint256 id, address asset, address v, uint256 shortfall) internal {
        // size the sale to the shortfall (+2% cushion, inside the +5% allowance)
        uint256 want = registry.amountFromQuote(asset, shortfall * 102 / 100);
        uint256 bal = IERC20(asset).balanceOf(v);
        uint256 amt = want < bal ? want : bal;
        if (amt == 0) return;
        try hub.forceRaise(id, asset, amt, 500) {} catch {}
    }

    /// conservation: hub's USDG balance covers exactly the claims it tracks
    function assertConservation() internal view {
        uint256 claims = hub.protoFees();
        for (uint256 i = 0; i < hub.tickerCount(); i++) {
            claims += exitReserveOf(i) + creatorFeesOf(i);
        }
        assertEq(usdg.balanceOf(address(hub)), claims, "USDG conservation broken");
    }
}
