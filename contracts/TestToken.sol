// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20, ERC20Permit {
    constructor() ERC20("TestToken", "TTK") ERC20Permit("TestToken") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }
} 