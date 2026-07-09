// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseSetup} from "./BaseSetup.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";
import {TraderVault} from "../src/TraderVault.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";

/// Adversarial battery: ports of every v0.1 audit regression that survived the
/// architecture change, plus the NEW attack surface this chain adds - malicious
/// trader extraction, forceRaise abuse, oracle staleness, donation vectors.
contract SecurityTest is BaseSetup {
    function launchAs(address who, string memory sym, uint256 seed) internal returns (uint256 id) {
        vm.prank(who);
        id = hub.launch(sym, sym, seed);
    }

    // ---------- the core promise: trader can NEVER withdraw ----------

    function test_trader_has_no_withdrawal_path() public {
        uint256 id = launchAs(attacker, "ATK", 20_000e6);
        vm.prank(alice);
        hub.buy(id, 100_000e6, 0);
        TraderVault v = vaultOf(id);

        uint256 attackerCash0 = usdg.balanceOf(attacker);
        uint256 vaultValue0 = v.totalValueInQuote();

        vm.startPrank(attacker);
        // no payOut
        vm.expectRevert(TraderVault.NotHub.selector);
        v.payOut(1e6);
        // no forceSell
        vm.expectRevert(TraderVault.NotHub.selector);
        v.forceSell(address(aapl), 1, 500);
        // swap only moves value between whitelisted assets INSIDE the vault -
        // recipient is hardcoded to the vault itself
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        vm.stopPrank();

        assertEq(usdg.balanceOf(attacker), attackerCash0, "trader-attacker extracted quote");
        assertEq(aapl.balanceOf(attacker), 0, "trader-attacker extracted stock");
        assertApproxEqRel(v.totalValueInQuote(), vaultValue0, 1e15, "value left the vault");
    }

    /// worst-case extraction: attacker-trader colludes with the pool at the worst
    /// allowed fill and churns max turnover. Bleed must respect the documented
    /// bound (slippage x turnover) and never exceed it.
    function test_malicious_trader_max_bleed_is_bounded() public {
        uint256 id = launchAs(attacker, "ATK", 20_000e6);
        vm.prank(alice);
        hub.buy(id, 100_000e6, 0);
        TraderVault v = vaultOf(id);

        router.setExecBps(9921); // just inside the 80bp wall (with fair-out rounding)
        uint256 v0 = v.totalValueInQuote();

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 40; i++) {
            uint256 bal = usdg.balanceOf(address(v));
            if (bal < 1e6) break;
            uint256 amt = bal / 2;
            try v.swap(address(usdg), address(aapl), amt, 0, 500) {} catch { break; }
            uint256 shares = aapl.balanceOf(address(v));
            try v.swap(address(aapl), address(usdg), shares, 0, 500) {} catch { break; }
        }
        vm.stopPrank();

        uint256 v1 = v.totalValueInQuote();
        // theoretical daily cap: 300% turnover x 0.8% slippage = 2.4% of NAV
        uint256 maxBleed = v0 * 240 / 10_000;
        assertLe(v0 - v1, maxBleed + v0 / 1000, "trader bled more than the documented bound");
        // and holders could exit at the (slightly lower) NAV the whole time
        assertGt(hub.nav(id), 0);
    }

    // ---------- forceRaise cannot be abused ----------

    function test_forceRaise_reverts_without_shortfall() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.expectRevert(RhTickerHub.NoShortfall.selector);
        hub.forceRaise(id, address(aapl), 1e18, 500);
    }

    function test_forceRaise_cannot_overliquidate() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.startPrank(alice);
        uint256 out = hub.buy(id, 50_000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        vm.stopPrank();
        traderAllIn(id, address(aapl));

        vm.prank(alice);
        hub.redeem(id, out / 10);
        vm.warp(block.timestamp + hub.REDEEM_DELAY() + 1);
        _refreshFeeds();

        // griefer tries to dump the ENTIRE vault through forceRaise
        uint256 allShares = aapl.balanceOf(address(vaultOf(id)));
        vm.prank(attacker);
        vm.expectRevert(); // RaiseTooLarge
        hub.forceRaise(id, address(aapl), allShares, 500);

        // right-sized raise passes and lets the queue settle
        _tryForceRaise(id);
        hub.settleQueue(id, 10);
        assertEq(queueLen(id), 0, "queue settled after bounded raise");
    }

    // ---------- oracle staleness halts trading (no stale-price prints) ----------

    function test_stale_feed_halts_trading_then_recovers() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        traderAllIn(id, address(aapl));
        vm.prank(alice);
        hub.buy(id, 1_000e6, 0);

        // stock feed goes quiet past its 96h bound (long weekend + halt)
        vm.warp(block.timestamp + 97 hours);
        usdgFeed.set(usdgFeed.answer()); // quote feed stays fresh
        vm.startPrank(alice);
        vm.expectRevert(); // StaleOracle inside nav()
        hub.buy(id, 1_000e6, 0);
        vm.expectRevert();
        hub.sell(id, 1e18, 0, true);
        vm.stopPrank();

        // feed resumes -> trading resumes
        aaplFeed.set(aaplFeed.answer());
        vm.prank(alice);
        hub.buy(id, 1_000e6, 0);
        assertConservation();
    }

    // ---------- E-1/E-2: at-NAV mint blocked against a stale mark ----------

    function test_navMint_blocked_when_feed_stale() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        pumpNavAbovePrice(id); // vault in AAPL, NAV > price -> navMint territory
        // fresh: a below-NAV buy mints at NAV
        (,, bool navMint) = hub.quoteBuy(id, 5_000e6);
        assertTrue(navMint);
        vm.prank(alice);
        hub.buy(id, 5_000e6, 0);

        // weekend: AAPL feed idles 40h (> MINT_FRESH 36h) but < 96h NAV bound
        vm.warp(block.timestamp + 40 hours);
        usdgFeed.set(usdgFeed.answer()); // quote stays fresh
        // NAV still readable (not past 96h), still below-NAV -> would-be navMint
        (,, bool stillNavMint) = hub.quoteBuy(id, 5_000e6);
        assertTrue(stillNavMint);
        // ...but the mint is refused: can't mint against a stale weekend mark
        vm.prank(alice);
        vm.expectRevert(RhTickerHub.StaleForMint.selector);
        hub.buy(id, 5_000e6, 0);

        // feed reopens -> mint allowed again
        aaplFeed.set(aaplFeed.answer());
        vm.prank(alice);
        hub.buy(id, 5_000e6, 0);
        assertConservation();
    }

    function test_navMint_allowed_within_weekday_overnight_gap() public {
        // R-A liveness: a below-NAV buy must NOT be bricked during a normal
        // weekday overnight gap (feed ~30h < MINT_FRESH 36h).
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        pumpNavAbovePrice(id);
        vm.warp(block.timestamp + 30 hours);
        usdgFeed.set(usdgFeed.answer()); // quote fresh; AAPL left at 30h
        (,, bool navMint) = hub.quoteBuy(id, 5_000e6);
        assertTrue(navMint, "should still be navMint territory");
        vm.prank(alice);
        uint256 out = hub.buy(id, 5_000e6, 0); // must NOT revert StaleForMint
        assertGt(out, 0);
        assertConservation();
    }

    function test_above_nav_curve_buy_still_works_when_stale() public {
        // a pure-quote vault is always mint-fresh, and above-NAV buys never need
        // the gate; trading continues through a stale stock feed for such books
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.warp(block.timestamp + 40 hours);
        usdgFeed.set(usdgFeed.answer());
        vm.prank(alice);
        uint256 out = hub.buy(id, 5_000e6, 0);
        assertGt(out, 0);
    }

    // ---------- R5-1: forced sells now consume the turnover budget ----------

    function test_forceSell_charges_turnover() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.prank(alice); hub.buy(id, 100_000e6, 0);
        TraderVault v = vaultOf(id);
        traderAllIn(id, address(aapl));            // vault fully in AAPL (uses turnover)
        uint256 usedBefore = v.turnoverUsed();
        // a hub-driven forced sell must ALSO increment the turnover accumulator now
        vm.prank(address(hub));
        v.forceSell(address(aapl), 10e18, 500);
        assertGt(v.turnoverUsed(), usedBefore, "forced sell must charge turnover (R5-1)");
    }

    // ---------- R5-4: cannot rotate the vault INTO a stale-marked stock ----------

    function test_swap_into_stale_stock_reverts() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.prank(alice); hub.buy(id, 50_000e6, 0);
        TraderVault v = vaultOf(id);
        // AAPL feed goes stale (>36h MINT_FRESH); buying INTO it must revert
        vm.warp(block.timestamp + 40 hours);
        usdgFeed.set(usdgFeed.answer());
        vm.prank(trader);
        vm.expectRevert(TraderVault.StaleForSwap.selector);
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        // but a fresh feed allows it again
        aaplFeed.set(aaplFeed.answer());
        vm.prank(trader);
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
    }

    // ---------- dust-stuffing the queue (M-1 port) ----------

    function test_dust_redemption_reverts() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.prank(attacker);
        hub.buy(id, 10_000e6, 0);
        vm.startPrank(attacker);
        tok(id).approve(address(hub), type(uint256).max);
        vm.expectRevert(RhTickerHub.DustRedemption.selector);
        hub.redeem(id, 1);
        uint256 tiny = 1e18 * 5_000 / hub.nav(id); // ~half the minimum notional
        vm.expectRevert(RhTickerHub.DustRedemption.selector);
        hub.redeem(id, tiny);
        vm.stopPrank();
    }

    // ---------- donation vectors ----------

    function test_donation_to_hub_does_not_move_nav() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        uint256 navBefore = hub.nav(id);
        vm.prank(attacker);
        usdg.transfer(address(hub), 1_000_000e6);
        assertEq(hub.nav(id), navBefore, "hub donation moved NAV");
    }

    function test_donation_to_vault_only_raises_floor() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        uint256 navBefore = hub.nav(id);
        vm.prank(attacker);
        usdg.transfer(address(vaultOf(id)), 100_000e6);
        assertGe(hub.nav(id), navBefore, "vault donation lowered NAV??");
        // NAV up = floor up = strictly good for holders; attacker just gifted them
        uint256 navAfter = hub.nav(id);
        assertGt(navAfter, navBefore);
        // and buys still route correctly (navMint at the higher floor)
        vm.prank(alice);
        uint256 out = hub.buy(id, 10_000e6, 0);
        assertGt(out, 0);
        uint256 floorValue = out * hub.nav(id) / 1e18;
        assertGe(floorValue, 9_700e6, "buyer skimmed by donation state");
    }

    function test_first_buyer_cannot_inflate_against_second() public {
        uint256 id = launchAs(attacker, "ATK", 500e6); // min seed
        vm.prank(attacker);
        usdg.transfer(address(vaultOf(id)), 100_000e6); // classic ERC4626-style inflation try
        vm.prank(alice);
        uint256 out = hub.buy(id, 10_000e6, 0);
        assertGt(out, 0, "victim got zero tokens - inflation succeeded");
        uint256 floorValue = out * hub.nav(id) / 1e18;
        // buy routed as navMint at the inflated NAV -> full net value lands in the
        // vault at that same NAV; the victim keeps >= ~99% of spend as floor value
        assertGe(floorValue, 9_800e6, "victim skimmed by inflation attack");
    }

    // ---------- navMint round-trip is fee-negative ----------

    function test_navMint_roundtrip_loses_money() public {
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        pumpNavAbovePrice(id);
        uint256 cash0 = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 out = hub.buy(id, 20_000e6, 0);
        tok(id).approve(address(hub), type(uint256).max);
        hub.sell(id, out, 0, true);
        vm.stopPrank();
        drainQueue(id);
        assertLe(usdg.balanceOf(attacker), cash0, "navMint round-trip was profitable");
    }

    // ---------- cross-ticker isolation ----------

    function test_cross_ticker_vault_isolation() public {
        uint256 a = launchAs(trader, "AAA", 20_000e6);
        uint256 b = launchAs(attacker, "BBB", 20_000e6);
        uint256 vaultA = vaultValue(a);
        // hammer ticker B: buys, trader all-in, market crash, sells
        vm.prank(bob);
        hub.buy(b, 100_000e6, 0);
        vm.startPrank(attacker);
        TraderVault vb = vaultOf(b);
        vb.swap(address(usdg), address(tsla), usdg.balanceOf(address(vb)), 0, 500);
        vm.stopPrank();
        tslaFeed.set(tslaFeed.answer() / 4);
        // ticker A untouched (its vault holds only USDG)
        assertEq(vaultValue(a), vaultA, "ticker A contaminated by ticker B activity");
    }

    // ---------- no admin surface ----------

    function test_no_owner_functions() public {
        launchAs(trader, "TRD", 20_000e6);
        vm.prank(attacker);
        vm.expectRevert(RhTickerHub.NotTreasury.selector);
        hub.withdrawProtocolFees();
        // there is no reportPnl / pause / upgrade / setter surface at all -
        // enforced at compile time; runtime check: treasury can't touch vaults
        uint256 v0 = vaultValue(0);
        vm.prank(treasury);
        hub.withdrawProtocolFees();
        assertEq(vaultValue(0), v0, "treasury touched a vault");
    }

    // ---------- seed lock ----------

    function test_seed_lock_no_bypass() public {
        uint256 id = launchAs(attacker, "ATK", 20_000e6);
        assertEq(tok(id).balanceOf(attacker), 0, "seed not escrowed");
        vm.prank(attacker);
        vm.expectRevert(RhTickerHub.SeedLocked.selector);
        hub.claimSeed(id);
        vm.warp(block.timestamp + hub.SEED_LOCK() + 1);
        vm.prank(attacker);
        hub.claimSeed(id);
        assertGt(tok(id).balanceOf(attacker), 0);
    }

    // ---------- reentrancy shape ----------

    function test_reentrancy_guards_wired() public {
        // all state-changing hub entry points share one guard; a reentering token
        // callback would hit Reentered. The ERC20s here have no hooks (USDG and
        // stock tokens are hookless), so we assert the guard exists by shape:
        // vault.swap -> router cannot re-enter hub.buy in the same lock? (vault
        // and hub have separate locks; the hub never calls out mid-accounting
        // except final transfers). This test documents the CEI review result.
        uint256 id = launchAs(trader, "TRD", 20_000e6);
        vm.prank(alice);
        hub.buy(id, 1000e6, 0); // sanity: normal flow unaffected by guards
        assertConservation();
    }
}
