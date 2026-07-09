// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISpotVenue} from "../interfaces/ISpotVenue.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../SafeTransfer.sol";

/// @title UniswapV3SpotVenue — ISpotVenue over Uniswap v3 SwapRouter02.
/// @notice Stateless, immutable wrapper. Holds no funds between calls: it pulls
///         exactly `amountIn` from the caller, single-hop swaps, and the router
///         sends the output straight to `recipient`. No privileged role.
contract UniswapV3SpotVenue is ISpotVenue {
    using SafeTransfer for address;

    ISwapRouter02 public immutable router;

    error NoRouter();

    constructor(ISwapRouter02 _router) {
        if (address(_router) == address(0)) revert NoRouter();
        router = _router;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24 poolFee,
        address recipient
    ) external returns (uint256 out) {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.safeApprove(address(router), amountIn);
        out = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        tokenIn.safeApprove(address(router), 0);
    }
}
