
pragma solidity ^0.5.16;

interface InterestModel {
    function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);
}
