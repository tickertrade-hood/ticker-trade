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

/// Stateful invariant harness. Foundry drives random sequences of launches,
/// buys, sells, redemptions, settlements, trader swaps, market moves and time
/// warps across multiple actors; after EVERY sequence:
///   1. hub quote conservation: hub balance == protoFees + Σ(exitReserve+creatorFees)
///   2. traders never extract: no trader address ever gains quote except via
///      claimCreatorFees (tracked)
///   3. no curve sell prints below NAV
///   4. queue accounting: escrowed redemption tokens == hub's token balance - seed
contract Handler is Test {
    RhTickerHub public hub;
    MockERC20 public usdg;
    MockStock public aapl;
    MockStock public tsla;
    MockFeed public aaplFeed;
    MockFeed public tslaFeed;
    MockFeed public usdgFeed;
    MockFeed public wethFeed;
    AssetRegistry public reg;

    address[] public actors;
    address[] public traders;
    uint256 public ghostLaunches;
    uint256 public ghostCreatorFeesClaimed; // quote paid out to traders via fees
    uint256 public tstamp;

    struct Cfg {
        RhTickerHub hub;
        MockERC20 usdg;
        MockStock aapl;
        MockStock tsla;
        MockFeed aaplFeed;
        MockFeed tslaFeed;
        MockFeed usdgFeed;
        MockFeed wethFeed;
        AssetRegistry reg;
        address[] actors;
        address[] traders;
    }

    constructor(Cfg memory c) {
        hub = c.hub; usdg = c.usdg; aapl = c.aapl; tsla = c.tsla;
        aaplFeed = c.aaplFeed; tslaFeed = c.tslaFeed; usdgFeed = c.usdgFeed; wethFeed = c.wethFeed;
        reg = c.reg; actors = c.actors; traders = c.traders;
        tstamp = block.timestamp;
    }

    modifier useActor(uint256 s) {
        address a = actors[s % actors.length];
        vm.startPrank(a);
        _;
        vm.stopPrank();
    }

    function _tok(uint256 id) internal view returns (TickerToken) {
        return hub.getTicker(id).token;
    }

    function launch(uint256 s, uint256 seed) public {
        address who = traders[s % traders.length];
        seed = bound(seed, 500e6, 200_000e6);
        string memory sym = string(abi.encodePacked("T", vm.toString(ghostLaunches)));
        vm.startPrank(who);
        try hub.launch(sym, sym, seed) { ghostLaunches++; } catch {}
        vm.stopPrank();
    }

    function buy(uint256 s, uint256 id, uint256 usdIn) public useActor(s) {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        usdIn = bound(usdIn, 1e6, 500_000e6);
        try hub.buy(id, usdIn, 0) {} catch {}
    }

    function sellOrQueue(uint256 s, uint256 id, uint256 frac) public useActor(s) {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        address a = actors[s % actors.length];
        uint256 bal = _tok(id).balanceOf(a);
        if (bal == 0) return;
        uint256 qty = bal * bound(frac, 1, 100) / 100;
        _tok(id).approve(address(hub), type(uint256).max);
        try hub.sell(id, qty, 0, true) {} catch {}
    }

    function redeem(uint256 s, uint256 id, uint256 frac) public useActor(s) {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        address a = actors[s % actors.length];
        uint256 bal = _tok(id).balanceOf(a);
        if (bal == 0) return;
        uint256 qty = bal * bound(frac, 1, 100) / 100;
        _tok(id).approve(address(hub), type(uint256).max);
        try hub.redeem(id, qty) {} catch {}
    }

    function settle(uint256 s, uint256 id) public useActor(s) {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        try hub.settleQueue(id, 10) {} catch {}
    }

    function forceRaise(uint256 id, uint256 frac) public {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        TraderVault v = hub.getTicker(id).vault;
        uint256 bal = aapl.balanceOf(address(v));
        if (bal == 0) return;
        uint256 amt = bal * bound(frac, 1, 100) / 100;
        try hub.forceRaise(id, address(aapl), amt, 500) {} catch {}
    }

    function traderSwap(uint256 id, uint256 frac, bool toStock) public {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        TraderVault v = hub.getTicker(id).vault;
        address who = v.trader();
        vm.startPrank(who);
        if (toStock) {
            uint256 bal = usdg.balanceOf(address(v));
            if (bal > 1e6) {
                try v.swap(address(usdg), address(aapl), bal * bound(frac, 1, 100) / 100, 0, 500) {} catch {}
            }
        } else {
            uint256 bal = aapl.balanceOf(address(v));
            if (bal > 0) {
                try v.swap(address(aapl), address(usdg), bal * bound(frac, 1, 100) / 100 + 1, 0, 500) {} catch {}
            }
        }
        vm.stopPrank();
    }

    function claimFees(uint256 id) public {
        if (hub.tickerCount() == 0) return;
        id = id % hub.tickerCount();
        address who = hub.getTicker(id).creator;
        uint256 before = usdg.balanceOf(who);
        vm.startPrank(who);
        try hub.claimCreatorFees(id) {
            ghostCreatorFeesClaimed += usdg.balanceOf(who) - before;
        } catch {}
        vm.stopPrank();
    }

    function marketMove(uint256 s) public {
        int256 px = aaplFeed.answer();
        int256 shift = int256(bound(s, 0, 60)) - 30; // ±30%
        int256 nu = px + px * shift / 100;
        if (nu < 1e6) nu = 1e6;
        aaplFeed.set(nu);
        px = tslaFeed.answer();
        nu = px - px * shift / 200;
        if (nu < 1e6) nu = 1e6;
        tslaFeed.set(nu);
    }

    function warp(uint256 secs) public {
        tstamp += bound(secs, 1 hours, 2 days);
        vm.warp(tstamp);
        // keep feeds alive so staleness doesn't freeze the whole run
        aaplFeed.set(aaplFeed.answer());
        tslaFeed.set(tslaFeed.answer());
        usdgFeed.set(usdgFeed.answer());
        wethFeed.set(wethFeed.answer());
    }
}

contract InvariantsTest is Test {
    RhTickerHub hub;
    MockERC20 usdg;
    MockStock aapl;
    MockStock tsla;
    MockERC20 weth;
    MockFeed usdgFeed;
    MockFeed aaplFeed;
    MockFeed tslaFeed;
    MockFeed wethFeed;
    MockSpotVenue router;
    AssetRegistry registry;
    Handler handler;

    address treasury = makeAddr("treasury");
    address[] traders_;
    uint256 traderInitialFunding = 5_000_000e6;

    function setUp() public {
        vm.warp(1_780_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockStock("Apple Stock Token", "AAPLx");
        tsla = new MockStock("Tesla Stock Token", "TSLAx");
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdgFeed = new MockFeed(8, 1e8);
        aaplFeed = new MockFeed(8, 200e8);
        tslaFeed = new MockFeed(8, 250e8);
        wethFeed = new MockFeed(8, 1700e8);

        address[] memory assets = new address[](3);
        assets[0] = address(aapl); assets[1] = address(tsla); assets[2] = address(weth);
        IAggregatorV3[] memory feeds = new IAggregatorV3[](3);
        feeds[0] = IAggregatorV3(address(aaplFeed));
        feeds[1] = IAggregatorV3(address(tslaFeed));
        feeds[2] = IAggregatorV3(address(wethFeed));
        uint48[] memory stales = new uint48[](3);
        stales[0] = 96 hours; stales[1] = 96 hours; stales[2] = 96 hours;
        bool[] memory hasMul = new bool[](3);
        hasMul[0] = true; hasMul[1] = true; hasMul[2] = false;

        registry = new AssetRegistry(
            IERC20(address(usdg)), IAggregatorV3(address(usdgFeed)), 96 hours,
            assets, feeds, stales, hasMul
        );
        router = new MockSpotVenue();
        router.setRegistry(registry);
        hub = new RhTickerHub(registry, ISpotVenue(address(router)), treasury);

        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            usdg.mint(actors[i], 5_000_000e6);
            vm.prank(actors[i]);
            usdg.approve(address(hub), type(uint256).max);
        }
        traders_ = new address[](2);
        for (uint256 i = 0; i < 2; i++) {
            traders_[i] = makeAddr(string(abi.encodePacked("trader", vm.toString(i))));
            usdg.mint(traders_[i], traderInitialFunding);
            vm.prank(traders_[i]);
            usdg.approve(address(hub), type(uint256).max);
        }

        handler = new Handler(Handler.Cfg({
            hub: hub, usdg: usdg, aapl: aapl, tsla: tsla,
            aaplFeed: aaplFeed, tslaFeed: tslaFeed, usdgFeed: usdgFeed, wethFeed: wethFeed,
            reg: registry, actors: actors, traders: traders_
        }));

        vm.prank(traders_[0]);
        hub.launch("SEED", "SEED", 10_000e6);

        targetContract(address(handler));
    }

    /// master invariant: the hub's quote balance covers exactly its claims
    function invariant_hubQuoteConservation() public view {
        uint256 claims = hub.protoFees();
        for (uint256 i = 0; i < hub.tickerCount(); i++) {
            RhTickerHub.Ticker memory t = hub.getTicker(i);
            claims += t.exitReserve + t.creatorFees;
        }
        assertEq(usdg.balanceOf(address(hub)), claims, "hub conservation broken");
    }

    /// traders can be paid ONLY through creator fees - never out of a vault.
    /// (Their spend on launches/seeds means balance strictly declines otherwise.)
    function invariant_traderNeverExtracts() public view {
        uint256 total;
        for (uint256 i = 0; i < traders_.length; i++) {
            total += usdg.balanceOf(traders_[i]);
        }
        // total trader cash <= initial funding + claimed fees (they only spend)
        assertLe(
            total,
            traderInitialFunding * traders_.length + handler.ghostCreatorFeesClaimed(),
            "a trader extracted vault money"
        );
    }

    /// the floor promise: no executable curve sell prints below NAV
    function invariant_noPrintBelowNav() public view {
        for (uint256 i = 0; i < hub.tickerCount(); i++) {
            uint256 c = hub.circ(i);
            if (c < 1e15) continue;
            uint256 qty = c / 100 + 1;
            (uint256 proceeds,, bool routed) = hub.quoteSell(i, qty);
            if (!routed) {
                assertGe(proceeds * 1e18 / qty, hub.nav(i) * 999 / 1000, "curve printed below NAV");
            }
        }
    }

    /// hub token custody = escrowed seed + escrowed queue entries, exactly
    function invariant_escrowAccounting() public view {
        for (uint256 i = 0; i < hub.tickerCount(); i++) {
            RhTickerHub.Ticker memory t = hub.getTicker(i);
            uint256 queued;
            for (uint256 q = t.queueHead; q < t.queueTail; q++) {
                (, uint256 qty,) = hub.queue(i, q);
                queued += qty;
            }
            assertEq(
                t.token.balanceOf(address(hub)),
                t.seedQty + queued,
                "hub token custody mismatch"
            );
        }
    }
}
