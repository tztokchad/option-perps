// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract MockOptionPricing {
    function getOptionPrice(
        bool,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256) {
        return 5e8; // 5$
    }
}
