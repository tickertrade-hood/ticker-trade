// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ILighterRelayer — the ONLY on-chain surface of Lighter a contract can use.
/// @notice Per Lighter's docs (verified 2026-07-09): a smart contract CANNOT place
///         orders — order/cancel/modify are off-chain signed messages sent to the
///         sequencer by an API-key holder. The only on-chain calls in the trade
///         path are collateral deposit and withdraw against the Lighter Relayer,
///         and Lighter binds withdrawals to the depositing L1 address. This
///         interface captures exactly that minimal surface (real ABI TBD — the
///         relayer address is not yet published on Robinhood Chain).
interface ILighterRelayer {
    /// @notice escrow `amount` of the quote token from msg.sender into Lighter.
    function deposit(uint256 amount) external;

    /// @notice withdraw `amount` back — Lighter releases ONLY to the address that
    ///         deposited (withdrawal-address binding). Async in production; the
    ///         prototype relayer settles synchronously for testability.
    function withdraw(uint256 amount) external;

    /// @notice on-chain-readable escrowed collateral for `account` (does NOT include
    ///         unrealized position PnL, which lives in the off-chain L2 state).
    function collateralOf(address account) external view returns (uint256);
}
