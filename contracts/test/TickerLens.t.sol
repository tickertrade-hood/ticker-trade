// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseSetup} from "./BaseSetup.sol";
import {TickerLens} from "../src/TickerLens.sol";

contract TickerLensTest is BaseSetup {
    TickerLens lens;

    function setUp() public override {
        super.setUp();
        lens = new TickerLens(hub);
    }

    function test_snap_matches_hub_reads() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 20_000e6, 0);
        TickerLens.Snap memory s = lens.snap(id);
        assertEq(s.id, id);
        assertEq(s.trader, trader);
        assertEq(s.symbol, "ALPHA");
        assertEq(s.price, hub.price(id));
        assertEq(s.nav, hub.nav(id));
        assertEq(s.vaultValue, vaultValue(id));
        assertEq(s.circ, hub.circ(id));
        assertTrue(s.mintFresh, "fresh feeds -> mintFresh");
        assertEq(s.vaultQuote, usdg.balanceOf(s.vault));
    }

    function test_premium_sign() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 5_000e6, 0);
        // fresh launch trades at a premium to floor (price > nav)
        TickerLens.Snap memory s = lens.snap(id);
        assertGt(s.premiumBps, 0, "should trade above floor at launch");
        // push into discount state -> premium negative
        pumpNavAbovePrice(id);
        s = lens.snap(id);
        assertLt(s.premiumBps, 0, "discount state -> negative premium");
    }

    function test_snapAll_and_range() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(trader);
            hub.launch(string(abi.encodePacked("T", vm.toString(i))), string(abi.encodePacked("T", vm.toString(i))), 1_000e6);
        }
        assertEq(lens.count(), 5);
        TickerLens.Snap[] memory all = lens.snapAll();
        assertEq(all.length, 5);
        TickerLens.Snap[] memory page = lens.snapRange(2, 2);
        assertEq(page.length, 2);
        assertEq(page[0].id, 2);
        assertEq(page[1].id, 3);
        // out-of-range start returns empty, not revert
        assertEq(lens.snapRange(99, 10).length, 0);
    }

    function test_snap_survives_stale_feed() public {
        uint256 id = launchDefault();
        traderAllIn(id, address(aapl));
        // let the AAPL feed go past the 96h NAV bound -> nav()/vaultValue revert
        vm.warp(block.timestamp + 100 hours);
        usdgFeed.set(usdgFeed.answer());
        TickerLens.Snap memory s = lens.snap(id);
        // the board still renders: price is feed-independent, nav/vaultValue 0
        assertGt(s.price, 0, "price still readable");
        assertEq(s.nav, 0, "stale nav swallowed to 0");
        assertEq(s.vaultValue, 0, "stale vaultValue swallowed to 0");
        assertFalse(s.mintFresh, "stale -> not mint fresh");
    }
}
