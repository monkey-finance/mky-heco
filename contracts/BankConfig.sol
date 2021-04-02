
pragma solidity ^0.5.16;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "./interfaces/IBankConfig.sol";
import "./interfaces/InterestModel.sol";

contract BankConfig is IBankConfig, Ownable {

    uint256 public getReserveBps;
    uint256 public getLiquidateBps;
    InterestModel public interestModel;

    constructor() public {}

    function setParams(uint256 _getReserveBps, uint256 _getLiquidateBps, InterestModel _interestModel) public onlyOwner {
        getReserveBps = _getReserveBps;
        getLiquidateBps = _getLiquidateBps;
        interestModel = _interestModel;
    }

    function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256) {
        return interestModel.getInterestRate(debt, floating);
    }
}