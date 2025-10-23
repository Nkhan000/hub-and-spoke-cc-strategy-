// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault} from "./Vault.sol";
// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

// import {IStrategy} from "../strategies/IStrategy.sol";
// import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

// import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
// import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
// import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
// import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults, use the funds in the different strategies to yield profits
 */

contract HubVault is Vault {
    constructor(
        address _weth,
        address _usdc,
        address _wethUsdFeed,
        address _usdcUsdFeed
    ) Vault(_weth, _usdc, _wethUsdFeed, _usdcUsdFeed) {
        //
    }
}

// function receiveDeposit(address spoke, uint256 weth, uint256 usdc, uint256 depositValueUsd) external onlySpoke;
// function sendProfitToSpokes() external onlyStrategy;
// function investToStrategy() external onlyOwnerOrAutomation;
// function harvestProfit() external onlyAutomation;
