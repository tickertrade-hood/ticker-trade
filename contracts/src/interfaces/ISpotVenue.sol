// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ISpotVenue — venue-agnostic synchronous spot swap.
/// @notice The TraderVault used to call Uniswap's SwapRouter02 directly. That made
///         the protocol hostage to one DEX — and on Robinhood Chain the Uniswap
///         stock/USDG pools are empty (AUDIT round 3), so the vault could not
///         trade at all. This interface decouples the vault from any single venue:
///         a venue can wrap Uniswap v3, 1inch, Arcus, Rialto, an aggregator, or a
///         test mock. Whichever venue actually has liquidity gets plugged in at
///         deploy without touching the vault.
///
///         SECURITY: the venue is UNTRUSTED. The vault approves exactly `amountIn`,
///         calls `swapExactIn`, then measures the received amount by its own
///         balance diff and re-checks it against the Chainlink oracle bound. A
///         lying/hostile venue can at worst return less (rejected by the vault's
///         own SlippageVsOracle guard) — it can never pull more than the approval.
interface ISpotVenue {
    /// @notice swap `amountIn` of `tokenIn` for `tokenOut`, sending output to
    ///         `recipient`. The venue pulls `tokenIn` from msg.sender (the vault,
    ///         which has approved it) and must deliver >= `minOut` or revert.
    /// @param  poolFee venue-specific route hint (e.g. Uniswap v3 fee tier);
    ///         ignored by venues that don't need it.
    /// @return out amount of `tokenOut` delivered to `recipient`.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24 poolFee,
        address recipient
    ) external returns (uint256 out);
}
