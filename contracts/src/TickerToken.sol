// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title TickerToken - one ERC20 per launched trader ticker.
/// @notice Minimal ERC20; mint/burn restricted to the immutable TickerHub.
///         No owner, no pause, no upgrade - supply changes only through the
///         curve (buys mint, redemptions/curve-sells burn). AUDIT.md #9.
contract TickerToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    address public immutable hub;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotHub();

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        hub = msg.sender;
    }

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    function mint(address to, uint256 amount) external onlyHub {
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyHub {
        balanceOf[from] -= amount;
        unchecked { totalSupply -= amount; }
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
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
