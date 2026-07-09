// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseSetup} from "./BaseSetup.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";
import {TraderVault} from "../src/TraderVault.sol";

/// Full-lifecycle scenario simulations - the "what actually happens when it all
/// goes wrong" battery: crashes, bank runs, oracle outages, depegs, splits,
/// issuer confiscation, liquidity starvation, mass launches.
contract ScenariosTest is BaseSetup {
    // ---------- scenario: -90% crash + full bank run ----------

    function test_scenario_crash90_bank_run_pays_prorata_nav() public {
        uint256 id = launchDefault();
        // three holders pile in
        vm.prank(alice); uint256 outA = hub.buy(id, 50_000e6, 0);
        vm.prank(bob); uint256 outB = hub.buy(id, 30_000e6, 0);
        // trader goes all-in AAPL at the top
        traderAllIn(id, address(aapl));
        // AAPL -90%
        aaplFeed.set(aaplFeed.answer() / 10);
        uint256 navCrash = hub.nav(id);
        assertGt(navCrash, 0);

        // everyone runs for the exit
        vm.startPrank(alice);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, outA);
        vm.stopPrank();
        vm.startPrank(bob);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, outB);
        vm.stopPrank();

        uint256 cashA0 = usdg.balanceOf(alice);
        uint256 cashB0 = usdg.balanceOf(bob);
        drainQueue(id); // cranks forceRaise + settle across epochs

        uint256 paidA = usdg.balanceOf(alice) - cashA0;
        uint256 paidB = usdg.balanceOf(bob) - cashB0;
        assertGt(paidA, 0, "alice never paid");
        assertGt(paidB, 0, "bob never paid");
        // both were paid in the same crashed-NAV regime; ratio tracks position size
        assertApproxEqRel(paidA * 1e18 / paidB, uint256(outA) * 1e18 / outB, 5e16, "not pro-rata");
        // nobody printed above the crash NAV by more than the settle-time drift
        assertLe(paidA, outA * navCrash / 1e18 * 12 / 10, "alice overpaid vs crash NAV");
        assertConservation();
    }

    // ---------- scenario: weekend oracle silence ----------

    function test_scenario_weekend_stale_then_monday_reopen() public {
        uint256 id = launchDefault();
        traderAllIn(id, address(aapl));
        vm.prank(alice);
        hub.buy(id, 5_000e6, 0);

        // Friday close -> Monday+ : stock feed silent 97h (beyond the 96h bound)
        uint256 tstamp = block.timestamp + 97 hours;
        vm.warp(tstamp);
        usdgFeed.set(usdgFeed.answer()); // stablecoin feed keeps beating

        // trading is halted, not corrupted
        vm.prank(alice);
        vm.expectRevert();
        hub.buy(id, 1_000e6, 0);

        // Monday reopen: feed beats again, NAV gaps down 4% - first trade prices it
        aaplFeed.set(aaplFeed.answer() * 96 / 100);
        vm.prank(alice);
        uint256 out = hub.buy(id, 1_000e6, 0);
        assertGt(out, 0, "reopen trade failed");
        assertConservation();
    }

    // ---------- scenario: malicious trader + colluding pool, multi-day grind ----------

    function test_scenario_slow_rug_visible_and_bounded_over_week() public {
        vm.prank(attacker);
        uint256 id = hub.launch("Rug", "RUG", 20_000e6);
        vm.prank(alice);
        hub.buy(id, 100_000e6, 0);
        TraderVault v = vaultOf(id);
        router.setExecBps(9921); // worst fill inside the wall

        uint256 v0 = v.totalValueInQuote();
        uint256 tstamp = block.timestamp;
        for (uint256 day = 0; day < 7; day++) {
            vm.startPrank(attacker);
            for (uint256 i = 0; i < 10; i++) {
                uint256 bal = usdg.balanceOf(address(v));
                if (bal < 1e6) break;
                try v.swap(address(usdg), address(aapl), bal / 2, 0, 500) {} catch { break; }
                uint256 sh = aapl.balanceOf(address(v));
                try v.swap(address(aapl), address(usdg), sh, 0, 500) {} catch { break; }
            }
            vm.stopPrank();
            tstamp += 1 days;
            vm.warp(tstamp);
            _refreshFeeds();
        }
        uint256 v1 = v.totalValueInQuote();
        // 7 days x 2.4%/day compounding floor ~ 15.6% max theoretical bleed
        assertGe(v1, v0 * 84 / 100, "bleed exceeded documented worst case");
        // holders could exit at NAV the whole time - alice redeems now and gets
        // her pro-rata share of what remains
        vm.startPrank(alice);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, tok(id).balanceOf(alice));
        vm.stopPrank();
        drainQueue(id);
        assertConservation();
    }

    // ---------- scenario: liquidity starvation -> permissionless rescue ----------

    function test_scenario_fully_deployed_vault_redemption_rescue() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 20_000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        vm.stopPrank();
        traderAllIn(id, address(aapl)); // 0 USDG left in vault

        vm.prank(alice);
        hub.redeem(id, out / 2);
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        _refreshFeeds();

        // settle finds zero quote liquidity -> reverts NothingToSettle
        vm.expectRevert(RhTickerHub.NothingToSettle.selector);
        hub.settleQueue(id, 10);

        // ANY address (bob, unaffiliated) cranks the rescue
        RhTickerHub.Ticker memory t = hub.getTicker(id);
        (, uint256 qty,) = hub.queue(id, t.queueHead);
        uint256 remaining = hub.gateRemaining(id);
        uint256 fill = qty < remaining ? qty : remaining;
        uint256 needed = fill * hub.nav(id) / 1e18;
        uint256 amt = registry.amountFromQuote(address(aapl), needed * 102 / 100);
        vm.prank(bob);
        hub.forceRaise(id, address(aapl), amt, 500);
        uint256 cash0 = usdg.balanceOf(alice);
        hub.settleQueue(id, 10);
        assertGt(usdg.balanceOf(alice), cash0, "redeemer rescued");
        assertConservation();
    }

    // ---------- scenario: 10:1 stock split over a weekend ----------

    function test_scenario_stock_split_nav_continuous() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 20_000e6, 0);
        traderAllIn(id, address(aapl));
        uint256 nav0 = hub.nav(id);

        // issuer executes a 10:1 split: multiplier x10, feed reprices /10
        aapl.setUiMultiplier(10e18);
        aaplFeed.set(aaplFeed.answer() / 10);

        assertApproxEqRel(hub.nav(id), nav0, 1e12, "split broke NAV continuity");
        // trading unaffected
        vm.prank(alice);
        hub.buy(id, 1_000e6, 0);
        assertConservation();
    }

    // ---------- scenario: USDG depeg ----------

    function test_scenario_usdg_depeg_stock_holders_protected() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 20_000e6, 0);
        traderAllIn(id, address(aapl));
        uint256 nav0 = hub.nav(id);

        // USDG -5% depeg: stock sleeve is now worth MORE quote units
        usdgFeed.set(95e6);
        assertGt(hub.nav(id), nav0, "depeg must raise stock-backed NAV in quote units");

        // redemption pays more USDG per token (same real value) - no revert, no skim
        vm.startPrank(alice);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, tok(id).balanceOf(alice) / 4);
        vm.stopPrank();
        drainQueue(id);
        assertConservation();
    }

    // ---------- scenario: issuer confiscates the stock (adminBurn) ----------

    function test_scenario_issuer_adminBurn_nav_reprices_no_lockup() public {
        uint256 id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 20_000e6, 0);
        traderAllIn(id, address(aapl));
        uint256 nav0 = hub.nav(id);

        // Robinhood's ADMIN_BURNER_ROLE torches half the vault's shares
        aapl.adminBurn(address(vaultOf(id)), aapl.balanceOf(address(vaultOf(id))) / 2);

        uint256 nav1 = hub.nav(id);
        assertLt(nav1, nav0, "NAV must reflect confiscation immediately");
        assertGt(nav1, nav0 * 45 / 100, "NAV fell more than the confiscated share");
        // holders can still exit at the new NAV
        vm.startPrank(alice);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, tok(id).balanceOf(alice));
        vm.stopPrank();
        drainQueue(id);
        assertConservation();
    }

    // ---------- scenario: stock paused by issuer ----------

    function test_scenario_stock_pause_blocks_swaps_not_valuation() public {
        uint256 id = launchDefault();
        traderAllIn(id, address(aapl));
        aapl.setPaused(true);

        // NAV still reads (balanceOf is view) - buys/sells on the CURVE still work
        uint256 n = hub.nav(id);
        assertGt(n, 0, "pause must not kill valuation");
        vm.prank(alice);
        hub.buy(id, 1_000e6, 0);

        // but the trader can't move the position, and forceRaise fails until unpause
        TraderVault v = vaultOf(id); // hoist: helper makes external calls
        vm.prank(trader);
        vm.expectRevert();
        v.swap(address(aapl), address(usdg), 1e18, 0, 500);
        aapl.setPaused(false);
        assertConservation();
    }

    // ---------- scenario: mass launch day ----------

    function test_scenario_twenty_launches_isolated_books() public {
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            address who = i % 2 == 0 ? trader : bob;
            vm.prank(who);
            ids[i] = hub.launch(
                string(abi.encodePacked("Trader ", vm.toString(i))),
                string(abi.encodePacked("T", vm.toString(i))),
                1_000e6
            );
        }
        assertEq(hub.tickerCount(), 20);
        // hammer one ticker, verify a random other book is untouched
        vm.prank(alice);
        hub.buy(ids[7], 200_000e6, 0);
        TraderVault v7 = vaultOf(ids[7]);
        RhTickerHub.Ticker memory t7 = hub.getTicker(ids[7]); // creator = bob (odd index)
        uint256 v7bal = usdg.balanceOf(address(v7)); // hoist: args must not eat the prank
        vm.prank(t7.creator);
        v7.swap(address(usdg), address(tsla), v7bal, 0, 500);
        tslaFeed.set(tslaFeed.answer() / 3);

        uint256 v12 = vaultValue(ids[12]);
        assertEq(v12, usdg.balanceOf(address(vaultOf(ids[12]))), "ticker 12 vault is pure USDG");
        (uint256 outQ,,) = hub.quoteBuy(ids[12], 1_000e6);
        assertGt(outQ, 0, "other books unaffected");
        assertConservation();
    }

    // ---------- scenario: total wipe (NAV -> ~0) doesn't brick the book ----------

    function test_scenario_total_wipe_burns_settle_cleanly() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 10_000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        hub.redeem(id, out); // queue BEFORE the wipe (dust check passes at live NAV)
        vm.stopPrank();

        traderAllIn(id, address(aapl));
        aaplFeed.set(1); // AAPL -> $0.00000001 (vault ~wiped)
        // exit reserve still holds the 20% sleeve; NAV is ~0 but > 0
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        usdgFeed.set(usdgFeed.answer());

        // settle burns the queued tokens; payment is bounded by remaining value.
        // NAV ~ 0 -> fills are epoch-gated at 20% of circ, so the burn-down takes
        // several epochs, exactly like a healthy-book bank run.
        hub.settleQueue(id, 10);
        drainQueue(id);
        assertEq(queueLen(id), 0, "wiped book still settles/burns");
        assertConservation();
    }
}
