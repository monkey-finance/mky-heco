pragma solidity ^0.5.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/ILPStakingRewards.sol";
import "./interfaces/IHecoPool.sol";
import "./RewardsDistributionRecipient.sol";

contract LpStakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    address public operator;
    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public startTime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 7 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalRewards = 0;
    uint256 private rewardsNext = 0;
    uint256 public rewardsPaid = 0;
    uint256 public rewardsed = 0;
    uint256 private leftRewardTimes = 12;

    int public poolId;
    IHecoPool public pool;
    IERC20 public earnToken;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsDistribution,
        address _operator,
        address _rewardsToken,
        address _stakingToken,
        uint256 _rewardAmount,
        address _pool,
        int _poolId,
        address _earnToken,
        uint256 _startTime
    ) public {
        operator = _operator;
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution;
        totalRewards = _rewardAmount;
        pool = IHecoPool(_pool);
        poolId = _poolId;
        earnToken = IERC20(_earnToken);
        startTime = _startTime;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function stake(uint256 amount, address user) external nonReentrant updateReward(user) checkhalve checkStart checkOperator(user, msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(user != address(0), "user cannot be 0");
        address from = operator != address(0) ? operator : user;
        _totalSupply = _totalSupply.add(amount);
        _balances[user] = _balances[user].add(amount);
        stakingToken.safeTransferFrom(from, address(this), amount);
        if (address(pool) != address(0) && poolId >= 0) {
            stakingToken.safeApprove(address(pool), 0);
            stakingToken.safeApprove(address(pool), uint256(-1));
            pool.deposit(uint256(poolId), amount);
            emit StakedHecoPool(from, amount);
        }
        emit Staked(from, amount);
    }

    function withdraw(uint256 amount, address user) public nonReentrant updateReward(user) checkhalve checkStart checkOperator(user, msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(user != address(0), "user cannot be 0");
        require(_balances[user] >= amount, "not enough");
        address to = operator != address(0) ? operator : user;
        if (address(pool) != address(0) && poolId >= 0) {
            // withdraw lp token back
            pool.withdraw(uint256(poolId), amount);
            emit WithdrawnHecoPool(to, amount);
        }
        _totalSupply = _totalSupply.sub(amount);
        _balances[user] = _balances[user].sub(amount);
        stakingToken.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) checkhalve checkStart {
        require(msg.sender != address(0), "user cannot be 0");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsPaid = rewardsPaid.add(reward);
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function burn(uint256 amount) external onlyRewardsDistribution {
        leftRewardTimes = 0;
        rewardsNext = 0;
        rewardsToken.burn(address(this), amount);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier checkhalve(){
        if (block.timestamp >= periodFinish && leftRewardTimes > 0) {
            leftRewardTimes = leftRewardTimes.sub(1);
            uint256 reward = leftRewardTimes == 0 ? totalRewards.sub(rewardsed) : rewardsNext;
            rewardsToken.mint(address(this), reward);
            rewardsed = rewardsed.add(reward);
            rewardRate = reward.div(rewardsDuration);
            periodFinish = block.timestamp.add(rewardsDuration);
            rewardsNext = leftRewardTimes > 0 ? rewardsNext.mul(70).div(100) : 0;
            emit RewardAdded(reward);
        }
        _;
    }

    modifier checkStart(){
        require(block.timestamp > startTime,"not start");
        _;
    }

    modifier checkOperator(address user, address sender) {
        require((operator == address(0) && user == sender) || (operator != address(0) && operator == sender));
        _;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        require(rewardsed == 0, "reward already inited");
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }
        rewardsToken.mint(address(this),reward);
        rewardsed = reward;
        rewardsNext = rewardsed.mul(70).div(100);
        leftRewardTimes = leftRewardTimes.sub(1);
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function setOperator(address _operator) external onlyRewardsDistribution {
        operator = _operator;
    }

    function setPool(address _pool) external onlyRewardsDistribution {
        require(_pool != address(0) && address(pool) == address(0), 'pool can not be update');
        pool = IHecoPool(_pool);
        if (poolId >= 0) {
            stakingToken.safeApprove(address(pool), 0);
            stakingToken.safeApprove(address(pool), uint256(-1));
            pool.deposit(uint256(poolId), _totalSupply);
            emit StakedHecoPool(address(this), _totalSupply);
        }
    }

    function setPoolId(int _poolId) external onlyRewardsDistribution {
        require(_poolId >= 0 && poolId < 0, 'pool id can not be update');
        poolId = _poolId;
        if (address(pool) != address(0)) {
            stakingToken.safeApprove(address(pool), 0);
            stakingToken.safeApprove(address(pool), uint256(-1));
            pool.deposit(uint256(poolId), _totalSupply);
            emit StakedHecoPool(address(this), _totalSupply);
        }
    }

    function claim(address to) external onlyRewardsDistribution {
        uint256 amount = earnToken.balanceOf(address(this));
        earnToken.transfer(to, amount);
        emit Claim(to, amount);
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event StakedHecoPool(address indexed user, uint256 amount);
    event WithdrawnHecoPool(address indexed user, uint256 amount);
    event Claim(address indexed to, uint256 amount);
}
