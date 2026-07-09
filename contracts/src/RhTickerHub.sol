// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TickerToken} from "./TickerToken.sol";
import {TraderVault} from "./TraderVault.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ISpotVenue} from "./interfaces/ISpotVenue.sol";
import {SafeTransfer} from "./SafeTransfer.sol";

/// @title RhTickerHub - TICKER.TRADE mechanism for Robinhood Chain (chain 4663).
/// @notice Port of the HyperEVM v0.1 hub with the simulated-PnL oracle REMOVED:
///         each ticker's backing is a TraderVault holding USDG + whitelisted
///         tokenized stocks/ETFs, and NAV is computed trustlessly from Chainlink
///         feeds. There is no reportPnl, no god-key; the only privileged address
///         is the immutable treasury (fee sink, cannot touch vaults).
///
///         Mechanism (unchanged from DESIGN.md):
///         - virtual constant-product curve per ticker (XV0 vUSDG / YV0 tokens)
///         - every buy splits 80% -> vault (NAV backing) / 20% -> exit reserve
///         - NAV floor binds both directions: sells below NAV (or beyond reserve
///           depth) route to the redemption queue; buys below NAV mint AT NAV
///           with 100% -> vault
///         - redemption gate: max 20% of circulating settles per epoch, FIFO,
///           partial fills roll (bank-run-proof)
///         - settlements are additionally bounded by the vault's QUOTE liquidity:
///           if the trader is fully deployed in stocks, anyone can crank
///           forceRaise() to liquidate just enough (oracle-bounded) to pay the
///           due queue head
///         - creator seed locked 30 days; graduation at $250k vault + 30 days
///
///         Known residuals (see AUDIT.md): Chainlink latency arb bounded by the
///         1% curve fee vs feed deviation thresholds; stock feeds idle off-hours
///         (weekend NAV = Friday close - the 6h queue delay and epoch gate absorb
///         gap risk); stock tokens themselves are pausable/beacon-upgradeable by
///         Robinhood (issuer risk, external to this protocol).
contract RhTickerHub {
    using SafeTransfer for address;

    // ---------- params (USDG = 6 dec, ticker tokens = 18 dec) ----------
    uint256 public constant CURVE_FEE_BPS = 100;
    uint256 public constant GRAD_FEE_BPS = 50;
    uint256 public constant FEE_PROTO_BPS = 7000;
    uint256 public constant VAULT_SPLIT_BPS = 8000;
    uint256 public constant XV0 = 30_000e6;
    uint256 public constant YV0 = 1_000_000e18;
    uint256 public constant LAUNCH_FEE = 50e6;
    uint256 public constant MIN_SEED = 500e6;
    uint256 public constant GRAD_VAULT = 250_000e6;
    uint256 public constant GRAD_AGE = 30 days;
    uint256 public constant SEED_LOCK = 30 days;
    uint256 public constant REDEEM_DELAY = 6 hours;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant REDEEM_GATE_BPS = 2000;
    uint256 public constant MIN_REDEEM_VALUE = 10e6; // $10 in 6-dec USDG (AUDIT S-4:
                                                     // real anti-dust floor; forceRaise
                                                     // makes a 1-cent floor too cheap
                                                     // to flood)
    uint256 public constant FORCE_RAISE_BUFFER_BPS = 500; // forceRaise may raise shortfall +5%
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    IERC20 public immutable quote;            // USDG
    AssetRegistry public immutable registry;
    ISpotVenue public immutable venue;
    address public immutable treasury;

    struct Ticker {
        TickerToken token;
        TraderVault vault;
        address creator;        // = the trader of the vault
        uint64 createdAt;
        bool graduated;
        uint256 xv;             // virtual quote reserve (6 dec)
        uint256 yv;             // virtual token reserve (18 dec)
        uint256 exitReserve;    // instant-sell liquidity held by the hub (6 dec)
        uint256 creatorFees;
        uint256 seedQty;
        uint256 seedUnlock;
        uint256 epochId;
        uint256 epochRedeemed;
        uint256 queueHead;
        uint256 queueTail;
    }

    struct Redemption {
        address who;
        uint256 qty;
        uint64 settleAt;
    }

    // internal + struct getter: the 16-field auto-getter is stack-too-deep
    Ticker[] internal tickers;
    mapping(uint256 => mapping(uint256 => Redemption)) public queue;
    mapping(bytes32 => bool) public symbolTaken;
    uint256 public protoFees;

    // ---------- events ----------
    event Launched(uint256 indexed id, address indexed creator, address token, address vault, string symbol, uint256 seedUsd, uint256 seedQty);
    event Bought(uint256 indexed id, address indexed who, uint256 usdIn, uint256 tokensOut, bool navMint);
    event Sold(uint256 indexed id, address indexed who, uint256 qty, uint256 proceeds);
    event Queued(uint256 indexed id, address indexed who, uint256 qty, uint256 index, uint64 settleAt);
    event Settled(uint256 indexed id, address indexed who, uint256 qty, uint256 paid, bool partialFill);
    event ForceRaised(uint256 indexed id, address indexed asset, uint256 amountIn, uint256 quoteOut);
    event SeedClaimed(uint256 indexed id, address indexed creator, uint256 qty);
    event Graduated(uint256 indexed id);

    // ---------- errors ----------
    error BadAmount();
    error SymbolTaken();
    error SeedTooSmall();
    error Slippage();
    error WouldQueue();
    error NotCreator();
    error SeedLocked();
    error NothingToSettle();
    error NotTreasury();
    error Reentered();
    error DustRedemption();
    error NoShortfall();
    error RaiseTooLarge(uint256 value, uint256 allowed);
    error StaleForMint();

    uint256 private _lock = 1;
    modifier nonReentrant() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(AssetRegistry _registry, ISpotVenue _venue, address _treasury) {
        registry = _registry;
        venue = _venue;
        treasury = _treasury;
        quote = _registry.quote();
    }

    // ---------- views ----------

    function tickerCount() external view returns (uint256) { return tickers.length; }

    function getTicker(uint256 id) external view returns (Ticker memory) { return tickers[id]; }

    /// @notice circulating supply: everything minted, incl. escrowed seed and
    ///         queued-but-unsettled redemptions
    function circ(uint256 id) public view returns (uint256) {
        return tickers[id].token.totalSupply();
    }

    /// @notice NAV in quote units (6 dec) per whole token (1e18). Reverts while
    ///         any needed Chainlink feed is stale - trading halts, funds sit.
    function nav(uint256 id) public view returns (uint256) {
        uint256 c = circ(id);
        if (c == 0) return 0;
        return tickers[id].vault.totalValueInQuote() * WAD / c;
    }

    function price(uint256 id) public view returns (uint256) {
        Ticker storage t = tickers[id];
        return t.xv * WAD / t.yv;
    }

    function feeBps(uint256 id) public view returns (uint256) {
        return tickers[id].graduated ? GRAD_FEE_BPS : CURVE_FEE_BPS;
    }

    function quoteBuy(uint256 id, uint256 usdIn) public view returns (uint256 out, uint256 fee, bool navMint) {
        Ticker storage t = tickers[id];
        fee = usdIn * feeBps(id) / BPS;
        uint256 net = usdIn - fee;
        uint256 curveOut = t.yv - (t.xv * t.yv) / (t.xv + net);
        uint256 n = nav(id);
        if (n > 0 && (curveOut == 0 || net * WAD / curveOut < n)) {
            return (net * WAD / n, fee, true); // buy-side floor
        }
        return (curveOut, fee, false);
    }

    function quoteSell(uint256 id, uint256 qty) public view returns (uint256 proceeds, uint256 fee, bool floorRouted) {
        Ticker storage t = tickers[id];
        uint256 gross = t.xv - (t.xv * t.yv) / (t.yv + qty);
        fee = gross * feeBps(id) / BPS;
        proceeds = gross - fee;
        uint256 n = nav(id);
        floorRouted = (proceeds * WAD / qty < n) || (gross > t.exitReserve);
    }

    // ---------- launch ----------

    /// @notice msg.sender becomes both creator and the vault's trader
    function launch(string calldata name_, string calldata symbol_, uint256 seedUsd)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (seedUsd < MIN_SEED) revert SeedTooSmall();
        {
            bytes32 symKey = keccak256(bytes(symbol_));
            if (symbolTaken[symKey]) revert SymbolTaken();
            symbolTaken[symKey] = true;
        }
        address(quote).safeTransferFrom(msg.sender, address(this), LAUNCH_FEE + seedUsd);
        protoFees += LAUNCH_FEE;

        id = _createTicker(name_, symbol_);
        (uint256 out,) = _executeBuy(id, seedUsd, address(this));
        Ticker storage t = tickers[id];
        t.seedQty = out;
        t.seedUnlock = block.timestamp + SEED_LOCK;

        emit Launched(id, msg.sender, address(t.token), address(t.vault), symbol_, seedUsd, out);
    }

    function _createTicker(string calldata name_, string calldata symbol_) internal returns (uint256 id) {
        id = tickers.length;
        tickers.push();
        Ticker storage t = tickers[id];
        t.token = new TickerToken(name_, symbol_);
        t.vault = new TraderVault(msg.sender, registry, venue);
        t.creator = msg.sender;
        t.createdAt = uint64(block.timestamp);
        t.xv = XV0;
        t.yv = YV0;
    }

    function claimSeed(uint256 id) external nonReentrant {
        Ticker storage t = tickers[id];
        if (msg.sender != t.creator) revert NotCreator();
        if (block.timestamp < t.seedUnlock) revert SeedLocked();
        uint256 qty = t.seedQty;
        if (qty == 0) revert BadAmount();
        t.seedQty = 0;
        t.token.transfer(msg.sender, qty);
        emit SeedClaimed(id, msg.sender, qty);
    }

    // ---------- trade ----------

    function buy(uint256 id, uint256 usdIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (usdIn == 0) revert BadAmount();
        address(quote).safeTransferFrom(msg.sender, address(this), usdIn);
        bool navMint;
        (out, navMint) = _executeBuy(id, usdIn, msg.sender);
        if (out < minOut) revert Slippage();
        emit Bought(id, msg.sender, usdIn, out, navMint);
    }

    function _executeBuy(uint256 id, uint256 usdIn, address to) internal returns (uint256 out, bool navMint) {
        Ticker storage t = tickers[id];
        uint256 fee;
        (out, fee, navMint) = quoteBuy(id, usdIn);
        // AUDIT E-1/E-2: an at-NAV mint against a stale (weekend/holiday/post-
        // sequencer-outage) mark lets an arber mint cheap and capture existing
        // holders' gap. Block below-NAV mints unless the vault's feeds are mint-
        // fresh. Above-NAV curve buys stay open (they carry a premium, no theft).
        if (navMint && !t.vault.mintFresh()) revert StaleForMint();
        uint256 net = usdIn - fee;
        uint256 proto = fee * FEE_PROTO_BPS / BPS;
        protoFees += proto;
        t.creatorFees += fee - proto;
        uint256 toVault;
        if (navMint) {
            // below-NAV buys back every minted token with its full NAV - existing
            // holders are never diluted
            toVault = net;
        } else {
            toVault = net * VAULT_SPLIT_BPS / BPS;
            t.exitReserve += net - toVault;
        }
        if (toVault > 0) address(quote).safeTransfer(address(t.vault), toVault);
        t.xv += net;
        t.yv -= out;
        t.token.mint(to, out);
        _checkGraduation(id);
    }

    function sell(uint256 id, uint256 qty, uint256 minProceeds, bool allowQueue)
        external
        nonReentrant
        returns (uint256 proceeds, bool queued)
    {
        if (qty == 0) revert BadAmount();
        Ticker storage t = tickers[id];
        (uint256 net, uint256 fee, bool floorRouted) = quoteSell(id, qty);
        if (floorRouted) {
            if (!allowQueue) revert WouldQueue();
            _enqueue(id, qty);
            return (0, true);
        }
        uint256 gross = net + fee;
        t.token.burn(msg.sender, qty);
        t.xv -= gross;
        t.yv += qty;
        t.exitReserve -= gross;
        uint256 proto = fee * FEE_PROTO_BPS / BPS;
        protoFees += proto;
        t.creatorFees += fee - proto;
        if (net < minProceeds) revert Slippage();
        address(quote).safeTransfer(msg.sender, net);
        emit Sold(id, msg.sender, qty, net);
        return (net, false);
    }

    /// @notice direct NAV redemption - the explicit floor
    function redeem(uint256 id, uint256 qty) external nonReentrant {
        if (qty == 0) revert BadAmount();
        _enqueue(id, qty);
    }

    function _enqueue(uint256 id, uint256 qty) internal {
        Ticker storage t = tickers[id];
        // anti dust-stuffing: a redemption must be worth >= MIN_REDEEM_VALUE
        if (qty * nav(id) / WAD < MIN_REDEEM_VALUE) revert DustRedemption();
        t.token.transferFrom(msg.sender, address(this), qty);
        uint256 idx = t.queueTail++;
        uint64 settleAt = uint64(block.timestamp + REDEEM_DELAY);
        queue[id][idx] = Redemption({who: msg.sender, qty: qty, settleAt: settleAt});
        emit Queued(id, msg.sender, qty, idx, settleAt);
    }

    /// @notice epoch-gate headroom (18-dec token qty) for the current epoch
    function gateRemaining(uint256 id) public view returns (uint256) {
        Ticker storage t = tickers[id];
        uint256 epochNow = (block.timestamp - t.createdAt) / EPOCH;
        uint256 redeemed = epochNow == t.epochId ? t.epochRedeemed : 0;
        uint256 gateTotal = circ(id) * REDEEM_GATE_BPS / BPS;
        return gateTotal > redeemed ? gateTotal - redeemed : 0;
    }

    /// @notice public crank: settle up to maxN due redemptions, FIFO. Fills are
    ///         bounded by (a) the 20%-of-circ epoch gate and (b) the vault's
    ///         instant QUOTE liquidity - a partial fill rolls and the crank stops.
    function settleQueue(uint256 id, uint256 maxN) external nonReentrant returns (uint256 settled) {
        Ticker storage t = tickers[id];
        uint256 epochNow = (block.timestamp - t.createdAt) / EPOCH;
        if (epochNow != t.epochId) {
            t.epochId = epochNow;
            t.epochRedeemed = 0;
        }
        for (uint256 i = 0; i < maxN && t.queueHead < t.queueTail; i++) {
            (bool didSettle, bool stop) = _settleOne(id, t);
            if (didSettle) settled++;
            if (stop) break;
        }
        if (settled == 0) revert NothingToSettle();
    }

    /// @dev settle the queue head against gate + vault quote liquidity.
    ///      Returns (didSettle, stop): stop ends the crank loop.
    function _settleOne(uint256 id, Ticker storage t) internal returns (bool, bool) {
        Redemption storage r = queue[id][t.queueHead];
        if (r.settleAt > block.timestamp) return (false, true);

        // hoist circ once: nav() would otherwise re-read totalSupply (~10k gas/iter)
        uint256 c = circ(id);
        uint256 fill;
        {
            uint256 gateTotal = c * REDEEM_GATE_BPS / BPS;
            uint256 remaining = gateTotal > t.epochRedeemed ? gateTotal - t.epochRedeemed : 0;
            if (remaining == 0) return (false, true);
            fill = r.qty < remaining ? r.qty : remaining;
        }
        uint256 n = c == 0 ? 0 : t.vault.totalValueInQuote() * WAD / c;
        uint256 pay;
        if (n > 0) {
            // vault quote liquidity bounds how much qty can settle right now
            uint256 liqFill = quote.balanceOf(address(t.vault)) * WAD / n;
            if (liqFill < fill) fill = liqFill;
            if (fill == 0) return (false, true); // starving - crank forceRaise first
            pay = fill * n / WAD;
        }
        // n == 0: vault fully wiped, redemption burns for nothing (pay 0)

        t.epochRedeemed += fill;
        t.token.burn(address(this), fill);
        bool partialFill = fill < r.qty;
        address who = r.who;
        if (partialFill) {
            r.qty -= fill;
        } else {
            delete queue[id][t.queueHead];
            t.queueHead++;
        }
        if (pay > 0) {
            t.vault.payOut(pay);
            address(quote).safeTransfer(who, pay);
        }
        emit Settled(id, who, fill, pay, partialFill);
        return (true, partialFill); // gate/liquidity exhausted ends the crank
    }

    /// @notice permissionless liquidity crank: when a due redemption cannot be
    ///         paid from the vault's quote balance, force-sell just enough of a
    ///         vault asset (oracle-bounded) to cover the shortfall.
    function forceRaise(uint256 id, address asset, uint256 amountIn, uint24 poolFee)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        Ticker storage t = tickers[id];
        uint256 shortfall = _dueShortfall(id, t);
        if (shortfall == 0) revert NoShortfall();

        uint256 value = registry.valueInQuote(asset, amountIn);
        uint256 allowed = shortfall * (BPS + FORCE_RAISE_BUFFER_BPS) / BPS;
        if (value > allowed) revert RaiseTooLarge(value, allowed);

        quoteOut = t.vault.forceSell(asset, amountIn, poolFee);
        emit ForceRaised(id, asset, amountIn, quoteOut);
    }

    /// @dev quote shortfall to pay the due queue head at current NAV, 0 if none
    function _dueShortfall(uint256 id, Ticker storage t) internal view returns (uint256) {
        if (t.queueHead >= t.queueTail) return 0;
        Redemption storage r = queue[id][t.queueHead];
        if (r.settleAt > block.timestamp) return 0;
        uint256 remaining = gateRemaining(id);
        uint256 fill = r.qty < remaining ? r.qty : remaining;
        uint256 needed = fill * nav(id) / WAD;
        uint256 liquid = quote.balanceOf(address(t.vault));
        return needed > liquid ? needed - liquid : 0;
    }

    // ---------- fees ----------

    function claimCreatorFees(uint256 id) external nonReentrant returns (uint256 amt) {
        Ticker storage t = tickers[id];
        if (msg.sender != t.creator) revert NotCreator();
        amt = t.creatorFees;
        t.creatorFees = 0;
        if (amt > 0) address(quote).safeTransfer(msg.sender, amt);
    }

    function withdrawProtocolFees() external nonReentrant returns (uint256 amt) {
        if (msg.sender != treasury) revert NotTreasury();
        amt = protoFees;
        protoFees = 0;
        if (amt > 0) address(quote).safeTransfer(treasury, amt);
    }

    // ---------- graduation ----------

    /// @notice permissionless graduation re-check (e.g. after vault PnL gains).
    ///         nonReentrant as defense-in-depth: it's the only mutating entrypoint
    ///         a (hypothetical future) stock-token transfer hook could reach mid-swap.
    function poke(uint256 id) external nonReentrant {
        _checkGraduation(id);
    }

    function _checkGraduation(uint256 id) internal {
        Ticker storage t = tickers[id];
        if (!t.graduated && block.timestamp - t.createdAt >= GRAD_AGE && t.vault.totalValueInQuote() >= GRAD_VAULT) {
            t.graduated = true;
            emit Graduated(id);
        }
    }
}
