// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Tick} from "../src/token/Tick.sol";
import {FeeStaking} from "../src/token/FeeStaking.sol";
import {FeeDistributor, IFeeStaking} from "../src/token/FeeDistributor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// Streaming-model staking tests (rewards drip over REWARD_DURATION). The headline
/// is test_flash_stake_earns_nothing — the AUDIT-round-5 CRITICAL fix.
contract FeeStakingTest is Test {
    Tick tick;
    MockERC20 usdg;
    FeeStaking staking;
    address deployer = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");
    address feeSource = makeAddr("feeSource");
    uint256 DUR;

    function setUp() public {
        vm.warp(1_800_000_000);
        tick = new Tick(1_000_000_000e18, deployer);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        staking = new FeeStaking(IERC20(address(tick)), IERC20(address(usdg)));
        DUR = staking.REWARD_DURATION();
        tick.transfer(alice, 10_000_000e18);
        tick.transfer(bob, 10_000_000e18);
        tick.transfer(attacker, 500_000_000e18); // whale for the flash-stake attempt
        for (uint256 i; i < 3; i++) { address a = [alice, bob, attacker][i]; vm.prank(a); tick.approve(address(staking), type(uint256).max); }
        usdg.mint(feeSource, 100_000_000e6);
        vm.prank(feeSource); usdg.approve(address(staking), type(uint256).max);
    }

    function _fund(uint256 amt) internal { vm.prank(feeSource); staking.fund(amt); }

    // ---------- the CRITICAL fix ----------

    function test_flash_stake_earns_nothing() public {
        // an honest staker present for the whole stream
        vm.prank(alice); staking.stake(1_000_000e18);
        // attacker flash-stakes a whale position right as fees arrive, same block
        vm.prank(attacker); staking.stake(500_000_000e18); // 500x alice
        _fund(10_000e6);
        // attacker immediately claims + unstakes in the SAME block (flash-loan window)
        vm.prank(attacker); uint256 stolen = staking.claim();
        vm.prank(attacker); staking.unstake(500_000_000e18);
        assertEq(stolen, 0, "flash-staker skimmed the distribution");
        // the stream now belongs to the remaining honest staker over time
        vm.warp(block.timestamp + DUR);
        assertApproxEqRel(staking.earned(alice), 10_000e6, 1e15, "honest staker earns the stream");
    }

    // ---------- streaming basics ----------

    function test_single_staker_earns_full_stream_over_time() public {
        vm.prank(alice); staking.stake(500_000e18);
        _fund(7_000e6);
        assertEq(staking.earned(alice), 0, "nothing accrues instantly");
        vm.warp(block.timestamp + DUR / 2);
        assertApproxEqRel(staking.earned(alice), 3_500e6, 1e15, "half the stream at half time");
        vm.warp(block.timestamp + DUR / 2);
        assertApproxEqRel(staking.earned(alice), 7_000e6, 1e15, "full stream at full time");
        vm.prank(alice); uint256 got = staking.claim();
        assertApproxEqRel(got, 7_000e6, 1e15);
    }

    function test_prorata_by_stake_over_the_stream() public {
        vm.prank(alice); staking.stake(750_000e18); // 75%
        vm.prank(bob);   staking.stake(250_000e18); // 25%
        _fund(10_000e6);
        vm.warp(block.timestamp + DUR);
        assertApproxEqRel(staking.earned(alice), 7_500e6, 1e15, "alice 75%");
        assertApproxEqRel(staking.earned(bob), 2_500e6, 1e15, "bob 25%");
    }

    function test_late_staker_only_earns_from_join() public {
        vm.prank(alice); staking.stake(1_000_000e18);
        _fund(7_000e6);
        vm.warp(block.timestamp + DUR / 2);          // alice alone for half
        vm.prank(bob); staking.stake(1_000_000e18);  // bob joins at halftime, equal stake
        vm.warp(block.timestamp + DUR / 2);          // both for the second half
        // alice: all of first half (3500) + half of second half (1750) = 5250
        // bob: half of second half (1750)
        assertApproxEqRel(staking.earned(alice), 5_250e6, 2e15, "alice front-half + share");
        assertApproxEqRel(staking.earned(bob), 1_750e6, 2e15, "bob only from join");
    }

    function test_unstake_pays_and_stops_accruing() public {
        vm.prank(alice); staking.stake(1_000_000e18);
        _fund(7_000e6);
        vm.warp(block.timestamp + DUR);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice); staking.claim();
        vm.prank(alice); staking.unstake(1_000_000e18);
        assertApproxEqRel(usdg.balanceOf(alice) - before, 7_000e6, 1e15);
        assertEq(tick.balanceOf(alice), 10_000_000e18, "TICK returned");
    }

    function test_fund_rolls_leftover_into_new_rate() public {
        vm.prank(alice); staking.stake(1_000_000e18);
        _fund(7_000e6);
        vm.warp(block.timestamp + DUR / 2);   // 3500 streamed, 3500 leftover
        _fund(7_000e6);                       // new period: 3500 leftover + 7000 = 10500 over DUR
        vm.warp(block.timestamp + DUR);
        assertApproxEqRel(staking.earned(alice), 14_000e6, 2e15, "all funded USDG eventually earned");
    }

    function test_fund_too_small_reverts() public {
        vm.prank(alice); staking.stake(1_000_000e18);
        vm.prank(feeSource);
        vm.expectRevert(FeeStaking.TooSmall.selector);
        staking.fund(1); // < REWARD_DURATION wei -> rate rounds to 0
    }

    function test_cannot_unstake_more_than_staked() public {
        vm.prank(alice); staking.stake(100e18);
        vm.prank(alice);
        vm.expectRevert(FeeStaking.BadAmount.selector);
        staking.unstake(101e18);
    }
}

contract FeeDistributorTest is Test {
    Tick tick;
    MockERC20 usdg;
    FeeStaking staking;
    FeeDistributor dist;
    address team = makeAddr("team");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        tick = new Tick(1_000_000_000e18, address(this));
        usdg = new MockERC20("USDG", "USDG", 6);
        staking = new FeeStaking(IERC20(address(tick)), IERC20(address(usdg)));
        dist = new FeeDistributor(IERC20(address(usdg)), IFeeStaking(address(staking)), team, 7000);
        tick.transfer(alice, 1_000_000e18);
        vm.prank(alice); tick.approve(address(staking), type(uint256).max);
    }

    function test_splits_70_30_and_streams_staker_share() public {
        vm.prank(alice); staking.stake(1_000_000e18);
        usdg.mint(address(dist), 1_000e6);
        (uint256 toStakers, uint256 toTeam) = dist.distribute();
        assertEq(toStakers, 700e6);
        assertEq(toTeam, 300e6);
        assertEq(usdg.balanceOf(team), 300e6);
        vm.warp(block.timestamp + staking.REWARD_DURATION());
        assertApproxEqRel(staking.earned(alice), 700e6, 3e15, "staker share streamed out");
    }

    function test_no_stakers_routes_all_to_team() public {
        usdg.mint(address(dist), 1_000e6);
        (uint256 toStakers, uint256 toTeam) = dist.distribute();
        assertEq(toStakers, 0);
        assertEq(toTeam, 1_000e6);
    }

    function test_bad_config_reverts() public {
        vm.expectRevert(FeeDistributor.BadConfig.selector);
        new FeeDistributor(IERC20(address(usdg)), IFeeStaking(address(staking)), team, 10_001);
    }
}
