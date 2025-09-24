// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {ERC4626} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
// import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
// import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
// import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

contract CrossToken is ERC20 {
    constructor() ERC20("CrossToken", "CT") {}

    function mint() public {
        _mint(msg.sender, 1_000_000 * 10 * decimals());
    }
}
