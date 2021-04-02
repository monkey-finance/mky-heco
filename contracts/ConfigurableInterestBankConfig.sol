pragma solidity 0.5.16;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import './BankConfig.sol';
import './GoblinConfig.sol';

contract ConfigurableInterestBankConfig is BankConfig, Ownable {
  /// The minimum BNB debt size per position.
  uint public minDebtSize;
  /// The portion of interests allocated to the reserve pool.
  uint public getReservePoolBps;
  /// The reward for successfully killing a position.
  uint public getKillBps;
  /// Mapping for goblin address to its configuration.
  mapping(address => GoblinConfig) public goblins;
  /// Interest rate model
  InterestModel public interestModel;

  constructor(
    uint _minDebtSize,
    uint _reservePoolBps,
    uint _killBps,
    InterestModel _interestModel
  ) public {
    setParams(_minDebtSize, _reservePoolBps, _killBps, _interestModel);
  }

  /// @dev Set all the basic parameters. Must only be called by the owner.
  /// @param _minDebtSize The new minimum debt size value.
  /// @param _reservePoolBps The new interests allocated to the reserve pool value.
  /// @param _killBps The new reward for killing a position value.
  /// @param _interestModel The new interest rate model contract.
  function setParams(
    uint _minDebtSize,
    uint _reservePoolBps,
    uint _killBps,
    InterestModel _interestModel
  ) public onlyOwner {
    minDebtSize = _minDebtSize;
    getReservePoolBps = _reservePoolBps;
    getKillBps = _killBps;
    interestModel = _interestModel;
  }

  /// @dev Set the configuration for the given goblins. Must only be called by the owner.
  function setGoblins(address[] calldata addrs, GoblinConfig[] calldata configs)
    external
    onlyOwner
  {
    require(addrs.length == configs.length, 'bad length');
    for (uint idx = 0; idx < addrs.length; idx++) {
      goblins[addrs[idx]] = configs[idx];
    }
  }

  /// @dev Return the interest rate per second, using 1e18 as denom.
  function getInterestRate(uint debt, uint floating) external view returns (uint) {
    return interestModel.getInterestRate(debt, floating);
  }

  /// @dev Return whether the given address is a goblin.
  function isGoblin(address goblin) external view returns (bool) {
    return address(goblins[goblin]) != address(0);
  }

  /// @dev Return whether the given goblin accepts more debt. Revert on non-goblin.
  function acceptDebt(address goblin) external view returns (bool) {
    return goblins[goblin].acceptDebt(goblin);
  }

  /// @dev Return the work factor for the goblin + BNB debt, using 1e4 as denom. Revert on non-goblin.
  function workFactor(address goblin, uint debt) external view returns (uint) {
    return goblins[goblin].workFactor(goblin, debt);
  }

  /// @dev Return the kill factor for the goblin + BNB debt, using 1e4 as denom. Revert on non-goblin.
  function killFactor(address goblin, uint debt) external view returns (uint) {
    return goblins[goblin].killFactor(goblin, debt);
  }
}