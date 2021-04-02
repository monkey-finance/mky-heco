pragma solidity ^0.5.16;

interface IHecoPool {
    function deposit(uint256 pid, uint256 amount) external;

    function withdraw(uint256 pid, uint256 amount) external;
}
