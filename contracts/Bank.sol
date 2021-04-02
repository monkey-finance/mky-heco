pragma solidity ^0.5.16;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/IBankConfig.sol";
import "./interfaces/InterestModel.sol";
import "./interfaces/Goblin.sol";
import "./SafeToken.sol";
import "./PTokenFactory.sol";

contract Bank is PTokenFactory, Ownable, ReentrancyGuard {
    using SafeToken for address;
    using SafeMath for uint256;

    event OpPosition(uint256 indexed id, uint256 debt, uint back);
    event Liquidate(uint256 indexed id, address indexed killer, uint256 prize, uint256 left);

    struct TokenBank {
        address tokenAddr;          //  原来的token合约地址，比如ht
        address pTokenAddr;         //  各种ptoken合约地址，比如pht
        bool isOpen;                //  默认为0，表示不存在
        bool canDeposit;
        bool canWithdraw;
        uint256 totalVal;
        uint256 totalDebt;
        uint256 totalDebtShare;
        uint256 totalReserve;
        uint256 lastInterestTime;
    }

    // todo: 字段意思还不太明确
    struct Production {
        address coinToken;
        address currencyToken;
        address borrowToken;            // 借的token
        bool isOpen;
        bool canBorrow;
        address goblin;
        uint256 minDebt;
        uint256 openFactor;
        uint256 liquidateFactor;
    }

    struct Position {
        address owner;
        uint256 productionId;
        uint256 debtShare;              // 债务份额
    }

    IBankConfig config;

    /// 和homora不同，有多个bank
    mapping(address => TokenBank) public banks;

    mapping(uint256 => Production) public productions;
    uint256 public currentPid = 1;

    mapping(uint256 => Position) public positions;
    uint256 public currentPos = 1;

    /// @dev Require that the caller must be an EOA account to avoid flash loans.
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "not eoa");
        _;
    }

    constructor() public {}

    /// read
    function positionInfo(uint256 posId) public view returns (uint256, uint256, uint256, address) {
        Position storage pos = positions[posId];
        Production storage prod = productions[pos.productionId];

        return (pos.productionId, Goblin(prod.goblin).health(posId, prod.borrowToken),
            debtShareToVal(prod.borrowToken, pos.debtShare), pos.owner);
    }

    function totalToken(address token) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        uint balance = token == address(0)? address(this).balance: SafeToken.myBalance(token);
        balance = bank.totalVal < balance? bank.totalVal: balance;

        return balance.add(bank.totalDebt).sub(bank.totalReserve);
    }

    function debtShareToVal(address token, uint256 debtShare) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (bank.totalDebtShare == 0) return debtShare;
        return debtShare.mul(bank.totalDebt).div(bank.totalDebtShare);
    }


    function debtValToShare(address token, uint256 debtVal) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (bank.totalDebt == 0) return debtVal;
        return debtVal.mul(bank.totalDebtShare).div(bank.totalDebt);
    }


    /// write


    /// @dev 存款，返回ptoken
    /// @param tokens ptoken合约的地址
    /// @param amount 
    function deposit(address token, uint256 amount) external payable nonReentrant {
        TokenBank storage bank = banks[token];
        require(bank.isOpen && bank.canDeposit, 'Token not exist or cannot deposit');

        calInterest(token);

        if (token == address(0)) {
            //TODO: 直接打HT，看看banks什么时候设置的address(0)
            amount = msg.value;
        } else {
            SafeToken.safeTransferFrom(token, msg.sender, address(this), amount);
        }

        bank.totalVal = bank.totalVal.add(amount);
        uint256 total = totalToken(token).sub(amount);
        uint256 pTotal = PToken(bank.pTokenAddr).totalSupply();

        uint256 pAmount = (total == 0 || pTotal == 0) ? amount: amount.mul(pTotal).div(total);
        PToken(bank.pTokenAddr).mint(msg.sender, pAmount);
    }

    function withdraw(address token, uint256 pAmount) external nonReentrant {
        TokenBank storage bank = banks[token];
        require(bank.isOpen && bank.canWithdraw, 'Token not exist or cannot withdraw');

        calInterest(token);

        uint256 amount = pAmount.mul(totalToken(token)).div(PToken(bank.pTokenAddr).totalSupply());
        bank.totalVal = bank.totalVal.sub(amount);

        PToken(bank.pTokenAddr).burn(msg.sender, pAmount);

        if (token == address(0)) {//HT
            SafeToken.safeTransferETH(msg.sender, amount);
        } else {
            SafeToken.safeTransfer(token, msg.sender, amount);
        }
    }

    function opPosition(uint256 posId, uint256 pid, uint256 borrow, bytes calldata data)
    external payable onlyEOA nonReentrant {

        if (posId == 0) {
            posId = currentPos;
            currentPos ++;
            positions[posId].owner = msg.sender;
            positions[posId].productionId = pid;

        } else {
            require(posId < currentPos, "bad position id");
            require(positions[posId].owner == msg.sender, "not position owner");

            pid = positions[posId].productionId;
        }

        Production storage production = productions[pid];
        require(production.isOpen, 'Production not exists');

        require(borrow == 0 || production.canBorrow, "Production can not borrow");
        calInterest(production.borrowToken);

        uint256 debt = _removeDebt(positions[posId], production).add(borrow);
        bool isBorrowHt = production.borrowToken == address(0);

        uint256 sendHT = msg.value;
        uint256 beforeToken = 0;
        if (isBorrowHt) {
            sendHT = sendHT.add(borrow);
            require(sendHT <= address(this).balance && debt <= banks[production.borrowToken].totalVal, "insufficient HT in the bank");
            beforeToken = address(this).balance.sub(sendHT);

        } else {
            beforeToken = SafeToken.myBalance(production.borrowToken);
            require(borrow <= beforeToken && debt <= banks[production.borrowToken].totalVal, "insufficient borrowToken in the bank");
            beforeToken = beforeToken.sub(borrow);
            SafeToken.safeApprove(production.borrowToken, production.goblin, borrow);
        }

        Goblin(production.goblin).work.value(sendHT)(posId, msg.sender, production.borrowToken, borrow, debt, data);

        uint256 backToken = isBorrowHt? (address(this).balance.sub(beforeToken)) :
            SafeToken.myBalance(production.borrowToken).sub(beforeToken);

        if(backToken > debt) { //没有借款, 有剩余退款
            backToken = backToken.sub(debt);
            debt = 0;

            isBorrowHt? SafeToken.safeTransferETH(msg.sender, backToken):
                SafeToken.safeTransfer(production.borrowToken, msg.sender, backToken);

        } else if (debt > backToken) { //有借款
            debt = debt.sub(backToken);
            backToken = 0;

            require(debt >= production.minDebt, "too small debt size");
            uint256 health = Goblin(production.goblin).health(posId, production.borrowToken);
            require(health.mul(production.openFactor) >= debt.mul(10000), "bad work factor");

            _addDebt(positions[posId], production, debt);
        }
        emit OpPosition(posId, debt, backToken);
    }

    function liquidate(uint256 posId) external payable onlyEOA nonReentrant {
        Position storage pos = positions[posId];
        require(pos.debtShare > 0, "no debt");
        Production storage production = productions[pos.productionId];

        uint256 debt = _removeDebt(pos, production);

        uint256 health = Goblin(production.goblin).health(posId, production.borrowToken);
        require(health.mul(production.liquidateFactor) < debt.mul(10000), "can't liquidate");

        bool isHT = production.borrowToken == address(0);
        uint256 before = isHT? address(this).balance: SafeToken.myBalance(production.borrowToken);

        Goblin(production.goblin).liquidate(posId, pos.owner, production.borrowToken);

        uint256 back = isHT? address(this).balance: SafeToken.myBalance(production.borrowToken);
        back = back.sub(before);

        uint256 prize = back.mul(config.getLiquidateBps()).div(10000);
        uint256 rest = back.sub(prize);
        uint256 left = 0;

        if (prize > 0) {
            isHT? SafeToken.safeTransferETH(msg.sender, prize): SafeToken.safeTransfer(production.borrowToken, msg.sender, prize);
        }
        if (rest > debt) {
            left = rest.sub(debt);
            isHT? SafeToken.safeTransferETH(pos.owner, left): SafeToken.safeTransfer(production.borrowToken, pos.owner, left);
        } else {
            banks[production.borrowToken].totalVal = banks[production.borrowToken].totalVal.sub(debt).add(rest);
        }
        emit Liquidate(posId, msg.sender, prize, left);
    }

    function _addDebt(Position storage pos, Production storage production, uint256 debtVal) internal {
        if (debtVal == 0) {
            return;
        }

        TokenBank storage bank = banks[production.borrowToken];

        uint256 debtShare = debtValToShare(production.borrowToken, debtVal);
        pos.debtShare = pos.debtShare.add(debtShare);

        bank.totalVal = bank.totalVal.sub(debtVal);
        bank.totalDebtShare = bank.totalDebtShare.add(debtShare);
        bank.totalDebt = bank.totalDebt.add(debtVal);
    }

    function _removeDebt(Position storage pos, Production storage production) internal returns (uint256) {
        TokenBank storage bank = banks[production.borrowToken];

        uint256 debtShare = pos.debtShare;
        if (debtShare > 0) {
            uint256 debtVal = debtShareToVal(production.borrowToken, debtShare);
            pos.debtShare = 0;

            bank.totalVal = bank.totalVal.add(debtVal);
            bank.totalDebtShare = bank.totalDebtShare.sub(debtShare);
            bank.totalDebt = bank.totalDebt.sub(debtVal);
            return debtVal;
        } else {
            return 0;
        }
    }

    function updateConfig(IBankConfig _config) external onlyOwner {
        config = _config;
    }

    function addToken(address token, string calldata _symbol) external onlyOwner {
        TokenBank storage bank = banks[token];
        require(!bank.isOpen, 'token already exists');

        bank.isOpen = true;
        address pToken = genPToken(_symbol);
        bank.tokenAddr = token;
        bank.pTokenAddr = pToken;
        bank.canDeposit = true;
        bank.canWithdraw = true;
        bank.totalVal = 0;
        bank.totalDebt = 0;
        bank.totalDebtShare = 0;
        bank.totalReserve = 0;
        bank.lastInterestTime = now;
    }

    function updateToken(address token, bool canDeposit, bool canWithdraw) external onlyOwner {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        bank.canDeposit = canDeposit;
        bank.canWithdraw = canWithdraw;
    }

    function opProduction(uint256 pid, bool isOpen, bool canBorrow,
        address coinToken, address currencyToken, address borrowToken, address goblin,
        uint256 minDebt, uint256 openFactor, uint256 liquidateFactor) external onlyOwner {

        if(pid == 0){
            pid = currentPid;
            currentPid ++;
        } else {
            require(pid < currentPid, "bad production id");
        }

        Production storage production = productions[pid];
        production.isOpen = isOpen;
        production.canBorrow = canBorrow;
        // 地址一旦设置, 就不要再改, 可以添加新币对!
        production.coinToken = coinToken;
        production.currencyToken = currencyToken;
        production.borrowToken = borrowToken;
        production.goblin = goblin;

        production.minDebt = minDebt;
        production.openFactor = openFactor;
        production.liquidateFactor = liquidateFactor;
    }

    function calInterest(address token) public {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (now > bank.lastInterestTime) {
            uint256 timePast = now.sub(bank.lastInterestTime);
            uint256 totalDebt = bank.totalDebt;
            uint256 totalBalance = totalToken(token);

            uint256 ratePerSec = config.getInterestRate(totalDebt, totalBalance);
            uint256 interest = ratePerSec.mul(timePast).mul(totalDebt).div(1e18);

            uint256 toReserve = interest.mul(config.getReserveBps()).div(10000);
            bank.totalReserve = bank.totalReserve.add(toReserve);
            bank.totalDebt = bank.totalDebt.add(interest);
            bank.lastInterestTime = now;
        }
    }

    function withdrawReserve(address token, address to, uint256 value) external onlyOwner nonReentrant {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        uint balance = token == address(0)? address(this).balance: SafeToken.myBalance(token);
        if(balance >= bank.totalVal.add(value)) {
            //非deposit存入
        } else {
            bank.totalReserve = bank.totalReserve.sub(value);
            bank.totalVal = bank.totalVal.sub(value);
        }

        if (token == address(0)) {
            SafeToken.safeTransferETH(to, value);
        } else {
            SafeToken.safeTransfer(token, to, value);
        }
    }

    function() external payable {}
}
