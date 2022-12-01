// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract MockVolatilityOracle {
    function getVolatility(uint _strike) external pure returns (uint256) {
        return 100;
    }
}
