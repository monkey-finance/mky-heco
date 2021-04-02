pragma solidity ^0.5.16;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "./LpStakingRewards.sol";

contract LpStakingRewardsFactory is Ownable {
    // immutables
    address public rewardsToken;

    mapping(address => bool) public stakingRewards;

    constructor(
        address _rewardsToken
    ) Ownable() public {
        rewardsToken = _rewardsToken;
    }

    ///// permissioned functions

    // deploy a staking reward contract for the staking token, and store the total reward amount
    // hecoPoolId: set -1 if not stake lpToken to Heco
    function deploy(address operator, address stakingToken, uint rewardAmount, address pool, int poolId, address earnToken, uint256 startTime) public onlyOwner {
        address stakingReward = address(new LpStakingRewards(/*_rewardsDistribution=*/ address(this), operator, rewardsToken, stakingToken, rewardAmount, pool, poolId, earnToken, startTime));
        stakingRewards[stakingReward] = true;
    }

    // notify initial reward amount for an individual staking token.
    function notifyRewardAmount(address stakingReward, uint256 rewardAmount) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).notifyRewardAmount(rewardAmount);
    }

    function setOperator(address stakingReward, address operator) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).setOperator(operator);
    }

    function setPool(address stakingReward, address pool) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).setPool(pool);
    }

    function setPoolId(address stakingReward, int poolId) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).setPoolId(poolId);
    }

    function claim(address stakingReward, address to) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).claim(to);
    }

    function burn(address stakingReward, uint256 amount) public onlyOwner {
        require(stakingRewards[stakingReward], 'not exist');
        LpStakingRewards(stakingReward).burn(amount);
    }
}