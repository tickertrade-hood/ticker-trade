// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RhTickerHub} from "./RhTickerHub.sol";
import {TickerToken} from "./TickerToken.sol";
import {TraderVault} from "./TraderVault.sol";

/// @title TickerLens — stateless batch reader for the frontend / leaderboard.
/// @notice Pure view aggregator over the immutable hub: one call returns every
///         ticker's live snapshot so the dapp/leaderboard doesn't fan out N*8
///         RPC reads. Touches no state and holds no privilege — deploy/replace
///         freely without affecting the core.
contract TickerLens {
    RhTickerHub public immutable hub;

    struct Snap {
        uint256 id;
        address token;
        address vault;
        address trader;
        string name;
        string symbol;
        uint64 createdAt;
        bool graduated;
        bool mintFresh;      // at-NAV mints currently allowed (feeds fresh)?
        uint256 price;       // curve price, 6-dec USDG per whole token
        uint256 nav;         // floor, 6-dec USDG per whole token
        uint256 vaultValue;  // AUM, 6-dec USDG
        uint256 circ;        // 18-dec circulating supply
        uint256 marketCap;   // price * circ / 1e18, 6-dec USDG
        uint256 exitReserve; // instant-sell liquidity, 6-dec
        uint256 creatorFees; // claimable by trader, 6-dec
        uint256 vaultQuote;  // idle USDG in the vault (instant redemption depth)
        uint256 queueDepth;  // unsettled redemptions (count)
        int256  premiumBps;  // (price-nav)/nav in bps; negative => trading below floor
    }

    constructor(RhTickerHub _hub) { hub = _hub; }

    function count() external view returns (uint256) { return hub.tickerCount(); }

    /// @notice snapshot a single ticker. `navSafe` swallows a stale-feed revert so
    ///         the leaderboard still renders a halted ticker (nav/price/premium 0).
    function snap(uint256 id) public view returns (Snap memory s) {
        RhTickerHub.Ticker memory t = hub.getTicker(id);
        s.id = id;
        s.token = address(t.token);
        s.vault = address(t.vault);
        s.trader = t.creator;
        s.name = t.token.name();
        s.symbol = t.token.symbol();
        s.createdAt = t.createdAt;
        s.graduated = t.graduated;
        s.exitReserve = t.exitReserve;
        s.creatorFees = t.creatorFees;
        s.circ = t.token.totalSupply();
        s.queueDepth = t.queueTail - t.queueHead;
        s.price = hub.price(id);
        s.marketCap = s.price * s.circ / 1e18;
        s.vaultQuote = hub.quote().balanceOf(address(t.vault));

        // feed-dependent reads are guarded so one stale ticker can't brick the board
        try t.vault.totalValueInQuote() returns (uint256 v) { s.vaultValue = v; } catch {}
        try hub.nav(id) returns (uint256 n) { s.nav = n; } catch {}
        try t.vault.mintFresh() returns (bool f) { s.mintFresh = f; } catch {}
        if (s.nav > 0) {
            s.premiumBps = (int256(s.price) - int256(s.nav)) * 10_000 / int256(s.nav);
        }
    }

    /// @notice snapshot a [start, start+n) window (pagination for large boards)
    function snapRange(uint256 start, uint256 n) external view returns (Snap[] memory out) {
        uint256 total = hub.tickerCount();
        if (start >= total) return new Snap[](0);
        uint256 end = start + n;
        if (end > total) end = total;
        out = new Snap[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = snap(i);
    }

    function snapAll() external view returns (Snap[] memory out) {
        uint256 total = hub.tickerCount();
        out = new Snap[](total);
        for (uint256 i = 0; i < total; i++) out[i] = snap(i);
    }
}
