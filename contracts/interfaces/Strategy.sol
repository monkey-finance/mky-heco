
pragma solidity ^0.5.16;

interface Strategy {

    /// @dev Execute worker strategy. Take LP tokens + debt token. Return LP tokens or debt token.
    /// @param user The original user that is interacting with the operator.
    /// @param borrowToken The token user want borrow.
    /// @param borrow The amount user borrow from bank.
    /// @param debt The user's total debt, for better decision making context.
    /// @param data Extra calldata information passed along to this strategy.
    /// @return token and amount need transfer back.
    function execute(address user, address borrowToken, uint256 borrow, uint256 debt, bytes calldata data) external payable;

}
