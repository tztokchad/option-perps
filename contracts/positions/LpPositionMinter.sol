// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract LpPositionMinter is Ownable, ERC20PresetMinterPauser {
    uint8 customDecimals;
    address public optionPerpContract;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20PresetMinterPauser(_name, _symbol) {
        customDecimals = _decimals;
    }

    function decimals() public view virtual override returns (uint8) {
        return customDecimals;
    }

    function setOptionPerpContract(address _optionPerpContract) public onlyOwner {
        optionPerpContract = _optionPerpContract;
    }

    function mintFromOptionPerp(address receiver, uint256 amount) public {
        require(
          msg.sender == optionPerpContract,
          "Only option perp contract can mint an option perp deposit token"
        );

        _mint(receiver, amount);
    }
}
