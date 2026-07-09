// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice minimal safe ERC20 ops: succeed on no-return-value tokens, revert on
///         `false` or reverting calls (USDT-style tolerance).
library SafeTransfer {
    error TransferFailed(address token);
    error ApproveFailed(address token);

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed(token);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed(token);
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed(token);
    }
}
