// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ILighterRelayer} from "../interfaces/ILighterRelayer.sol";
import {SafeTransfer} from "../SafeTransfer.sol";

/// @title MarginSleeve — OPTIONAL, CAPPED async hedge sleeve for a Lighter-style
///        (off-chain-orderbook, keeper-signed) venue.
/// @notice Lighter cannot be a synchronous swap adapter (contracts can't sign
///         orders; stock markets are perps; position value isn't on-chain — see
///         LIGHTER-ADAPTER.md). Any integration therefore reintroduces an
///         off-chain keeper and a non-atomic deposit→trade→settle→withdraw loop.
///         This sleeve quarantines that trust so it can never touch the trustless
///         spot core. THE INVARIANTS, enforced here:
///
///         1. The keeper (trader's off-chain signer) can NEVER receive funds.
///            No function transfers the quote token to the keeper. Withdrawals
///            come back from the relayer to THIS sleeve (Lighter binds the
///            withdrawal address), and only the owner (the vault/hub) can sweep
///            realized funds out — to the owner, never the keeper.
///         2. REDEEMABLE value counts ONLY realized on-chain quote (idle in the
///            sleeve + escrowed collateral the relayer reports), NEVER the keeper's
///            reported open-position equity. So a compromised keeper reporting a
///            fake equity number cannot cause over-redemption / a drain.
///         3. The keeper's reported equity is display-only and additionally
///            bounded by a staleness window and a max-deviation circuit breaker vs
///            escrowed collateral, so even the display can't show an absurd number.
///
///         Net keeper power: it can LOSE up to the sleeve's capital via bad Lighter
///         trades (bounded by how much the owner funds the sleeve — meant to be a
///         small cap, e.g. <=20% of vault), but it can never steal to itself and
///         never inflate what holders can redeem. Same "trade, never extract"
///         property as the spot vault, enforced structurally.
contract MarginSleeve {
    using SafeTransfer for address;

    uint256 public constant EQUITY_MAX_AGE = 1 hours;   // reported equity staleness
    uint256 public constant EQUITY_MAX_DEVIATION_BPS = 5000; // report within ±50% of collateral
    uint256 private constant BPS = 10_000;

    address public immutable owner;    // the vault/hub — the ONLY address funds sweep to
    address public immutable keeper;   // trader's off-chain signer — reports equity only
    IERC20 public immutable quote;     // USDG
    ILighterRelayer public immutable relayer;

    uint256 public depositedNotional;  // cumulative net quote pushed into the relayer
    // NAMED "unsafe" on purpose (AUDIT S-4/S-7): this is the keeper's self-reported,
    // off-chain, DISPLAY-ONLY number. It is NEVER part of redeemableValue and MUST
    // NEVER be read into NAV by any consumer. A future hub that promotes it into a
    // floor silently defeats the no-inflation invariant.
    uint256 public displayEquityUnsafe;
    uint256 public reportedAt;

    event Funded(uint256 amount);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event SweptToOwner(uint256 amount);
    event EquityReported(uint256 equity, uint256 at);

    error NotOwner();
    error NotKeeper();
    error BadAmount();
    error DeviationTooLarge(uint256 equity, uint256 collateral);
    error BadConfig();
    error Reentered();

    uint256 private _lock = 1;
    modifier nonReentrant() { if (_lock != 1) revert Reentered(); _lock = 2; _; _lock = 1; }
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyKeeper() { if (msg.sender != keeper) revert NotKeeper(); _; }

    constructor(address _owner, address _keeper, IERC20 _quote, ILighterRelayer _relayer) {
        // AUDIT S-9: owner==keeper would hand the keeper sweepToOwner (extraction).
        if (_owner == address(0) || _keeper == address(0) || _owner == _keeper
            || address(_quote) == address(0) || address(_relayer) == address(0)) revert BadConfig();
        owner = _owner; keeper = _keeper; quote = _quote; relayer = _relayer;
    }

    // ---------- realized (redeemable) accounting ----------

    /// @notice idle quote sitting in this sleeve (already back from the venue)
    function idleQuote() public view returns (uint256) { return quote.balanceOf(address(this)); }

    /// @notice escrowed collateral the relayer reports on-chain for this sleeve
    ///         (excludes unrealized position PnL — that's off-chain)
    function escrowedCollateral() public view returns (uint256) { return relayer.collateralOf(address(this)); }

    /// @notice the ONLY value a NAV floor / redemption may count from this sleeve:
    ///         realized on-chain quote. Deliberately EXCLUDES `displayEquityUnsafe`,
    ///         so a lying keeper cannot make holders redeem money that isn't here.
    /// @dev    NOTE (AUDIT S-3): the `escrowedCollateral()` term trusts the Lighter
    ///         relayer's on-chain accounting — that is the irreducible trust of
    ///         using Lighter at all. Only `idleQuote()` is relayer-independent. A
    ///         consuming hub MUST cap this sleeve's contribution to NAV (e.g. ≤20%
    ///         of vault) so relayer risk is bounded, not open-ended.
    function redeemableValue() public view returns (uint256) {
        return idleQuote() + escrowedCollateral();
    }

    /// @notice true iff the keeper's reported equity is fresh (for display gating)
    function equityFresh() public view returns (bool) {
        return reportedAt != 0 && block.timestamp <= reportedAt + EQUITY_MAX_AGE;
    }

    // ---------- owner (vault) funds flow — funds only ever move owner<->sleeve ----------

    /// @notice owner tops up the sleeve's capital (its at-risk budget). Bounded by
    ///         the owner's own policy/cap; the sleeve doesn't mint trust.
    function fund(uint256 amount) external onlyOwner {
        address(quote).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    /// @notice owner pulls realized quote back out (e.g. to service redemptions).
    ///         Goes to the owner ONLY. Never to the keeper.
    function sweepToOwner(uint256 amount) external onlyOwner nonReentrant {
        if (amount > idleQuote()) revert BadAmount();
        address(quote).safeTransfer(owner, amount);
        emit SweptToOwner(amount);
    }

    // ---------- keeper venue ops — move collateral, never receive it ----------

    /// @notice keeper pushes idle quote into the Lighter relayer as margin. The
    ///         keeper then trades OFF-CHAIN with its API key (not on-chain here).
    function depositToVenue(uint256 amount) external onlyKeeper nonReentrant {
        if (amount > idleQuote()) revert BadAmount();
        address(quote).safeApprove(address(relayer), amount);
        relayer.deposit(amount);
        address(quote).safeApprove(address(relayer), 0);
        depositedNotional += amount;
        emit Deposited(amount);
    }

    /// @notice keeper OR owner requests collateral back from the relayer INTO this
    ///         sleeve. The relayer binds the destination to this sleeve — funds
    ///         cannot be diverted to the keeper. After this, only the owner can
    ///         sweep them. AUDIT R5 (M-1): the owner is included so a dark/passive
    ///         keeper cannot lock the vault's capital in the relayer forever.
    function withdrawFromVenue(uint256 amount) external nonReentrant {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        // AUDIT S-1/S-2: don't TRUST the relayer paid us — measure it. Decrement the
        // (informational) notional by funds that ACTUALLY landed in this sleeve, so a
        // diverting or async relayer can't silently corrupt the accounting.
        uint256 before = idleQuote();
        relayer.withdraw(amount); // real relayer binds destination to this sleeve
        uint256 received = idleQuote() - before;
        depositedNotional = received >= depositedNotional ? 0 : depositedNotional - received;
        emit Withdrawn(received);
    }

    /// @notice keeper reports the off-chain account value (position + collateral).
    ///         DISPLAY ONLY — never used for redemptions. Bounded by a deviation
    ///         circuit breaker vs on-chain escrowed collateral so it can't show an
    ///         absurd figure. A gain beyond the band means "withdraw realized funds
    ///         first, then it counts" — realization must be on-chain to be believed.
    function reportEquity(uint256 equity) external onlyKeeper {
        uint256 collat = escrowedCollateral();
        // equity must be within ±EQUITY_MAX_DEVIATION_BPS of escrowed collateral
        uint256 hi = collat + collat * EQUITY_MAX_DEVIATION_BPS / BPS;
        uint256 lo = collat - collat * EQUITY_MAX_DEVIATION_BPS / BPS;
        if (equity > hi || equity < lo) revert DeviationTooLarge(equity, collat);
        displayEquityUnsafe = equity;
        reportedAt = block.timestamp;
        emit EquityReported(equity, block.timestamp);
    }
}
