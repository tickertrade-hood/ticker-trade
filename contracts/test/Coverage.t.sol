// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseSetup} from "./BaseSetup.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {TraderVault} from "../src/TraderVault.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";
import {TickerToken} from "../src/TickerToken.sol";
import {TickerLens} from "../src/TickerLens.sol";
import {SafeTransfer} from "../src/SafeTransfer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ISpotVenue} from "../src/interfaces/ISpotVenue.sol";
import {MockERC20, MockStock, MockFeed, MockSpotVenue, LyingVenue, BadERC20} from "./mocks/Mocks.sol";

/// Closes the coverage gaps flagged by the audit: AssetRegistry guards/oracle
/// (the pricing trust root, was 29% branch), SafeTransfer failure paths,
/// TickerToken onlyHub, the vault's own slippage self-check vs a lying router,
/// dust guards, zero-amount reverts, syncHeld untrack, Lens empty-window, and the
/// new rolling-turnover decay behavior.
contract CoverageTest is BaseSetup {
    // ---------- AssetRegistry constructor guards ----------

    function _feeds(uint256 n) internal returns (address[] memory a, IAggregatorV3[] memory f, uint48[] memory s, bool[] memory m) {
        a = new address[](n); f = new IAggregatorV3[](n); s = new uint48[](n); m = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(new MockStock("X", "X"));
            f[i] = IAggregatorV3(address(new MockFeed(8, 100e8)));
            s[i] = 96 hours; m[i] = true;
        }
    }

    function test_registry_lengthMismatch() public {
        (address[] memory a, IAggregatorV3[] memory f, uint48[] memory s,) = _feeds(2);
        bool[] memory badM = new bool[](1);
        vm.expectRevert(AssetRegistry.LengthMismatch.selector);
        new AssetRegistry(IERC20(address(usdg)), IAggregatorV3(address(usdgFeed)), 26 hours, a, f, s, badM);
    }

    function test_registry_zeroQuote() public {
        (address[] memory a, IAggregatorV3[] memory f, uint48[] memory s, bool[] memory m) = _feeds(1);
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        new AssetRegistry(IERC20(address(0)), IAggregatorV3(address(usdgFeed)), 26 hours, a, f, s, m);
    }

    function test_registry_duplicateAsset() public {
        (address[] memory a, IAggregatorV3[] memory f, uint48[] memory s, bool[] memory m) = _feeds(2);
        a[1] = a[0]; // duplicate
        vm.expectRevert(AssetRegistry.DuplicateAsset.selector);
        new AssetRegistry(IERC20(address(usdg)), IAggregatorV3(address(usdgFeed)), 26 hours, a, f, s, m);
    }

    function test_registry_assetEqualsQuote() public {
        (address[] memory a, IAggregatorV3[] memory f, uint48[] memory s, bool[] memory m) = _feeds(1);
        a[0] = address(usdg);
        vm.expectRevert(AssetRegistry.DuplicateAsset.selector);
        new AssetRegistry(IERC20(address(usdg)), IAggregatorV3(address(usdgFeed)), 26 hours, a, f, s, m);
    }

    // ---------- AssetRegistry oracle validation ----------

    function test_registry_badOracleAnswer() public {
        aaplFeed.set(0); // answer <= 0, but fresh updatedAt -> BadOracleAnswer first
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.BadOracleAnswer.selector, address(aaplFeed)));
        registry.valueInQuote(address(aapl), 1e18);
    }

    function test_registry_staleOracle() public {
        vm.warp(block.timestamp + 100 hours);
        usdgFeed.set(usdgFeed.answer()); // quote fresh, aapl stale
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.StaleOracle.selector, address(aaplFeed), aaplFeed.updatedAt()));
        registry.valueInQuote(address(aapl), 1e18);
    }

    function test_registry_notListed() public {
        address junk = address(new MockStock("J", "J"));
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotListed.selector, junk));
        registry.valueInQuote(junk, 1e18);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotListed.selector, junk));
        registry.amountFromQuote(junk, 1e6);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotListed.selector, junk));
        registry.assetPriceUsd(junk);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotListed.selector, junk));
        registry.assetUpdatedAt(junk);
    }

    function test_registry_zeroAmount_returnsZero() public view {
        assertEq(registry.valueInQuote(address(aapl), 0), 0);
        assertEq(registry.amountFromQuote(address(aapl), 0), 0);
        assertEq(registry.valueInQuote(address(usdg), 0), 0);
    }

    function test_registry_getters() public view {
        (uint256 pxA, uint8 dA) = registry.assetPriceUsd(address(aapl));
        assertEq(pxA, 200e8); assertEq(dA, 8);
        (uint256 pxQ, uint8 dQ) = registry.quotePriceUsd();
        assertEq(pxQ, 1e8); assertEq(dQ, 8);
        assertGt(registry.quoteUpdatedAt(), 0);
    }

    // ---------- SafeTransfer failure paths ----------

    function test_safeTransfer_failureReverts() public {
        SafeHarness h = new SafeHarness();
        address bad = address(new BadERC20());
        vm.expectRevert(abi.encodeWithSelector(SafeTransfer.TransferFailed.selector, bad));
        h.doTransfer(bad, address(1), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeTransfer.TransferFailed.selector, bad));
        h.doTransferFrom(bad, address(1), address(2), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeTransfer.ApproveFailed.selector, bad));
        h.doApprove(bad, address(1), 1);
    }

    // ---------- TickerToken onlyHub ----------

    function test_tickerToken_onlyHub() public {
        uint256 id = launchDefault();
        TickerToken tk = tok(id);
        vm.startPrank(attacker);
        vm.expectRevert(TickerToken.NotHub.selector);
        tk.mint(attacker, 1e18);
        vm.expectRevert(TickerToken.NotHub.selector);
        tk.burn(attacker, 1);
        vm.stopPrank();
    }

    // ---------- vault slippage self-check vs a lying router ----------

    function test_vault_slippageSelfCheck_vs_lyingRouter() public {
        // spin a hub whose venue LIES (ignores minOut, delivers 50% of fair)
        LyingVenue liar = new LyingVenue();
        liar.setRegistry(registry);
        RhTickerHub hub2 = new RhTickerHub(registry, ISpotVenue(address(liar)), treasury);
        usdg.mint(trader, 1_000_000e6);
        vm.startPrank(trader);
        usdg.approve(address(hub2), type(uint256).max);
        uint256 id = hub2.launch("Liar", "LIAR", 50_000e6);
        TraderVault v = hub2.getTicker(id).vault;
        // even with minOut=0, the vault's own post-swap balance-diff guard rejects
        // the lying router's under-delivery
        vm.expectRevert(); // SlippageVsOracle
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        vm.stopPrank();
    }

    // ---------- dust guard + zero-amount reverts ----------

    function test_vault_dustSwap_reverts() public {
        uint256 id = launchDefault();
        vm.prank(alice); hub.buy(id, 50_000e6, 0);
        TraderVault v = vaultOf(id);
        // acquire some AAPL, then try to swap 1 wei of it back: valueInQuote(aapl,1)
        // floors to 0 quote (18-dec in -> 6-dec out) -> BadAmount dust guard
        vm.startPrank(trader);
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        vm.expectRevert(TraderVault.BadAmount.selector);
        v.swap(address(aapl), address(usdg), 1, 0, 500);
        vm.stopPrank();
    }

    function test_hub_zeroAmount_reverts() public {
        uint256 id = launchDefault();
        vm.startPrank(alice);
        vm.expectRevert(RhTickerHub.BadAmount.selector);
        hub.buy(id, 0, 0);
        vm.expectRevert(RhTickerHub.BadAmount.selector);
        hub.sell(id, 0, 0, true);
        vm.expectRevert(RhTickerHub.BadAmount.selector);
        hub.redeem(id, 0);
        vm.stopPrank();
    }

    // ---------- syncHeld untrack path ----------

    function test_vault_syncHeld_untrack() public {
        uint256 id = launchDefault();
        vm.prank(alice); hub.buy(id, 50_000e6, 0);
        TraderVault v = vaultOf(id);
        vm.prank(trader);
        v.swap(address(usdg), address(aapl), 10_000e6, 0, 500);
        assertEq(v.heldCount(), 1);
        // burn the vault's AAPL to zero, then syncHeld should drop it
        aapl.adminBurn(address(v), aapl.balanceOf(address(v)));
        vm.prank(trader);
        v.syncHeld(address(aapl));
        assertEq(v.heldCount(), 0, "zero-balance asset untracked");
    }

    // ---------- Lens empty window ----------

    function test_lens_emptyWindow() public {
        TickerLens lens = new TickerLens(hub);
        launchDefault();
        assertEq(lens.snapRange(5, 10).length, 0);
        assertEq(lens.snapRange(0, 10).length, 1);
    }

    // ---------- rolling turnover: no midnight-seam double budget ----------

    function test_turnover_rolling_no_seam() public {
        uint256 id = launchDefault();
        vm.prank(alice); hub.buy(id, 100_000e6, 0);
        TraderVault v = vaultOf(id);

        // two full rotations (~200% of NAV) exhaust the daily budget; a third,
        // done immediately, must revert — proving there's no instant-reset seam.
        vm.startPrank(trader);
        uint256 bal = usdg.balanceOf(address(v));
        v.swap(address(usdg), address(aapl), bal, 0, 500);      // ~100%
        uint256 sh = aapl.balanceOf(address(v));
        v.swap(address(aapl), address(usdg), sh, 0, 500);       // ~200% (at cap)
        uint256 bal2 = usdg.balanceOf(address(v));
        vm.expectRevert(); // TurnoverExceeded — no seam grants a fresh budget
        v.swap(address(usdg), address(aapl), bal2, 0, 500);
        vm.stopPrank();

        // a full day later the accumulator has decayed to ~0 and trading resumes
        vm.warp(block.timestamp + 25 hours);
        _refreshFeeds();
        vm.prank(trader);
        v.swap(address(usdg), address(aapl), bal2, 0, 500); // succeeds
    }
}

/// thin harness so the SafeTransfer library's revert paths are exercised
contract SafeHarness {
    using SafeTransfer for address;
    function doTransfer(address t, address to, uint256 a) external { t.safeTransfer(to, a); }
    function doTransferFrom(address t, address f, address to, uint256 a) external { t.safeTransferFrom(f, to, a); }
    function doApprove(address t, address s, uint256 a) external { t.safeApprove(s, a); }
}
