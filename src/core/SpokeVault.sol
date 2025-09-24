// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

contract SpokeVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    // ERROR

    // EVENTS

    // STATE VARIABLES
    mapping(address => uint256) private lpBalances;
    address private hubVault;
    uint256 private bufferAmount;
    uint256 private minBuffer;
    uint256 private maxBuffer;
    uint256 private totalDeposits;

    constructor(
        IERC20 asset
    ) ERC4626(asset) ERC20("Cross Token", "CT") Ownable(msg.sender) {}

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver
    ) external nonReentrant whenNotPaused {}

    // CROSS-CHAIN -> HUB VAULT
    function sendDepositsToHub() public {}

    function receiveWithdrawalFromHub() public {}

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ADMIN FUNCTION
    function setRouter() public {} // updates cross - chain router

    function setBufferSize() public {}
}
