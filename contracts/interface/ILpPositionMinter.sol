//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "./IERC20.sol";

interface ILpPositionMinter is IERC20 {
    function mintFromOptionPerp(address receiver, uint256 amount) external;

     function burn(uint256 amount) external;
}