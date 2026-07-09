// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseSetup} from "./BaseSetup.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";

/// Port of the HyperEVM v0.1 mechanism battery to the Robinhood architecture:
/// every rule that survived the move (curve, splits, NAV floor both directions,
/// queue + epoch gate, seed lock, graduation, fees) - with NAV now moved by real
/// feed prices + trader swaps instead of the removed reportPnl oracle.
contract RhTickerHubTest is BaseSetup {
    // ---------- launch ----------

    function test_launch_basics() public {
        uint256 balBefore = usdg.balanceOf(trader);
        uint256 id = launchDefault();
        assertEq(usdg.balanceOf(trader), balBefore - 10_050e6, "debits seed + fee");
        RhTickerHub.Ticker memory t = hub.getTicker(id);
        assertGt(t.seedQty, 0);
        assertEq(tok(id).balanceOf(address(hub)), t.seedQty, "seed escrowed in hub");
        assertEq(t.seedUnlock, block.timestamp + hub.SEED_LOCK());
        // 80/20 split of net seed: 80% sits in the vault as USDG, 20% exit reserve
        uint256 net = 10_000e6 - 10_000e6 / 100;
        assertEq(usdg.balanceOf(address(t.vault)), net * 8000 / 10_000, "80% to vault");
        assertEq(t.exitReserve, net - net * 8000 / 10_000);
        assertEq(vaultValue(id), net * 8000 / 10_000, "NAV backing = vault USDG");
        assertConservation();
    }

    function test_launch_rejects_dupe_and_dust() public {
        launchDefault();
        vm.expectRevert(RhTickerHub.SymbolTaken.selector);
        hub.launch("Copy", "ALPHA", 1000e6);
        vm.expectRevert(RhTickerHub.SeedTooSmall.selector);
        hub.launch("Tiny", "TINY", 100e6);
    }

    function test_launcher_is_vault_trader() public {
        uint256 id = launchDefault();
        assertEq(vaultOf(id).trader(), trader, "creator must be the vault trader");
        assertEq(hub.getTicker(id).creator, trader);
    }

    // ---------- seed lock ----------

    function test_seed_locked_until_expiry() public {
        uint256 id = launchDefault();
        vm.prank(trader);
        vm.expectRevert(RhTickerHub.SeedLocked.selector);
        hub.claimSeed(id);
        vm.warp(block.timestamp + hub.SEED_LOCK() + 1);
        vm.prank(trader);
        hub.claimSeed(id);
        assertGt(tok(id).balanceOf(trader), 0);
    }

    function test_seed_claim_only_creator() public {
        uint256 id = launchDefault();
        vm.warp(block.timestamp + hub.SEED_LOCK() + 1);
        vm.prank(alice);
        vm.expectRevert(RhTickerHub.NotCreator.selector);
        hub.claimSeed(id);
    }

    // ---------- buy ----------

    function test_buy_splits_and_mints() public {
        uint256 id = launchDefault();
        uint256 v0 = usdg.balanceOf(address(vaultOf(id)));
        vm.prank(alice);
        uint256 out = hub.buy(id, 1000e6, 0);
        assertGt(out, 0);
        assertEq(tok(id).balanceOf(alice), out);
        uint256 net = 1000e6 - 1000e6 / 100;
        assertEq(usdg.balanceOf(address(vaultOf(id))), v0 + net * 8000 / 10_000, "80% to vault");
        assertConservation();
    }

    function test_buy_slippage_guard() public {
        uint256 id = launchDefault();
        (uint256 out,,) = hub.quoteBuy(id, 1000e6);
        vm.prank(alice);
        vm.expectRevert(RhTickerHub.Slippage.selector);
        hub.buy(id, 1000e6, out + 1);
    }

    // ---------- buy-side NAV floor ----------

    function test_below_nav_buy_routes_to_navMint() public {
        uint256 id = launchDefault();
        pumpNavAbovePrice(id);
        (,, bool navMint) = hub.quoteBuy(id, 5000e6);
        assertTrue(navMint);
    }

    function test_navMint_preserves_nav_exactly() public {
        uint256 id = launchDefault();
        pumpNavAbovePrice(id);
        uint256 navBefore = hub.nav(id);
        vm.prank(alice);
        hub.buy(id, 5000e6, 0);
        assertGe(hub.nav(id), navBefore, "NAV diluted by below-NAV buy");
        assertApproxEqRel(hub.nav(id), navBefore, 1e12, "NAV not preserved");
        assertConservation();
    }

    function test_discount_arb_cycle_is_negative_ev() public {
        uint256 id = launchDefault();
        pumpNavAbovePrice(id);
        uint256 cash0 = usdg.balanceOf(alice);
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 5000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, out);
        vm.stopPrank();
        drainQueue(id);
        assertLt(usdg.balanceOf(alice), cash0, "buy->redeem cycle must lose fees");
        assertConservation();
    }

    // ---------- sell routing ----------

    function test_sell_above_nav_executes_on_curve() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 2000e6, 0);
        (uint256 net,, bool floorRouted) = hub.quoteSell(id, out / 4);
        assertFalse(floorRouted, "small sell should clear the floor");
        (uint256 proceeds, bool queued) = hub.sell(id, out / 4, 0, false);
        vm.stopPrank();
        assertEq(proceeds, net);
        assertFalse(queued);
        assertGe(proceeds * 1e18 / (out / 4), hub.nav(id), "printed below NAV");
        assertConservation();
    }

    function test_below_nav_sell_queues_or_reverts() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 50_000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        (,, bool floorRouted) = hub.quoteSell(id, out);
        assertTrue(floorRouted);
        vm.expectRevert(RhTickerHub.WouldQueue.selector);
        hub.sell(id, out, 0, false);
        (, bool queued) = hub.sell(id, out, 0, true);
        assertTrue(queued);
        vm.stopPrank();
        assertConservation();
    }

    // ---------- redemption queue ----------

    function test_redemption_settles_at_nav_and_burns() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 1000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, out);
        vm.stopPrank();
        uint256 supply0 = tok(id).totalSupply();
        uint256 cash0 = usdg.balanceOf(alice);
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        hub.settleQueue(id, 10);
        assertLt(tok(id).totalSupply(), supply0, "supply burned");
        assertGt(usdg.balanceOf(alice), cash0, "paid at NAV");
        assertConservation();
    }

    function test_queue_not_settleable_before_delay() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 1000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, out);
        vm.stopPrank();
        vm.expectRevert(RhTickerHub.NothingToSettle.selector);
        hub.settleQueue(id, 10);
    }

    function test_bank_run_hits_epoch_gate() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 60_000e6, 0); // alice >> 20% of circ
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, out);
        vm.stopPrank();
        uint256 circ0 = hub.circ(id);
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        hub.settleQueue(id, 50);
        uint256 settled1 = circ0 - hub.circ(id);
        assertLe(settled1, circ0 * 2000 / 10_000, "first wave exceeded 20% gate");
        assertLt(settled1, out, "should have been partial");
        drainQueue(id);
        assertConservation();
    }

    // ---------- graduation ----------

    function test_graduation_needs_age_not_just_aum() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 400_000e6, 0);
        assertGt(vaultValue(id), hub.GRAD_VAULT());
        assertFalse(graduatedOf(id), "young ticker must not graduate");
        vm.warp(block.timestamp + hub.GRAD_AGE() + 1);
        _refreshFeeds();
        vm.prank(alice);
        hub.buy(id, 100e6, 0);
        assertTrue(graduatedOf(id), "aged ticker with AUM graduates");
    }

    function test_poke_graduates_on_vault_pnl() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 200_000e6, 0); // vault ~166k, below 250k
        assertLt(vaultValue(id), hub.GRAD_VAULT());
        traderAllIn(id, address(aapl));
        vm.warp(block.timestamp + hub.GRAD_AGE() + 1);
        aaplFeed.set(aaplFeed.answer() * 2); // trader doubles it
        usdgFeed.set(usdgFeed.answer());
        assertGt(vaultValue(id), hub.GRAD_VAULT());
        hub.poke(id);
        assertTrue(graduatedOf(id), "poke must graduate on vault PnL");
    }

    // ---------- fees ----------

    function test_creator_fees_claimable_only_by_creator() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 10_000e6, 0);
        assertGt(creatorFeesOf(id), 0);
        vm.prank(alice);
        vm.expectRevert(RhTickerHub.NotCreator.selector);
        hub.claimCreatorFees(id);
        uint256 cash0 = usdg.balanceOf(trader);
        vm.prank(trader);
        hub.claimCreatorFees(id);
        assertGt(usdg.balanceOf(trader), cash0);
        assertConservation();
    }

    function test_protocol_fees_only_treasury() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 10_000e6, 0);
        vm.expectRevert(RhTickerHub.NotTreasury.selector);
        hub.withdrawProtocolFees();
        vm.prank(treasury);
        uint256 amt = hub.withdrawProtocolFees();
        assertGt(amt, 0);
        assertEq(usdg.balanceOf(treasury), amt);
        assertConservation();
    }

    // ---------- trader PnL flows through to NAV ----------

    function test_nav_tracks_trader_pnl_live() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 40_000e6, 0);
        uint256 nav0 = hub.nav(id);
        traderAllIn(id, address(aapl));
        // swap at fair value: NAV unchanged (within slippage-free mock)
        assertApproxEqRel(hub.nav(id), nav0, 1e15, "fair swap moved NAV");
        // AAPL +50% -> NAV up ~proportionally to vault's AAPL share
        aaplFeed.set(aaplFeed.answer() * 3 / 2);
        assertGt(hub.nav(id), nav0 * 130 / 100, "NAV didn't track PnL up");
        // AAPL -80% from here
        aaplFeed.set(aaplFeed.answer() / 5);
        assertLt(hub.nav(id), nav0, "NAV didn't track PnL down");
        assertConservation();
    }

    // ---------- fuzz: random flows keep conservation + floor ----------

    function testFuzz_random_flows_conserve(uint256 seed) public {
        uint256 id = launchDefault();
        vm.prank(alice);
        tok(id).approve(address(hub), type(uint256).max);
        uint256 s = seed;
        uint256 tstamp = block.timestamp;
        for (uint256 i = 0; i < 25; i++) {
            s = uint256(keccak256(abi.encode(s)));
            uint256 action = s % 6;
            uint256 amt = (s >> 8) % 20_000e6 + 1e6;
            if (action == 0) {
                vm.prank(alice);
                hub.buy(id, amt, 0);
            } else if (action == 1) {
                uint256 bal = tok(id).balanceOf(alice);
                if (bal > 1e15) { vm.prank(alice); try hub.sell(id, bal / 3 + 1, 0, true) {} catch {} }
            } else if (action == 2) {
                uint256 bal = tok(id).balanceOf(alice);
                if (bal > 1e15) { vm.prank(alice); try hub.redeem(id, bal / 4 + 1) {} catch {} }
            } else if (action == 3) {
                tstamp += (s >> 16) % 2 days;
                vm.warp(tstamp);
                _refreshFeeds();
                _tryForceRaise(id);
                try hub.settleQueue(id, 5) {} catch {}
            } else if (action == 4) {
                // trader rotates a slice of the vault
                uint256 vbal = usdg.balanceOf(address(vaultOf(id)));
                if (vbal > 1e6) {
                    vm.prank(trader);
                    try vaultOf(id).swap(address(usdg), address(aapl), vbal / 2, 0, 500) {} catch {}
                }
            } else {
                // market moves ±30%
                int256 px = aaplFeed.answer();
                int256 shift = int256((s >> 24) % 60) - 30;
                aaplFeed.set(px + px * shift / 100);
            }
            assertConservation();
            uint256 c = hub.circ(id);
            if (c > 1e15) {
                (uint256 net,, bool routed) = hub.quoteSell(id, c / 100 + 1);
                if (!routed) assertGe(net * 1e18 / (c / 100 + 1), hub.nav(id) * 999 / 1000, "curve would print below NAV");
            }
        }
    }
}
