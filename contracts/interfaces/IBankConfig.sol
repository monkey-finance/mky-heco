
pragma solidity ^0.5.16;

interface IBankConfig {

    /*
    A unit that is equal to 1/100th of 1%, and is used to denote the change in a financial instrument.
    The basis point is commonly used for calculating changes in interest rates, equity indexes and the yield of a fixed-income security. 
    The relationship between percentage changes and basis points can be summarized as follows: 
    1% change = 100 basis points, and  0.01% = 1 basis point. 
    So, a bond whose yield increases from 5% to 5.5% is said to increase by 50 basis points; 
    or interest rates that have risen 1% are said to have increased by 100 basis points.
    */

    /// @dev Return the interest rate per second, using 1e18 as denom.
    function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);

    /// @dev 返回储备池的bps利率。
    function getReserveBps() external view returns (uint256);

    function getLiquidateBps() external view returns (uint256);
}