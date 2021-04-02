pragma solidity ^0.5.16;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/Goblin.sol";
import "./interfaces/IMdexFactory.sol";
import "./interfaces/IMdexRouter.sol";
import "./interfaces/IMdexPair.sol";
import "./interfaces/ILPStakingRewards.sol";
import "./SafeToken.sol";
import "./interfaces/Strategy.sol";


contract MdxGoblin is Ownable, ReentrancyGuard, Goblin {
    /// @notice Libraries
    using SafeToken for address;
    using SafeMath for uint256;

    /// @notice Events
    event AddPosition(uint256 indexed id, uint256 lpAmount);
    event RemovePosition(uint256 indexed id, uint256 lpAmount);
    event Liquidate(uint256 indexed id, address lpTokenAddress, uint256 lpAmount, address debtToken, uint256 liqAmount);

    /// @notice Immutable variables
    IStakingRewards public staking;
    IMdexFactory public factory;
    IMdexRouter public router;
    IMdexPair public lpToken;
    address public wht;
    address public token0;
    address public token1;
    address public operator;

    /// @notice Mutable state variables
    mapping(uint256 => uint256) public posLPAmount;
    mapping(address => bool) public okStrategies;
    uint256 public totalLPAmount;
    Strategy public liqStrategy;

    constructor(
        address _operator,
        IStakingRewards _staking,
        IMdexRouter _router,
        address _token0,
        address _token1,
        Strategy _liqStrategy
    ) public {
        operator = _operator;
        wht = _router.WHT();
        staking = _staking;
        router = _router;
        factory = IMdexFactory(_router.factory());

        _token0 = _token0 == address(0) ? wht : _token0;
        _token1 = _token1 == address(0) ? wht : _token1;

        lpToken = IMdexPair(factory.getPair(_token0, _token1));
        token0 = lpToken.token0();
        token1 = lpToken.token1();

        liqStrategy = _liqStrategy;
        okStrategies[address(liqStrategy)] = true;

        // 100% trust in the staking pool
        lpToken.approve(address(_staking), uint256(-1));
    }

    /// @dev Require that the caller must be the operator (the bank).
    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    /// @dev Work on the given position. Must be called by the operator.
    /// @param id The position ID to work on.
    /// @param user The original user that is interacting with the operator.
    /// @param borrowToken The token user borrow from bank.
    /// @param borrow The amount user borrow form bank.
    /// @param debt The user's debt amount.
    /// @param data The encoded data, consisting of strategy address and bytes to strategy.
    function work(uint256 id, address user, address borrowToken, uint256 borrow, uint256 debt, bytes calldata data)
        external
        payable
        onlyOperator
        nonReentrant
    {
        require(borrowToken == token0 || borrowToken == token1 || borrowToken == address(0), "borrowToken not token0 and token1");

        // 1. Convert this position back to LP tokens.
        _removePosition(id, user);
        // 2. Perform the worker strategy; sending LP tokens + borrowToken; expecting LP tokens.
        (address strategy, bytes memory ext) = abi.decode(data, (address, bytes));
        require(okStrategies[strategy], "unapproved work strategy");

        lpToken.transfer(strategy, lpToken.balanceOf(address(this)));

        // transfer the borrow token.
        if (borrow > 0 && borrowToken != address(0)) {
            borrowToken.safeTransferFrom(msg.sender, address(this), borrow);

            borrowToken.safeApprove(address(strategy), 0);
            borrowToken.safeApprove(address(strategy), uint256(-1));
        }

        Strategy(strategy).execute.value(msg.value)(user, borrowToken, borrow, debt, ext);

        // 3. Add LP tokens back to the farming pool.
        _addPosition(id, user);

        if (borrowToken == address(0)) {
            SafeToken.safeTransferETH(msg.sender, address(this).balance);
        } else {
            uint256 borrowTokenAmount = borrowToken.myBalance();
            if(borrowTokenAmount > 0){
                SafeToken.safeTransfer(borrowToken, msg.sender, borrowTokenAmount);
            }
        }
    }

    /// @dev Return maximum output given the input amount and the status of Uniswap reserves.
    /// @param aIn The amount of asset to market sell.
    /// @param rIn the amount of asset in reserve for input.
    /// @param rOut The amount of asset in reserve for output.
    function getMktSellAmount(uint256 aIn, uint256 rIn, uint256 rOut) public pure returns (uint256) {
        if (aIn == 0) return 0;
        require(rIn > 0 && rOut > 0, "bad reserve values");
        uint256 aInWithFee = aIn.mul(997);
        uint256 numerator = aInWithFee.mul(rOut);
        uint256 denominator = rIn.mul(1000).add(aInWithFee);
        return numerator / denominator;
    }

    /// @dev Return the amount of debt token to receive if we are to liquidate the given position.
    /// @param id The position ID to perform health check.
    /// @param borrowToken The token this position had debt.
    function health(uint256 id, address borrowToken) external view returns (uint256) {
        bool isDebtHt = borrowToken == address(0);
        require(borrowToken == token0 || borrowToken == token1 || isDebtHt, "borrowToken not token0 and token1");

        // 1. Get the position's LP balance and LP total supply.
        uint256 lpBalance = posLPAmount[id];
        uint256 lpSupply = lpToken.totalSupply();
        // Ignore pending mintFee as it is insignificant
        // 2. Get the pool's total supply of token0 and token1.
        (uint256 totalAmount0, uint256 totalAmount1,) = lpToken.getReserves();

        // 3. Convert the position's LP tokens to the underlying assets.
        uint256 userToken0 = lpBalance.mul(totalAmount0).div(lpSupply);
        uint256 userToken1 = lpBalance.mul(totalAmount1).div(lpSupply);

        if (isDebtHt) {
            borrowToken = token0 == wht ? token0 : token1;
        }

        // 4. Convert all farming tokens to debtToken and return total amount.
        if (borrowToken == token0) {
            return getMktSellAmount(
                userToken1, totalAmount1.sub(userToken1), totalAmount0.sub(userToken0)
            ).add(userToken0);
        } else {
            return getMktSellAmount(
                userToken0, totalAmount0.sub(userToken0), totalAmount1.sub(userToken1)
            ).add(userToken1);
        }
    }

    /// @dev Liquidate the given position by converting it to debtToken and return back to caller.
    /// @param id The position ID to perform liquidation.
    /// @param user The address than this position belong to.
    /// @param borrowToken The token user borrow from bank.
    function liquidate(uint256 id, address user, address borrowToken)
        external
        onlyOperator
        nonReentrant
    {
        bool isBorrowHt = borrowToken == address(0);
        require(borrowToken == token0 || borrowToken == token1 || isBorrowHt, "borrowToken not token0 and token1");

        // 1. Convert the position back to LP tokens and use liquidate strategy.
        _removePosition(id, user);
        uint256 lpTokenAmount = lpToken.balanceOf(address(this));
        lpToken.transfer(address(liqStrategy), lpTokenAmount);
        liqStrategy.execute(address(0), borrowToken, uint256(0), uint256(0), abi.encode(address(lpToken)));

        // 2. transfer borrowToken and user want back to goblin.
        uint256 tokenLiquidate;
        if (isBorrowHt){
            tokenLiquidate = address(this).balance;
            SafeToken.safeTransferETH(msg.sender, tokenLiquidate);
        } else {
            tokenLiquidate = borrowToken.myBalance();
            borrowToken.safeTransfer(msg.sender, tokenLiquidate);
        }

        emit Liquidate(id, address(lpToken), lpTokenAmount, borrowToken, tokenLiquidate);
    }

    /// @dev Internal function to stake all outstanding LP tokens to the given position ID.
    function _addPosition(uint256 id, address user) internal {
        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance > 0) {
            // take lpToken to the pool2.
            staking.stake(lpBalance, user);
            totalLPAmount = totalLPAmount.add(lpBalance);
            posLPAmount[id] = posLPAmount[id].add(lpBalance);
            emit AddPosition(id, lpBalance);
        }
    }

    /// @dev Internal function to remove shares of the ID and convert to outstanding LP tokens.
    function _removePosition(uint256 id, address user) internal {
        uint256 lpAmount = posLPAmount[id];
        if (lpAmount > 0) {
            posLPAmount[id] = 0;
            totalLPAmount = totalLPAmount.sub(lpAmount);
            staking.withdraw(lpAmount, user);
            emit RemovePosition(id, lpAmount);
        }
    }

    /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOwner nonReentrant {
        token.safeTransfer(to, value);
    }

    /// @dev Set the given strategies' approval status.
    /// @param strategies The strategy addresses.
    /// @param isOk Whether to approve or unapprove the given strategies.
    function setStrategyOk(address[] calldata strategies, bool isOk) external onlyOwner {
        uint256 len = strategies.length;
        require(len < 10, "strategy too more");
        for (uint256 idx = 0; idx < len; idx++) {
            okStrategies[strategies[idx]] = isOk;
        }
    }

    /// @dev Update critical strategy smart contracts. EMERGENCY ONLY. Bad strategies can steal funds.
    /// @param _liqStrategy The new liquidate strategy contract.
    function setCriticalStrategies(Strategy _liqStrategy) external onlyOwner {
        liqStrategy = _liqStrategy;
    }

    function() external payable {}
}