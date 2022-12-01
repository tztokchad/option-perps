// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract USDC is ERC20PresetMinterPauser("USD Coin", "USDC") {
    constructor() {
        _mint(address(msg.sender), 10000000000000 * 10**6);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function approve(address spender, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }
}