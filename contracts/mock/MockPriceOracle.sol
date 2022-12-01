// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract MockPriceOracle {
    function getUnderlyingPrice() external pure returns (uint256) {
        return 1000 * 10 ** 8;
    }
}
