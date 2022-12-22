// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract MockPriceOracle {
    uint lastPrice = 1000 * 10 ** 8;

    function getUnderlyingPrice() external returns (uint256) {
        return lastPrice;
    }

    function updateUnderlyingPrice(uint price) external {
        lastPrice = price;
    }
}
