// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FeeStaking} from "../src/token/FeeStaking.sol";
import {FeeDistributor, IFeeStaking} from "../src/token/FeeDistributor.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {RhMainnet} from "../src/Addresses.sol";

/// Deploys the $TICK fee-sharing layer AFTER the token exists (e.g. launched on
/// NOXA). Point it at the launched TICK address; it wires FeeStaking (stake TICK
/// -> earn USDG) + FeeDistributor (splits protocol fees stakers/team).
///
///   TICK=0x<launched token> TEAM=0x<team multisig> STAKE_BPS=7000 \
///   forge script script/DeployStaking.s.sol \
///     --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast --account rh
///
/// USDG defaults to canonical Robinhood-Chain USDG; override with USDG=0x... on a
/// chain/testnet where it differs.
contract DeployStaking is Script {
    function run() external {
        address tick = vm.envAddress("TICK");                 // launched TICK token
        address usdg = vm.envOr("USDG", RhMainnet.USDG);      // reward token
        address team = vm.envOr("TEAM", msg.sender);          // fee-split recipient
        uint256 stakeBps = vm.envOr("STAKE_BPS", uint256(7000)); // 70% to stakers

        require(tick != address(0), "set TICK to the launched token address");

        vm.startBroadcast();
        FeeStaking staking = new FeeStaking(IERC20(tick), IERC20(usdg));
        FeeDistributor dist = new FeeDistributor(
            IERC20(usdg), IFeeStaking(address(staking)), team, stakeBps
        );
        vm.stopBroadcast();

        console2.log("=== $TICK fee layer ===");
        console2.log("TICK (staked): ", tick);
        console2.log("FeeStaking:    ", address(staking));
        console2.log("FeeDistributor:", address(dist));
        console2.log("team:          ", team);
        console2.log("stakeBps:      ", stakeBps);
        console2.log("");
        console2.log("Next: route protocol fees to the distributor -> anyone cranks distribute().");
        console2.log("Paste FeeStaking + TICK into web/config.js to light up the Stake page.");
    }
}
