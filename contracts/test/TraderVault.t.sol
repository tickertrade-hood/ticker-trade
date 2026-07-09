// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseSetup} from "./BaseSetup.sol";
import {TraderVault} from "../src/TraderVault.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";

/// The vault IS the security model on Robinhood Chain (it replaces HyperCore's
/// "leader can trade, never withdraw"). These tests pin every edge of that ACL
/// plus the two quantitative bounds: oracle slippage and daily turnover.
contract TraderVaultTest is BaseSetup {
    uint256 id;
    TraderVault vault;

    function setUp() public override {
        super.setUp();
        id = launchDefault();
        vm.prank(alice);
        hub.buy(id, 100_000e6, 0); // vault now ~87k USDG
        vault = vaultOf(id);
    }

    // ---------- ACL ----------

    function test_only_trader_can_swap() public {
        vm.prank(attacker);
        vm.expectRevert(TraderVault.NotTrader.selector);
        vault.swap(address(usdg), address(aapl), 1000e6, 0, 500);
        vm.prank(alice);
        vm.expectRevert(TraderVault.NotTrader.selector);
        vault.swap(address(usdg), address(aapl), 1000e6, 0, 500);
    }

    function test_only_hub_can_payOut_and_forceSell() public {
        vm.prank(trader); // even the trader cannot withdraw
        vm.expectRevert(TraderVault.NotHub.selector);
        vault.payOut(1e6);
        vm.prank(attacker);
        vm.expectRevert(TraderVault.NotHub.selector);
        vault.payOut(1e6);
        vm.prank(trader);
        vm.expectRevert(TraderVault.NotHub.selector);
        vault.forceSell(address(aapl), 1e18, 500);
    }

    function test_swap_only_whitelisted_assets() public {
        vm.startPrank(trader);
        vm.expectRevert(TraderVault.SameToken.selector);
        vault.swap(address(usdg), address(usdg), 1000e6, 0, 500);
        vm.stopPrank();

        // an unlisted token can be neither leg
        address junk = address(new JunkToken());
        vm.startPrank(trader);
        vm.expectRevert(abi.encodeWithSelector(TraderVault.NotWhitelisted.selector, junk));
        vault.swap(address(usdg), junk, 1000e6, 0, 500);
        vm.expectRevert(abi.encodeWithSelector(TraderVault.NotWhitelisted.selector, junk));
        vault.swap(junk, address(usdg), 1000e6, 0, 500);
        vm.stopPrank();
    }

    function test_trader_cannot_swap_more_than_balance() public {
        // with the vault fully in quote, its whole balance == 100% of NAV == the
        // daily turnover cap, so swapping bal+1 trips the turnover guard first;
        // either way the trader cannot move value it doesn't hold.
        uint256 bal = usdg.balanceOf(address(vault));
        vm.prank(trader);
        vm.expectRevert(); // TurnoverExceeded or BadAmount
        vault.swap(address(usdg), address(aapl), bal + 1, 0, 500);
    }

    function test_swap_up_to_turnover_cap_then_balance_guard() public {
        // give the vault stock headroom so turnover isn't the binding constraint,
        // then prove the balance guard itself rejects an over-balance swap
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 40_000e6, 0, 500);
        uint256 shares = aapl.balanceOf(address(vault));
        vm.prank(trader);
        vm.expectRevert(TraderVault.BadAmount.selector);
        vault.swap(address(aapl), address(usdg), shares + 1e18, 0, 500);
    }

    // ---------- oracle slippage bound (the anti-drain wall) ----------

    function test_swap_at_fair_value_succeeds() public {
        vm.prank(trader);
        uint256 out = vault.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        // $10k at $200/share = 50 shares
        assertApproxEqRel(out, 50e18, 1e12);
        assertEq(vault.heldCount(), 1);
    }

    function test_swap_within_slippage_bound_succeeds() public {
        router.setExecBps(9925); // 0.75% worse than fair < 0.80% bound
        vm.prank(trader);
        uint256 out = vault.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        assertGt(out, 0);
    }

    function test_swap_beyond_slippage_bound_reverts() public {
        // hostile/manipulated pool fills 1.5% below fair -> the vault must refuse,
        // regardless of the trader passing minOut = 0
        router.setExecBps(9850);
        vm.prank(trader);
        vm.expectRevert("Too little received"); // router enforces our raised minOut
        vault.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
    }

    function test_forceSell_also_oracle_bounded() public {
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 50_000e6, 0, 500);
        router.setExecBps(9850);
        vm.prank(address(hub));
        vm.expectRevert("Too little received");
        vault.forceSell(address(aapl), 10e18, 500);
    }

    // ---------- daily turnover cap ----------

    function test_turnover_cap_binds_and_resets() public {
        uint256 nav0 = vault.totalValueInQuote();
        uint256 cap = nav0 * vault.TURNOVER_BPS() / 10_000; // 200% of NAV

        // a single full-portfolio de-risk (USDG->AAPL) is well within the cap
        vm.startPrank(trader);
        vault.swap(address(usdg), address(aapl), nav0, 0, 500);
        assertApproxEqRel(vault.turnoverUsed(), nav0, 1e15, "one rotation charged ~NAV");

        // ...and an immediate re-risk (AAPL->USDG) also fits (2x rotation == cap):
        // this is the honest same-day rotation the 200% cap is meant to allow (R-B)
        uint256 shares = aapl.balanceOf(address(vault));
        vault.swap(address(aapl), address(usdg), shares, 0, 500);
        assertLe(vault.turnoverUsed(), cap, "two rotations within 200% cap");

        // a third rotation now exceeds the daily budget and must revert
        uint256 bal = usdg.balanceOf(address(vault));
        vm.expectRevert();
        vault.swap(address(usdg), address(aapl), bal, 0, 500);
        vm.stopPrank();

        // next day the counter resets
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        assertEq(vault.turnoverUsed(), 10_000e6);
    }

    // ---------- NAV valuation ----------

    function test_totalValue_includes_stock_at_feed_price() public {
        uint256 v0 = vault.totalValueInQuote();
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 20_000e6, 0, 500);
        assertApproxEqRel(vault.totalValueInQuote(), v0, 1e12, "fair swap changed value");
        aaplFeed.set(400e8); // AAPL doubles
        uint256 gain = 20_000e6; // the AAPL sleeve doubled
        assertApproxEqRel(vault.totalValueInQuote(), v0 + gain, 1e12, "value didn't track feed");
    }

    function test_uiMultiplier_split_does_not_change_value() public {
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 20_000e6, 0, 500);
        uint256 v0 = vault.totalValueInQuote();
        // 10:1 stock split: raw balances unchanged, multiplier 10x, price /10
        aapl.setUiMultiplier(10e18);
        aaplFeed.set(20e8);
        assertApproxEqRel(vault.totalValueInQuote(), v0, 1e12, "split repriced the vault");
    }

    function test_usdg_depeg_reprices_stock_sleeve() public {
        vm.prank(trader);
        vault.swap(address(usdg), address(aapl), 20_000e6, 0, 500);
        uint256 v0 = vault.totalValueInQuote();
        // USDG depegs to $0.95 -> each stock $ buys MORE USDG units
        usdgFeed.set(95e6); // 0.95e8
        assertGt(vault.totalValueInQuote(), v0, "depeg must raise quote-denominated stock value");
    }

    // ---------- held-asset enumeration ----------

    function test_held_tracking_add_remove() public {
        vm.startPrank(trader);
        vault.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        vault.swap(address(usdg), address(tsla), 10_000e6, 0, 500);
        assertEq(vault.heldCount(), 2);
        uint256 shares = aapl.balanceOf(address(vault));
        vault.swap(address(aapl), address(usdg), shares, 0, 500);
        assertEq(vault.heldCount(), 1, "empty asset must untrack");
        vm.stopPrank();
    }

    function test_syncHeld_counts_donations() public {
        uint256 v0 = vault.totalValueInQuote();
        aapl.mint(address(vault), 100e18); // $20k gift
        assertEq(vault.totalValueInQuote(), v0, "untracked donation shouldn't count yet");
        // syncHeld is trader/hub-only now (AUDIT S-2): attacker can't force it
        vm.prank(attacker);
        vm.expectRevert(TraderVault.NotTrader.selector);
        vault.syncHeld(address(aapl));
        vm.prank(trader);
        vault.syncHeld(address(aapl));
        assertApproxEqRel(vault.totalValueInQuote(), v0 + 20_000e6, 1e12, "donation must raise NAV");
        // donations can only ever help holders: NAV floor went UP
    }

    function test_syncHeld_rejects_unlisted() public {
        address junk = address(new JunkToken());
        vm.prank(trader);
        vm.expectRevert();
        vault.syncHeld(junk);
    }
}

contract JunkToken {
    function decimals() external pure returns (uint8) { return 18; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
}
