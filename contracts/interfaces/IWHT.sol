
pragma solidity ^0.5.16;

interface IWHT {
    function balanceOf(address user) external returns (uint256);

    function approve(address to, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function deposit() external payable;

    function withdraw(uint256) external;
}