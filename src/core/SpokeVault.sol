// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault} from "./Vault.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
// import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
// import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
// import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
// import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
// import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
// import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
// import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";

contract SpokeVault is Vault {
    constructor(
        address _weth,
        address _usdc,
        address _wethUsdFeed,
        address _usdcUsdFeed
    ) Vault(_weth, _usdc, _wethUsdFeed, _usdcUsdFeed) {
        //
    }

    function deposit(uint256 _amountWeth, uint256 _amountUsdc) public override {
        _deposit(_amountWeth, _amountUsdc);
    }
}

//     function deposit(uint256 wethAmt, uint256 usdcAmt) external;
// function withdraw(uint256 shares) external;
// function ccipReceive(bytes memory data) external onlyCCIPRouter;
