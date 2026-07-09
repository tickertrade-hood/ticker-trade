// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISpotVenue} from "./interfaces/ISpotVenue.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {SafeTransfer} from "./SafeTransfer.sol";

/// @title TraderVault - one on-chain portfolio per ticker; the Robinhood Chain
///        replacement for a HyperCore native vault.
/// @notice On HyperEVM the "trader can trade but never withdraw" property was
///         enforced by HyperCore vault leadership. Here it is enforced by this
///         contract's ACL + an oracle bound on every swap:
///
///         - trader:  swap() between whitelisted assets only, routed through
///                    Uniswap v3, output checked against Chainlink fair value
///                    (>= fair * (1 - MAX_SLIPPAGE_BPS)). The trader can rotate
///                    the portfolio but cannot hand value to a counterparty pool
///                    beyond the slippage bound per unit of turnover.
///         - hub:     payOut() quote to the hub (redemption settlements + instant
///                    sells refill) and forceSell() assets->quote when the
///                    redemption queue is starving (same oracle bound).
///         - nobody:  any other withdrawal path. No owner, no upgrade, no pause.
///
///         Residual extraction vector (documented, bounded): a malicious trader
///         skims at most MAX_SLIPPAGE_BPS per swap, and turnover is capped at
///         TURNOVER_BPS of NAV per day => worst-case bleed
///         MAX_SLIPPAGE_BPS * TURNOVER_BPS / 1e4 per day (0.8% * 300% = 2.4%/day),
///         fully visible on-chain while holders exit at NAV through the queue.
contract TraderVault {
    using SafeTransfer for address;

    uint256 public constant MAX_SLIPPAGE_BPS = 80;    // vs Chainlink fair value
    uint256 public constant TURNOVER_BPS = 20_000;    // 200% of NAV per day (AUDIT E-3/
                                                      // R-B: allows an honest same-day
                                                      // full de-risk + re-risk rotation;
                                                      // worst-case bleed = slippage*
                                                      // turnover = 1.6%/day, on-chain
                                                      // visible, holders exit at NAV)
    uint256 public constant MINT_FRESH = 36 hours;    // at-NAV mints require every held
                                                      // feed fresher than this. Tuned from
                                                      // live data (AUDIT R-A): quiet equity/
                                                      // ETF feeds sit 13h+ stale intraday and
                                                      // a weekday overnight close is ~24h, so
                                                      // 36h clears normal weekday activity
                                                      // while still blocking multi-day
                                                      // weekend/holiday marks (>48h).
    uint256 public constant MAX_HELD = 24;    // cap held[] length so the NAV loop
                                              // can't be grown into a gas/stale DoS
                                              // (AUDIT M-3). Immutable whitelist is
                                              // small; 24 is generous headroom.
    uint256 private constant BPS = 10_000;
    uint256 private constant DAY = 1 days;

    address public immutable hub;
    address public immutable trader;
    AssetRegistry public immutable registry;
    ISpotVenue public immutable venue;        // untrusted swap venue (see ISpotVenue)
    IERC20 public immutable quote;

    address[] public held;                    // enumerated non-quote assets for NAV
    mapping(address => uint256) private heldIdx; // index+1; 0 = not tracked

    // rolling-window turnover accounting (AUDIT M-1): a fixed UTC-midnight reset let
    // a trader straddle the boundary for ~2x turnover in one minute. Instead we
    // leak the accumulator down linearly over DAY, so no instant boundary ever
    // grants a fresh full budget — any 24h span is bounded to ~TURNOVER_BPS.
    uint256 public turnoverUsed;              // decayed quote units traded
    uint256 public lastTurnoverTs;            // last time the accumulator was touched

    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 fairOut, bool forced);
    event PaidOut(uint256 amount);

    error NotHub();
    error NotTrader();
    error NotWhitelisted(address token);
    error SameToken();
    error BadAmount();
    error SlippageVsOracle(uint256 got, uint256 minFair);
    error TurnoverExceeded(uint256 used, uint256 cap);
    error StaleForSwap();
    error Reentered();

    uint256 private _lock = 1;
    modifier nonReentrant() { if (_lock != 1) revert Reentered(); _lock = 2; _; _lock = 1; }
    modifier onlyHub() { if (msg.sender != hub) revert NotHub(); _; }

    constructor(address _trader, AssetRegistry _registry, ISpotVenue _venue) {
        hub = msg.sender;
        trader = _trader;
        registry = _registry;
        venue = _venue;
        quote = _registry.quote();
        lastTurnoverTs = block.timestamp;
    }

    // ---------- NAV ----------

    /// @notice total portfolio value in quote units (Chainlink-priced, reverts on
    ///         stale feeds - consumers halt instead of trading on a dead price)
    function totalValueInQuote() public view returns (uint256 v) {
        v = quote.balanceOf(address(this));
        uint256 n = held.length;
        for (uint256 i = 0; i < n; i++) {
            address a = held[i];
            v += registry.valueInQuote(a, IERC20(a).balanceOf(address(this)));
        }
    }

    function heldCount() external view returns (uint256) { return held.length; }

    /// @notice trader/hub only: start counting a donated/airdropped listed asset in
    ///         NAV (donations only ever raise NAV - a gift to holders), or drop a
    ///         zero-balance entry to keep the NAV loop tight.
    /// @dev    NOT permissionless (AUDIT S-2): otherwise an attacker could donate
    ///         1 wei of a weekend-idle listed asset and syncHeld it into a vault
    ///         that otherwise held only quote, so its stale feed would revert the
    ///         whole vault's NAV every weekend - a cheap per-ticker DoS on
    ///         buys/sells/redemptions. The trader has no incentive to grief their
    ///         own book; the hub can always clean up.
    function syncHeld(address asset) external {
        if (msg.sender != trader && msg.sender != hub) revert NotTrader();
        if (asset == address(quote)) revert NotWhitelisted(asset);
        if (!registry.isListed(asset)) revert NotWhitelisted(asset);
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal > 0) _trackHeld(asset);
        else _untrackHeld(asset);
    }

    /// @notice true iff every held stock feed (and the quote feed) updated within
    ///         MINT_FRESH. Consumed by the hub to gate at-NAV mints so a stale
    ///         weekend/holiday mark can't be minted against (AUDIT E-1/E-2). A
    ///         vault holding only quote is always mint-fresh.
    function mintFresh() external view returns (bool) {
        if (block.timestamp > registry.quoteUpdatedAt() + MINT_FRESH) return false;
        uint256 n = held.length;
        for (uint256 i = 0; i < n; i++) {
            if (block.timestamp > registry.assetUpdatedAt(held[i]) + MINT_FRESH) return false;
        }
        return true;
    }

    error TooManyAssets();

    function _trackHeld(address asset) internal {
        if (heldIdx[asset] == 0) {
            if (held.length >= MAX_HELD) revert TooManyAssets();
            held.push(asset);
            heldIdx[asset] = held.length;
        }
    }

    function _untrackHeld(address asset) internal {
        uint256 idx = heldIdx[asset];
        if (idx == 0) return;
        uint256 last = held.length;
        if (idx != last) {
            address moved = held[last - 1];
            held[idx - 1] = moved;
            heldIdx[moved] = idx;
        }
        held.pop();
        heldIdx[asset] = 0;
    }

    // ---------- trading ----------

    /// @notice trader-only portfolio rotation between whitelisted assets
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 poolFee)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (msg.sender != trader) revert NotTrader();
        out = _swap(tokenIn, tokenOut, amountIn, minOut, poolFee, false);
    }

    /// @notice hub-only forced liquidation toward quote (redemption-queue starvation
    ///         crank; the hub gates how much may be raised)
    function forceSell(address asset, uint256 amountIn, uint24 poolFee)
        external
        nonReentrant
        onlyHub
        returns (uint256 out)
    {
        out = _swap(asset, address(quote), amountIn, 0, poolFee, true);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 poolFee, bool forced)
        internal
        returns (uint256 out)
    {
        if (amountIn == 0) revert BadAmount();
        if (tokenIn == tokenOut) revert SameToken();
        if (tokenIn != address(quote) && !registry.isListed(tokenIn)) revert NotWhitelisted(tokenIn);
        if (tokenOut != address(quote) && !registry.isListed(tokenOut)) revert NotWhitelisted(tokenOut);

        // AUDIT R5-4: buying INTO a stock values it at its (possibly stale) feed.
        // Gate that on freshness so the trader can't rotate the vault into a
        // weekend/holiday stale-marked asset at a price reality has moved past.
        // Selling a stock -> quote (incl. forceSell for redemptions) is NOT gated:
        // realizing a stale mark to quote only helps the vault.
        if (tokenOut != address(quote)
            && block.timestamp > registry.assetUpdatedAt(tokenOut) + MINT_FRESH) revert StaleForSwap();

        uint256 fairOut;
        (minOut, fairOut) = _boundedMinOut(tokenIn, tokenOut, amountIn, minOut);

        out = _execRouter(tokenIn, tokenOut, amountIn, minOut, poolFee);

        if (tokenOut != address(quote)) _trackHeld(tokenOut);
        if (tokenIn != address(quote) && IERC20(tokenIn).balanceOf(address(this)) == 0) _untrackHeld(tokenIn);

        emit Swapped(tokenIn, tokenOut, amountIn, out, fairOut, forced);
    }

    /// @dev oracle bound: the swap may not hand more than MAX_SLIPPAGE_BPS of fair
    ///      value to the pool, no matter what minOut the caller passed. Also
    ///      charges the daily turnover cap (forced liquidations skip it: they are
    ///      redemption-driven and already bounded by the hub's shortfall gate).
    function _boundedMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256, uint256)
    {
        uint256 valueQ = registry.valueInQuote(tokenIn, amountIn);
        uint256 fairOut = registry.amountFromQuote(tokenOut, valueQ);
        // AUDIT S-3: a swap so small that its quote value or fair output floors to
        // zero would make the slippage bound zero (any output accepted) and evade
        // the turnover counter. Reject dust swaps outright.
        if (valueQ == 0 || fairOut == 0) revert BadAmount();
        // AUDIT R5-2: ceil-round the bound so truncation favors the VAULT, not the pool.
        uint256 minFair = (fairOut * (BPS - MAX_SLIPPAGE_BPS) + BPS - 1) / BPS;
        if (minOut < minFair) minOut = minFair;

        // AUDIT R5-1: charge turnover on EVERY leg, forced included. Previously
        // forced sells were exempt, which let a colluding trader keep a standing
        // self-redemption "starving" and route unbounded volume through the venue
        // at the 0.8% skim. Redemption needs are far below the daily cap (gated at
        // 20%/epoch), so legitimate forced servicing is never blocked.
        uint256 elapsed = block.timestamp - lastTurnoverTs;
        uint256 used = elapsed >= DAY ? 0 : turnoverUsed - (turnoverUsed * elapsed / DAY);
        uint256 cap = totalValueInQuote() * TURNOVER_BPS / BPS;
        if (used + valueQ > cap) revert TurnoverExceeded(used + valueQ, cap);
        turnoverUsed = used + valueQ;
        lastTurnoverTs = block.timestamp;
        return (minOut, fairOut);
    }

    function _execRouter(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 poolFee)
        internal
        returns (uint256 out)
    {
        if (IERC20(tokenIn).balanceOf(address(this)) < amountIn) revert BadAmount();
        uint256 balOutBefore = IERC20(tokenOut).balanceOf(address(this));

        // route through the (untrusted) venue: approve exactly amountIn, swap with
        // output back to this vault, then revoke. The venue can't pull more than the
        // approval, and we re-verify the result by our own balance diff below.
        tokenIn.safeApprove(address(venue), amountIn);
        venue.swapExactIn(tokenIn, tokenOut, amountIn, minOut, poolFee, address(this));
        tokenIn.safeApprove(address(venue), 0);

        // measure by balance diff - never trust the venue's return value
        out = IERC20(tokenOut).balanceOf(address(this)) - balOutBefore;
        if (out < minOut) revert SlippageVsOracle(out, minOut);
    }

    // ---------- hub settlement ----------

    /// @notice move quote to the hub (redemption payouts). Only the hub, and the
    ///         hub only forwards to redeemers/reserves inside the same tx.
    function payOut(uint256 amount) external onlyHub {
        address(quote).safeTransfer(hub, amount);
        emit PaidOut(amount);
    }
}
