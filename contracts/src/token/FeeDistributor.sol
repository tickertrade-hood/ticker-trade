// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../SafeTransfer.sol";

interface IFeeStaking {
    function fund(uint256 amount) external;
    function totalStaked() external view returns (uint256);
}

/// @title FeeDistributor — routes protocol USDG fees to stakers + team.
/// @notice Set the hub's immutable `treasury` to this contract; then anyone can
///         crank `distribute()`. It splits whatever USDG has arrived: `stakeBps`
///         to the staking contract (real yield to $TICK stakers), the rest to the
///         team/ecosystem address. The staker share is fixed at deploy and cannot
///         be redirected. If nobody is staked yet, the whole amount routes to the
///         team so fees are never stranded.
contract FeeDistributor {
    using SafeTransfer for address;

    uint256 private constant BPS = 10_000;

    IERC20 public immutable usdg;
    IFeeStaking public immutable staking;
    address public immutable team;
    uint256 public immutable stakeBps; // e.g. 7000 = 70% to stakers

    event Distributed(uint256 toStakers, uint256 toTeam);

    error BadConfig();
    error Nothing();

    constructor(IERC20 _usdg, IFeeStaking _staking, address _team, uint256 _stakeBps) {
        if (address(_usdg) == address(0) || address(_staking) == address(0) || _team == address(0) || _stakeBps > BPS) {
            revert BadConfig();
        }
        usdg = _usdg; staking = _staking; team = _team; stakeBps = _stakeBps;
    }

    /// @notice permissionless: split all USDG held here to stakers + team
    function distribute() external returns (uint256 toStakers, uint256 toTeam) {
        uint256 bal = usdg.balanceOf(address(this));
        if (bal == 0) revert Nothing();
        toStakers = bal * stakeBps / BPS;
        // if nobody is staked, the staker share would strand in the staking
        // contract with no owner — route everything to the team instead.
        if (staking.totalStaked() == 0) toStakers = 0;
        toTeam = bal - toStakers;

        if (toStakers > 0) {
            address(usdg).safeApprove(address(staking), toStakers);
            staking.fund(toStakers);
        }
        if (toTeam > 0) address(usdg).safeTransfer(team, toTeam);
        emit Distributed(toStakers, toTeam);
    }
}
