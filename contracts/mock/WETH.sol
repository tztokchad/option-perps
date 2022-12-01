// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract WETH is ERC20PresetMinterPauser("Wrapped Ether", "WETH") {
    constructor() {
        _mint(address(msg.sender), 100_000_000_000 ether);
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