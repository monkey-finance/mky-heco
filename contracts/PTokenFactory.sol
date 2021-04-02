
pragma solidity ^0.5.16;

import "./PToken.sol";

contract PTokenFactory {

    function genPToken(string memory _symbol) public returns(address) {
        return address(new PToken(_symbol));
    }
}