// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {RhTickerHub} from "../src/RhTickerHub.sol";
import {TickerLens} from "../src/TickerLens.sol";
import {UniswapV3SpotVenue} from "../src/venues/UniswapV3SpotVenue.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ISpotVenue} from "../src/interfaces/ISpotVenue.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {RhMainnet} from "../src/Addresses.sol";

/// Deploys the immutable AssetRegistry (USDG quote + AAPL/TSLA/NVDA/SPY/QQQ) and
/// the RhTickerHub on Robinhood Chain mainnet (4663).
///
/// Usage (dry run):
///   forge script script/Deploy.s.sol --rpc-url robinhood
/// Broadcast:
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast \
///     --private-key $PK
///
/// TREASURY must be a multisig (no admin surface exists in the hub, but the
/// treasury is the protocol-fee sink — keep it off a hot EOA).
contract Deploy is Script {
    // stock feeds idle over weekends/holidays -> generous NAV-valuation bound;
    // the tighter MINT_FRESH gate (in TraderVault) stops stale-mark minting.
    uint48 constant STALE_STOCK = 96 hours;
    uint48 constant STALE_QUOTE = 26 hours;

    function run() external {
        require(block.chainid == RhMainnet.CHAIN_ID, "wrong chain: expected Robinhood 4663");
        // AUDIT R5 (3.1): treasury is IMMUTABLE in the hub — never let it silently
        // default to a hot deployer EOA on mainnet. Must be set explicitly.
        require(vm.envExists("TREASURY"), "set TREASURY to a multisig before mainnet");
        address treasury = vm.envAddress("TREASURY");
        require(treasury != address(0) && treasury != msg.sender, "TREASURY must be a multisig, not the deployer");

        // WETH (index 0) is the one asset with real liquidity today — tradeable at
        // launch. The 5 stocks are pre-listed (immutable registry) and activate when
        // their pools fill; swapping into an empty-pool stock reverts harmlessly.
        address[] memory assets = new address[](6);
        assets[0] = RhMainnet.WETH;
        assets[1] = RhMainnet.AAPLx;
        assets[2] = RhMainnet.TSLAx;
        assets[3] = RhMainnet.NVDAx;
        assets[4] = RhMainnet.SPYx;
        assets[5] = RhMainnet.QQQx;

        IAggregatorV3[] memory feeds = new IAggregatorV3[](6);
        feeds[0] = IAggregatorV3(RhMainnet.WETH_USD);
        feeds[1] = IAggregatorV3(RhMainnet.AAPL_USD);
        feeds[2] = IAggregatorV3(RhMainnet.TSLA_USD);
        feeds[3] = IAggregatorV3(RhMainnet.NVDA_USD);
        feeds[4] = IAggregatorV3(RhMainnet.SPY_USD);
        feeds[5] = IAggregatorV3(RhMainnet.QQQ_USD);

        uint48[] memory stales = new uint48[](6);
        bool[] memory hasMul = new bool[](6);
        stales[0] = STALE_QUOTE; hasMul[0] = false;     // WETH: crypto feed, no uiMultiplier
        for (uint256 i = 1; i < 6; i++) { stales[i] = STALE_STOCK; hasMul[i] = true; }

        vm.startBroadcast();

        AssetRegistry registry = new AssetRegistry(
            IERC20(RhMainnet.USDG),
            IAggregatorV3(RhMainnet.USDG_USD),
            STALE_QUOTE,
            assets, feeds, stales, hasMul
        );

        // wrap the Uniswap v3 router in a venue adapter. NOTE (AUDIT round 3): the
        // stock/USDG pools are empty on mainnet today, so this venue will revert on
        // stock swaps until liquidity exists or the venue is re-pointed. The vault
        // is venue-agnostic — deploy a different ISpotVenue here when a liquid spot
        // venue (1inch/Arcus/Rialto) is confirmed.
        UniswapV3SpotVenue venue = new UniswapV3SpotVenue(ISwapRouter02(RhMainnet.SWAP_ROUTER_02));

        RhTickerHub hub = new RhTickerHub(registry, ISpotVenue(address(venue)), treasury);

        TickerLens lens = new TickerLens(hub);

        vm.stopBroadcast();

        console2.log("AssetRegistry:", address(registry));
        console2.log("SpotVenue:    ", address(venue));
        console2.log("RhTickerHub:  ", address(hub));
        console2.log("TickerLens:   ", address(lens));
        console2.log("treasury:     ", treasury);
        console2.log("quote (USDG):  ", address(registry.quote()));
    }
}
