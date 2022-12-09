// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IGmxRouter {
    function swap(
        address[] memory path,
        uint256 _amountIn,
        uint256 _minOut,
        address _receiver
    ) external;
}