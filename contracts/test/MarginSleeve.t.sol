// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarginSleeve} from "../src/venues/MarginSleeve.sol";
import {ILighterRelayer} from "../src/interfaces/ILighterRelayer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20, MockLighterRelayer} from "./mocks/Mocks.sol";

/// The MarginSleeve is the async Lighter integration's trust boundary. These
/// tests pin the three invariants that make a keeper-mediated venue safe:
///   1. the keeper can never receive funds (no extraction, even when hostile);
///   2. redeemable value counts only realized on-chain quote, never the keeper's
///      reported equity (no NAV inflation -> no over-redemption drain);
///   3. only the owner sweeps funds out, and only to itself.
contract MarginSleeveTest is Test {
    MockERC20 usdg;
    MockLighterRelayer relayer;
    MarginSleeve sleeve;

    address owner = makeAddr("owner");     // the vault/hub
    address keeper = makeAddr("keeper");   // trader's off-chain signer
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        relayer = new MockLighterRelayer(IERC20(address(usdg)));
        sleeve = new MarginSleeve(owner, keeper, IERC20(address(usdg)), ILighterRelayer(address(relayer)));

        usdg.mint(owner, 1_000_000e6);
        usdg.mint(address(this), 1_000_000e6); // funder of relayer PnL settlements
        usdg.approve(address(relayer), type(uint256).max);
        vm.prank(owner); usdg.approve(address(sleeve), type(uint256).max);
    }

    function _fund(uint256 amt) internal { vm.prank(owner); sleeve.fund(amt); }

    // ---------- constructor guards (AUDIT S-9) ----------

    function test_constructor_rejects_owner_equals_keeper() public {
        vm.expectRevert(MarginSleeve.BadConfig.selector);
        new MarginSleeve(owner, owner, IERC20(address(usdg)), ILighterRelayer(address(relayer)));
        vm.expectRevert(MarginSleeve.BadConfig.selector);
        new MarginSleeve(address(0), keeper, IERC20(address(usdg)), ILighterRelayer(address(relayer)));
    }

    // ---------- ACL ----------

    function test_only_owner_funds_and_sweeps() public {
        _fund(100_000e6);
        vm.prank(attacker);
        vm.expectRevert(MarginSleeve.NotOwner.selector);
        sleeve.fund(1);
        vm.prank(keeper);
        vm.expectRevert(MarginSleeve.NotOwner.selector);
        sleeve.sweepToOwner(1);
        vm.prank(attacker);
        vm.expectRevert(MarginSleeve.NotOwner.selector);
        sleeve.sweepToOwner(1);
    }

    function test_only_keeper_venue_ops() public {
        _fund(100_000e6);
        vm.prank(attacker);
        vm.expectRevert(MarginSleeve.NotKeeper.selector);
        sleeve.depositToVenue(1);
        vm.prank(owner); // even the owner can't place venue ops
        vm.expectRevert(MarginSleeve.NotKeeper.selector);
        sleeve.depositToVenue(1);
        vm.prank(attacker);
        vm.expectRevert(MarginSleeve.NotKeeper.selector);
        sleeve.reportEquity(1);
    }

    // ---------- invariant 1: keeper can never receive funds ----------

    function test_keeper_cannot_extract() public {
        _fund(100_000e6);
        uint256 keeperStart = usdg.balanceOf(keeper);
        vm.startPrank(keeper);
        sleeve.depositToVenue(80_000e6);     // push margin to venue
        sleeve.withdrawFromVenue(80_000e6);  // pull it back -> lands in the SLEEVE
        vm.stopPrank();
        // no keeper-facing transfer exists; the keeper's balance never moved
        assertEq(usdg.balanceOf(keeper), keeperStart, "keeper extracted funds");
        // withdrawn funds are in the sleeve, sweepable only by the owner
        assertEq(sleeve.idleQuote(), 100_000e6);
    }

    // ---------- invariant 2: reported equity never becomes redeemable ----------

    function test_reportedEquity_not_redeemable() public {
        _fund(100_000e6);
        vm.prank(keeper);
        sleeve.depositToVenue(100_000e6); // all in venue as collateral
        // keeper reports a rosy (but in-band) equity
        vm.prank(keeper);
        sleeve.reportEquity(140_000e6);
        assertEq(sleeve.displayEquityUnsafe(), 140_000e6);
        // redeemable value is ONLY realized: idle(0) + escrowed collateral(100k)
        assertEq(sleeve.redeemableValue(), 100_000e6, "reported equity leaked into redeemable");
    }

    function test_reportEquity_deviation_circuitBreaker() public {
        _fund(100_000e6);
        vm.prank(keeper);
        sleeve.depositToVenue(100_000e6);
        // collateral is 100k; a report >150k or <50k must revert
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MarginSleeve.DeviationTooLarge.selector, 200_000e6, 100_000e6));
        sleeve.reportEquity(200_000e6);
        // within band is fine
        vm.prank(keeper);
        sleeve.reportEquity(120_000e6);
        assertTrue(sleeve.equityFresh());
    }

    // ---------- invariant 3: realized PnL flows correctly, bounded ----------

    function test_realized_gain_becomes_redeemable_only_when_settled() public {
        _fund(100_000e6);
        vm.prank(keeper);
        sleeve.depositToVenue(100_000e6);
        assertEq(sleeve.redeemableValue(), 100_000e6);

        // trader wins 20k off-chain; it only counts once SETTLED on-chain
        relayer.settlePnl(address(sleeve), 20_000e6);
        assertEq(sleeve.escrowedCollateral(), 120_000e6);
        assertEq(sleeve.redeemableValue(), 120_000e6, "settled gain is redeemable");

        // keeper pulls it back to the sleeve, owner sweeps to the vault
        vm.prank(keeper);
        sleeve.withdrawFromVenue(120_000e6);
        assertEq(sleeve.idleQuote(), 120_000e6);
        uint256 ownerStart = usdg.balanceOf(owner);
        vm.prank(owner);
        sleeve.sweepToOwner(120_000e6);
        assertEq(usdg.balanceOf(owner) - ownerStart, 120_000e6, "owner realized the gain");
    }

    function test_realized_loss_is_bounded_to_sleeve_capital() public {
        _fund(100_000e6);
        vm.prank(keeper);
        sleeve.depositToVenue(100_000e6);
        // trader blows up: loses everything (and then some) off-chain
        relayer.settlePnl(address(sleeve), -500_000e6);
        // loss is capped at the collateral actually in the venue
        assertEq(sleeve.escrowedCollateral(), 0);
        assertEq(sleeve.redeemableValue(), 0, "loss bounded to sleeve capital");
        // the rest of the world (owner's other funds) is untouched — only the
        // capital the owner CHOSE to put in the sleeve was ever at risk
    }

    // ---------- sweep bounded by idle ----------

    function test_sweep_cannot_exceed_idle() public {
        _fund(100_000e6);
        vm.prank(keeper);
        sleeve.depositToVenue(100_000e6); // idle now 0, all in venue
        vm.prank(owner);
        vm.expectRevert(MarginSleeve.BadAmount.selector);
        sleeve.sweepToOwner(1); // nothing idle to sweep
    }
}
