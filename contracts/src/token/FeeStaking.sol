// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../SafeTransfer.sol";

/// @title FeeStaking — stake TICK, earn real USDG protocol fees, STREAMED over time.
/// @notice Rewards are NOT credited instantly on `fund` — they drip linearly over
///         REWARD_DURATION (Synthetix StakingRewards model). This is the robust
///         fix for the flash-stake sandwich (AUDIT round 5, CRITICAL): a staker
///         present for one block earns only ~rate*blocktime, so flash-borrowing
///         TICK to sandwich a distribution captures ~nothing. Real, sticky stakers
///         earn the stream; opportunists can't skim it.
///
///         No lockup on principal (unstake anytime), no admin over funds. `fund`
///         is permissionless (the FeeDistributor / treasury calls it). A staker can
///         never take more than their time-weighted accrued share.
contract FeeStaking {
    using SafeTransfer for address;

    uint256 public constant REWARD_DURATION = 7 days;
    uint256 private constant ACC = 1e18;

    IERC20 public immutable tick;   // staking token (18-dec)
    IERC20 public immutable usdg;   // reward token (6-dec)

    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    // streaming reward accounting
    uint256 public rewardRate;              // USDG per second (during a period)
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event Funded(uint256 amount, uint256 rate, uint256 periodFinish);

    error BadAmount();
    error TooSmall();
    error Reentered();

    uint256 private _lock = 1;
    modifier nonReentrant() { if (_lock != 1) revert Reentered(); _lock = 2; _; _lock = 1; }

    modifier updateReward(address user) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (user != address(0)) {
            rewards[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
        _;
    }

    constructor(IERC20 _tick, IERC20 _usdg) { tick = _tick; usdg = _usdg; }

    // ---------- views ----------

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * ACC / totalStaked;
    }

    /// @notice USDG earned by `user` so far (streamed, time-weighted)
    function earned(address user) public view returns (uint256) {
        return staked[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / ACC + rewards[user];
    }

    /// @notice current annualized reward rate in USDG/sec (for UI APR display)
    function pending(address user) external view returns (uint256) { return earned(user); }

    // ---------- fund (stream in protocol fees) ----------

    /// @notice push protocol fees; they stream to stakers over REWARD_DURATION. If
    ///         a period is active, the leftover is rolled into the new rate. Excess
    ///         accrued while nobody is staked is simply not distributed (the
    ///         FeeDistributor routes to the team when totalStaked==0).
    function fund(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (amount == 0) revert BadAmount();
        address(usdg).safeTransferFrom(msg.sender, address(this), amount);
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / REWARD_DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (amount + leftover) / REWARD_DURATION;
        }
        if (rewardRate == 0) revert TooSmall(); // fund at least REWARD_DURATION wei-USDG
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;
        emit Funded(amount, rewardRate, periodFinish);
    }

    // ---------- stake / unstake / claim ----------

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert BadAmount();
        address(tick).safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0 || amount > staked[msg.sender]) revert BadAmount();
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        address(tick).safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) returns (uint256 amt) {
        amt = rewards[msg.sender];
        if (amt > 0) {
            rewards[msg.sender] = 0;           // effects before interaction
            address(usdg).safeTransfer(msg.sender, amt);
            emit Claimed(msg.sender, amt);
        }
    }
}
