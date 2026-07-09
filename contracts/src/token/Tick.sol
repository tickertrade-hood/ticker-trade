// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title TICK — the protocol governance + fee-share token.
/// @notice Fixed supply, no mint after construction, no owner. This is a
///         value-accrual token (fee rights + governance), NOT a backed ticker —
///         so a fixed supply is correct here (unlike bonding-curve tickers).
///         Minimal ERC20 (permit-less); the full supply is minted once to the
///         deployer, who distributes per TOKENOMICS.md.
contract Tick {
    string public constant name = "Ticker";
    string public constant symbol = "TICK";
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 supply, address to) {
        totalSupply = supply;
        balanceOf[to] = supply;
        emit Transfer(address(0), to, supply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
