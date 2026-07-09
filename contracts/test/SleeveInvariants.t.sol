// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarginSleeve} from "../src/venues/MarginSleeve.sol";
import {ILighterRelayer} from "../src/interfaces/ILighterRelayer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20, MockLighterRelayer} from "./mocks/Mocks.sol";

/// Stateful invariant harness: Foundry drives random sequences of a HOSTILE keeper
/// (deposit/withdraw/report) + random relayer PnL settlements + owner fund/sweep.
/// After every sequence:
///   1. the keeper's balance is exactly 0 (never received a cent);
///   2. redeemableValue never includes the keeper's display equity;
///   3. total quote is conserved across {sleeve, relayer, owner, pnl-funder}.
contract SleeveHandler is Test {
    MockERC20 usdg;
    MockLighterRelayer relayer;
    MarginSleeve sleeve;
    address owner;
    address keeper;
    address pnlFunder;

    uint256 public ownerFunded;   // cumulative owner -> sleeve
    uint256 public ownerSwept;    // cumulative sleeve -> owner
    int256 public netPnl;         // cumulative settled PnL into the sleeve's collateral

    constructor(MockERC20 _usdg, MockLighterRelayer _relayer, MarginSleeve _sleeve, address _owner, address _keeper, address _funder) {
        usdg = _usdg; relayer = _relayer; sleeve = _sleeve; owner = _owner; keeper = _keeper; pnlFunder = _funder;
    }

    function fund(uint256 amt) public {
        amt = bound(amt, 0, usdg.balanceOf(owner));
        if (amt == 0) return;
        vm.prank(owner); try sleeve.fund(amt) { ownerFunded += amt; } catch {}
    }
    function sweep(uint256 amt) public {
        amt = bound(amt, 0, sleeve.idleQuote());
        if (amt == 0) return;
        vm.prank(owner); try sleeve.sweepToOwner(amt) { ownerSwept += amt; } catch {}
    }
    function deposit(uint256 amt) public {
        amt = bound(amt, 0, sleeve.idleQuote());
        if (amt == 0) return;
        vm.prank(keeper); try sleeve.depositToVenue(amt) {} catch {}
    }
    function withdraw(uint256 amt) public {
        amt = bound(amt, 0, relayer.collateralOf(address(sleeve)));
        if (amt == 0) return;
        vm.prank(keeper); try sleeve.withdrawFromVenue(amt) {} catch {}
    }
    function report(uint256 eq) public {
        eq = bound(eq, 0, 2_000_000e6);
        vm.prank(keeper); try sleeve.reportEquity(eq) {} catch {}
    }
    function settle(int256 pnl) public {
        pnl = int256(bound(pnl, -500_000e6, 500_000e6));
        // fund positive PnL from the pnlFunder's balance
        if (pnl > 0 && usdg.balanceOf(pnlFunder) < uint256(pnl)) return;
        vm.prank(pnlFunder);
        try relayer.settlePnl(address(sleeve), pnl) { netPnl += pnl; } catch {}
    }
}

contract SleeveInvariantsTest is Test {
    MockERC20 usdg;
    MockLighterRelayer relayer;
    MarginSleeve sleeve;
    SleeveHandler handler;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address pnlFunder = makeAddr("pnlFunder");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        relayer = new MockLighterRelayer(IERC20(address(usdg)));
        sleeve = new MarginSleeve(owner, keeper, IERC20(address(usdg)), ILighterRelayer(address(relayer)));
        usdg.mint(owner, 2_000_000e6);
        usdg.mint(pnlFunder, 2_000_000e6);
        vm.prank(owner); usdg.approve(address(sleeve), type(uint256).max);
        vm.prank(pnlFunder); usdg.approve(address(relayer), type(uint256).max);
        handler = new SleeveHandler(usdg, relayer, sleeve, owner, keeper, pnlFunder);
        // move approvals to the handler's pranks
        vm.prank(owner); usdg.approve(address(sleeve), type(uint256).max);
        targetContract(address(handler));
    }

    /// invariant 1: the keeper NEVER holds a single unit of quote
    function invariant_keeperNeverHoldsFunds() public view {
        assertEq(usdg.balanceOf(keeper), 0, "keeper extracted funds");
    }

    /// invariant 2: redeemable value = idle + escrowed collateral, and NEVER counts
    /// the keeper's display equity (even when the keeper reports a huge number)
    function invariant_redeemableExcludesDisplayEquity() public view {
        uint256 expected = usdg.balanceOf(address(sleeve)) + relayer.collateralOf(address(sleeve));
        assertEq(sleeve.redeemableValue(), expected, "redeemable diverged from realized");
    }

    /// invariant 3: quote is conserved — nothing is minted or lost across the system
    function invariant_quoteConservation() public view {
        uint256 total = usdg.balanceOf(address(sleeve))
            + usdg.balanceOf(address(relayer))
            + usdg.balanceOf(owner)
            + usdg.balanceOf(pnlFunder);
        // everything started in owner + pnlFunder (2M each)
        assertEq(total, 4_000_000e6, "quote created or destroyed");
    }
}
