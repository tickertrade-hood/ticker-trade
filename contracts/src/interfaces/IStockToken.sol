// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice ERC-8056 surface of Robinhood stock tokens: `uiMultiplier` scales the
///         effective (economic) amount per raw balance unit to express splits and
///         stock dividends. 1e18 = 1:1. Raw `balanceOf` never rebases.
interface IStockToken {
    function uiMultiplier() external view returns (uint256);
}
