// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title AssetRegistry - immutable price/whitelist registry for TICKER.TRADE on
///        Robinhood Chain.
/// @notice Fixed at deployment: the quote token (USDG) and the set of tradable
///         vault assets (tokenized stocks / ETFs / WETH), each mapped to its
///         Chainlink feed and a per-asset staleness bound. No owner, no setters -
///         adding an asset means deploying a new registry + hub (AUDIT #9
///         discipline: no god-key can repoint a feed).
///
///         Valuation rules:
///         - every asset is valued in QUOTE units via ASSET/USD and QUOTE/USD
///           feeds (so a USDG depeg reprices correctly instead of lying)
///         - stock tokens carry an ERC-8056 `uiMultiplier` (splits/dividends):
///           effective shares = raw balance * uiMultiplier / 1e18. Chainlink
///           prices the effective share, so the multiplier MUST be applied.
///         - stale/invalid feed -> revert. NAV consumers halt rather than trade
///           on a dead price. Stock feeds idle over weekends/holidays, so their
///           maxStale must cover that (e.g. 96h) while crypto feeds stay tight.
contract AssetRegistry {
    struct AssetCfg {
        IAggregatorV3 feed;   // ASSET/USD
        uint48 maxStale;      // seconds
        uint8 assetDecimals;
        uint8 feedDecimals;
        bool hasUiMultiplier; // ERC-8056 stock token
        bool listed;
    }

    IERC20 public immutable quote;             // USDG (6 dec on Robinhood Chain)
    IAggregatorV3 public immutable quoteFeed;  // USDG/USD
    uint48 public immutable quoteMaxStale;
    uint8 public immutable quoteDecimals;
    uint8 public immutable quoteFeedDecimals;

    address[] public assets;
    mapping(address => AssetCfg) public cfg;

    uint256 private constant ONE = 1e18;

    error LengthMismatch();
    error ZeroAddress();
    error DuplicateAsset();
    error NotListed(address asset);
    error StaleOracle(address feed, uint256 updatedAt);
    error BadOracleAnswer(address feed);
    error BadUiMultiplier(address asset);

    constructor(
        IERC20 _quote,
        IAggregatorV3 _quoteFeed,
        uint48 _quoteMaxStale,
        address[] memory _assets,
        IAggregatorV3[] memory _feeds,
        uint48[] memory _maxStales,
        bool[] memory _hasUiMultiplier
    ) {
        if (address(_quote) == address(0) || address(_quoteFeed) == address(0)) revert ZeroAddress();
        if (_assets.length != _feeds.length || _assets.length != _maxStales.length || _assets.length != _hasUiMultiplier.length) {
            revert LengthMismatch();
        }
        quote = _quote;
        quoteFeed = _quoteFeed;
        quoteMaxStale = _quoteMaxStale;
        quoteDecimals = _quote.decimals();
        quoteFeedDecimals = _quoteFeed.decimals();

        for (uint256 i = 0; i < _assets.length; i++) {
            address a = _assets[i];
            if (a == address(0) || address(_feeds[i]) == address(0)) revert ZeroAddress();
            if (a == address(_quote)) revert DuplicateAsset();
            if (cfg[a].listed) revert DuplicateAsset();
            cfg[a] = AssetCfg({
                feed: _feeds[i],
                maxStale: _maxStales[i],
                assetDecimals: IERC20(a).decimals(),
                feedDecimals: _feeds[i].decimals(),
                hasUiMultiplier: _hasUiMultiplier[i],
                listed: true
            });
            assets.push(a);
        }
    }

    // ---------- views ----------

    function assetCount() external view returns (uint256) { return assets.length; }
    function isListed(address asset) public view returns (bool) { return cfg[asset].listed; }

    /// @notice validated Chainlink read (positive answer, within maxStale)
    function _read(IAggregatorV3 feed, uint48 maxStale) internal view returns (uint256 px) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadOracleAnswer(address(feed));
        if (updatedAt == 0 || block.timestamp > updatedAt + maxStale) revert StaleOracle(address(feed), updatedAt);
        return uint256(answer);
    }

    function quotePriceUsd() public view returns (uint256 px, uint8 dec) {
        return (_read(quoteFeed, quoteMaxStale), quoteFeedDecimals);
    }

    /// @notice raw last-update timestamp of the quote feed (no staleness revert) —
    ///         lets consumers apply a TIGHTER freshness bound than NAV valuation
    ///         (e.g. gate at-NAV mints so a weekend-stale mark can't be minted at)
    function quoteUpdatedAt() external view returns (uint256) {
        (,,, uint256 updatedAt,) = quoteFeed.latestRoundData();
        return updatedAt;
    }

    function assetUpdatedAt(address asset) external view returns (uint256) {
        AssetCfg storage c = cfg[asset];
        if (!c.listed) revert NotListed(asset);
        (,,, uint256 updatedAt,) = c.feed.latestRoundData();
        return updatedAt;
    }

    function assetPriceUsd(address asset) public view returns (uint256 px, uint8 dec) {
        AssetCfg storage c = cfg[asset];
        if (!c.listed) revert NotListed(asset);
        return (_read(c.feed, c.maxStale), c.feedDecimals);
    }

    /// @notice value of `rawBal` of `asset` in quote token units (quoteDecimals)
    function valueInQuote(address asset, uint256 rawBal) public view returns (uint256) {
        if (rawBal == 0) return 0;
        if (asset == address(quote)) return rawBal;
        AssetCfg storage c = cfg[asset];
        if (!c.listed) revert NotListed(asset);

        uint256 effBal = rawBal;
        if (c.hasUiMultiplier) {
            effBal = rawBal * IStockToken(asset).uiMultiplier() / ONE;
        }
        uint256 pxA = _read(c.feed, c.maxStale);
        uint256 pxQ = _read(quoteFeed, quoteMaxStale);

        // quoteAmt = effBal * pxA * 10^(quoteDec + quoteFeedDec) / (10^(assetDec + feedDec) * pxQ)
        return effBal * pxA * (10 ** (quoteDecimals + quoteFeedDecimals))
            / (10 ** (c.assetDecimals + c.feedDecimals)) / pxQ;
    }

    /// @notice inverse: how many raw units of `asset` are worth `quoteAmt` quote units
    function amountFromQuote(address asset, uint256 quoteAmt) public view returns (uint256) {
        if (quoteAmt == 0) return 0;
        if (asset == address(quote)) return quoteAmt;
        AssetCfg storage c = cfg[asset];
        if (!c.listed) revert NotListed(asset);

        uint256 pxA = _read(c.feed, c.maxStale);
        uint256 pxQ = _read(quoteFeed, quoteMaxStale);

        uint256 effAmt = quoteAmt * pxQ * (10 ** (c.assetDecimals + c.feedDecimals))
            / (10 ** (quoteDecimals + quoteFeedDecimals)) / pxA;
        if (c.hasUiMultiplier) {
            uint256 mul = IStockToken(asset).uiMultiplier();
            if (mul == 0) revert BadUiMultiplier(asset); // AUDIT R5: clean revert, not a div-by-zero panic
            effAmt = effAmt * ONE / mul;
        }
        return effAmt;
    }
}
