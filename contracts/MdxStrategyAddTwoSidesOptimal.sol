pragma solidity 0.5.16;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v2-core/contracts/libraries/Math.sol";
import "./SafeToken.sol";
import "./interfaces/Strategy.sol";
import "./interfaces/IWHT.sol";
import "./interfaces/IMdexPair.sol";
import "./interfaces/IMdexRouter.sol";
import "./interfaces/IMdexFactory.sol";
import "./interfaces/ISwapMining.sol";

contract MdxStrategyAddTwoSidesOptimal is Ownable, ReentrancyGuard, Strategy {
    using SafeToken for address;
    using SafeMath for uint256;

    IMdexFactory public factory;
    IMdexRouter public router;
    address public wht;
    address public goblin;

    /// @dev Create a new add two-side optimal strategy instance for mdx.
    /// @param _router The mdx router smart contract.
    /// @param _goblin The goblin can execute the smart contract.
    constructor(IMdexRouter _router, address _goblin) public {
        factory = IMdexFactory(_router.factory());
        router = _router;

        wht = _router.WHT();
        goblin = _goblin;
    }

    /// @dev Throws if called by any account other than the goblin.
    modifier onlyGoblin() {
        require(isGoblin(), "caller is not the goblin");
        _;
    }

    /// @dev Returns true if the caller is the current goblin.
    function isGoblin() public view returns (bool) {
        return msg.sender == goblin;
    }

    /// @dev Compute optimal deposit amount
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amonut of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function optimalDeposit(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB
    ) internal pure returns (uint256 swapAmt, bool isReversed) {
        if (amtA.mul(resB) >= amtB.mul(resA)) {
            swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
            isReversed = false;
        } else {
            swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
            isReversed = true;
        }
    }

    /// @dev Compute optimal deposit amount helper
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amonut of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function _optimalDepositA(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB
    ) internal pure returns (uint256) {
        require(amtA.mul(resB) >= amtB.mul(resA), "Reversed");

        uint256 a = 997;
        uint256 b = uint256(1997).mul(resA);
        uint256 _c = (amtA.mul(resB)).sub(amtB.mul(resA));
        uint256 c = _c.mul(1000).div(amtB.add(resB)).mul(resA);

        uint256 d = a.mul(c).mul(4);
        uint256 e = Math.sqrt(b.mul(b).add(d));

        uint256 numerator = e.sub(b);
        uint256 denominator = a.mul(2);

        return numerator.div(denominator);
    }

    /// @dev Execute worker strategy. Take LP tokens + debtToken. Return LP tokens.
    /// @param user User address
    /// @param borrowToken The token user borrow from bank.
    /// @param borrow The amount user borrow from bank.
    /// @param data Extra calldata information passed along to this strategy.
    function execute(address user, address borrowToken, uint256 borrow, uint256 /* debt */, bytes calldata data)
        external
        payable
        onlyGoblin
        nonReentrant
    {
        address token0;
        address token1;
        uint256 minLPAmount;
        {
            // 1. decode token and amount info, and transfer to contract.
            (address _token0, address _token1, uint256 token0Amount, uint256 token1Amount, uint256 _minLPAmount) =
                abi.decode(data, (address, address, uint256, uint256, uint256));
            token0 = _token0;
            token1 = _token1;
            minLPAmount = _minLPAmount;

            require(borrowToken == token0 || borrowToken == token1, "borrowToken not token0 and token1");
            if (token0Amount > 0 && _token0 != address(0)) {
                token0.safeTransferFrom(user, address(this), token0Amount);
            }
            if (token1Amount > 0 && token1 != address(0)) {
                token1.safeTransferFrom(user, address(this), token1Amount);
            }
        }

        address htRelative = address(0);
        {
            if (borrow > 0 && borrowToken != address(0)) {
                borrowToken.safeTransferFrom(msg.sender, address(this), borrow);
            }
            if (token0 == address(0)){
                token0 = wht;
                htRelative = token1;
            }
            if (token1 == address(0)){
                token1 = wht;
                htRelative = token0;
            }

            // change all ht to WHT if need.
            uint256 htBalance = address(this).balance;
            if (htBalance > 0) {
                IWHT(wht).deposit.value(htBalance)();
            }
        }
        // tokens are all ERC20 token now.

        IMdexPair lpToken = IMdexPair(factory.getPair(token0, token1));
        token0 = lpToken.token0();
        token1 = lpToken.token1();
        // 2. Compute the optimal amount of token0 and token1 to be converted.
        address tokenRelative;
        {
            borrowToken = borrowToken == address(0) ? wht : borrowToken;
            tokenRelative = borrowToken == token0 ? token1 : token0;

            borrowToken.safeApprove(address(router), 0);
            borrowToken.safeApprove(address(router), uint256(-1));

            tokenRelative.safeApprove(address(router), 0);
            tokenRelative.safeApprove(address(router), uint256(-1));

            // 3. swap and mint LP tokens.
            calAndSwap(lpToken, borrowToken, tokenRelative);

            (,, uint256 moreLPAmount) = router.addLiquidity(token0, token1, token0.myBalance(), token1.myBalance(), 0, 0, address(this), now);
            require(moreLPAmount >= minLPAmount, "insufficient LP tokens received");
        }

        // 4. send lpToken and borrowToken back to the sender.
        lpToken.transfer(msg.sender, lpToken.balanceOf(address(this)));

        if (htRelative == address(0)) {
            borrowToken.safeTransfer(msg.sender, borrowToken.myBalance());
            tokenRelative.safeTransfer(user, tokenRelative.myBalance());
        } else {
            safeUnWrapperAndAllSend(borrowToken, msg.sender);
            safeUnWrapperAndAllSend(tokenRelative, user);
        }
    }

    /// get token balance, if is WHT un wrapper to HT and send to 'to'
    function safeUnWrapperAndAllSend(address token, address to) internal {
        uint256 total = SafeToken.myBalance(token);
        if (total > 0) {
            if (token == wht) {
                IWHT(wht).withdraw(total);
                SafeToken.safeTransferETH(to, total);
            } else {
                SafeToken.safeTransfer(token, to, total);
            }
        }
    }

    /// Compute amount and swap between borrowToken and tokenRelative.
    function calAndSwap(IMdexPair lpToken, address borrowToken, address tokenRelative) internal {
        (uint256 token0Reserve, uint256 token1Reserve,) = lpToken.getReserves();
        (uint256 debtReserve, uint256 relativeReserve) = borrowToken ==
            lpToken.token0() ? (token0Reserve, token1Reserve) : (token1Reserve, token0Reserve);
        (uint256 swapAmt, bool isReversed) = optimalDeposit(borrowToken.myBalance(), tokenRelative.myBalance(),
            debtReserve, relativeReserve);

        if (swapAmt > 0){
            address[] memory path = new address[](2);
            (path[0], path[1]) = isReversed ? (tokenRelative, borrowToken) : (borrowToken, tokenRelative);
            router.swapExactTokensForTokens(swapAmt, 0, path, address(this), now);
        }
    }

    /// @param minter The address of MDex SwapMining contract.
    /// @param pid pid of pair in SwapMining config.
    function getSwapReward(address minter, uint256 pid) public view returns (uint256, uint256) {
        ISwapMining swapMining = ISwapMining(minter);
        return swapMining.getUserReward(pid);
    }

    /// @param minter The address of MDex SwapMining contract.
    /// @param token Token of reward. Result of pairOfPid(lpTokenAddress)
    function swapMiningReward(address minter, address token) external onlyOwner{
        ISwapMining swapMining = ISwapMining(minter);
        swapMining.takerWithdraw();
        token.safeTransfer(msg.sender, token.myBalance());
    }

    /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOwner nonReentrant {
        token.safeTransfer(to, value);
    }

    function() external payable {}
}
