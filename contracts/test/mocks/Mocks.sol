// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISpotVenue} from "../../src/interfaces/ISpotVenue.sol";
import {ILighterRelayer} from "../../src/interfaces/ILighterRelayer.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// Mintable ERC20 with configurable decimals (USDG stand-in at 6 dec).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _dec) {
        name = _name; symbol = _symbol; decimals = _dec;
    }

    function mint(address to, uint256 amount) public virtual {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// Robinhood stock token stand-in: 18 dec, ERC-8056 uiMultiplier, issuer powers
/// (pause + adminBurn) so scenarios can simulate the real contract's admin risk.
contract MockStock is MockERC20 {
    uint256 public uiMultiplier = 1e18;
    bool public paused;

    constructor(string memory _name, string memory _symbol) MockERC20(_name, _symbol, 18) {}

    function setUiMultiplier(uint256 m) external { uiMultiplier = m; }
    function setPaused(bool p) external { paused = p; }

    function adminBurn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "stock: paused");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!paused, "stock: paused");
        return super.transferFrom(from, to, amount);
    }
}

/// Chainlink aggregator stand-in (8 dec by default).
contract MockFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 _dec, int256 _answer) {
        decimals = _dec;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setStale(uint256 _updatedAt) external { updatedAt = _updatedAt; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// ISpotVenue stand-in with infinite liquidity that executes at `execBps` of
/// Chainlink fair value (10000 = perfect fill, lower = hostile / manipulated
/// pool). Mocks at the true external boundary (the venue).
contract MockSpotVenue is ISpotVenue {
    AssetRegistry public reg;
    uint256 public execBps = 10_000;

    function setRegistry(AssetRegistry r) external { reg = r; }
    function setExecBps(uint256 b) external { execBps = b; }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24, address recipient)
        external returns (uint256 out)
    {
        require(MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "venue:in");
        uint256 valueQ = reg.valueInQuote(tokenIn, amountIn);
        uint256 fair = reg.amountFromQuote(tokenOut, valueQ);
        out = fair * execBps / 10_000;
        require(out >= minOut, "Too little received");
        MockERC20(tokenOut).mint(recipient, out);
    }
}

/// A venue that IGNORES minOut and delivers less than fair — used to prove the
/// vault's own post-swap balance-diff guard (SlippageVsOracle) catches a lying
/// venue, not just the mock's honesty.
contract LyingVenue is ISpotVenue {
    AssetRegistry public reg;
    uint256 public lieBps = 5_000; // deliver 50% of fair, ignoring minOut
    function setRegistry(AssetRegistry r) external { reg = r; }
    function setLieBps(uint256 b) external { lieBps = b; }
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, uint24, address recipient)
        external returns (uint256 out)
    {
        require(MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "venue:in");
        uint256 valueQ = reg.valueInQuote(tokenIn, amountIn);
        uint256 fair = reg.amountFromQuote(tokenOut, valueQ);
        out = fair * lieBps / 10_000; // deliberately ignore minOut
        MockERC20(tokenOut).mint(recipient, out);
    }
}

/// ERC20 whose transfer/transferFrom/approve return false — to exercise the
/// SafeTransfer library's failure branches.
contract BadERC20 {
    function decimals() external pure returns (uint8) { return 6; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return false; }
    function approve(address, uint256) external pure returns (bool) { return false; }
}

/// Lighter relayer stand-in: escrows the quote token, binds withdrawals to the
/// depositor, and lets a test simulate realized venue PnL (a winning/losing trade
/// changes how much collateral comes back) via `settlePnl`.
contract MockLighterRelayer is ILighterRelayer {
    IERC20 public immutable quote;
    mapping(address => uint256) public collateral;
    constructor(IERC20 _quote) { quote = _quote; }

    function deposit(uint256 amount) external {
        require(quote.transferFrom(msg.sender, address(this), amount), "relayer:in");
        collateral[msg.sender] += amount;
    }
    // withdrawal-address binding: funds go back ONLY to the caller (the sleeve)
    function withdraw(uint256 amount) external {
        collateral[msg.sender] -= amount;
        require(quote.transfer(msg.sender, amount), "relayer:out");
    }
    function collateralOf(address a) external view returns (uint256) { return collateral[a]; }

    // test-only: simulate off-chain realized PnL settling into on-chain collateral
    function settlePnl(address account, int256 pnl) external {
        if (pnl >= 0) {
            require(quote.transferFrom(msg.sender, address(this), uint256(pnl)), "pnl:in");
            collateral[account] += uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss > collateral[account]) loss = collateral[account];
            collateral[account] -= loss;
            require(quote.transfer(msg.sender, loss), "pnl:out");
        }
    }
}
