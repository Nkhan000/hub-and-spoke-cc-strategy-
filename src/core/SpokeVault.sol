// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract SpokeVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    // ERROR
    error SpokeVault__AmountMustBeMoreThanZero();
    // EVENTS
    event DepositSuccessfull(address lp, uint256 amount);
    // STATE VARIABLES
    mapping(address => uint256) private lpBalances;
    uint256 constant MIN_DEPOSIT = 3 * 10 ** 18;
    address private hubVault;
    // uint256 private bufferAmount;
    // uint256 private minBuffer;
    // uint256 private maxBuffer;
    uint256 private totalDeposits;

    EnumerableSet.AddressSet private allLiquidityProviders;

    modifier notZeroAmount(uint256 amount) {
        require(amount > 0, SpokeVault__AmountMustBeMoreThanZero());
        _;
    }
    constructor(
        IERC20 asset
    ) ERC4626(asset) ERC20("Cross Token", "CT") Ownable(msg.sender) {}

    function addLpProvider(address _lp) external {}
    function removeLpProvider(address _lp) external {}

    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        notZeroAmount(assets)
        returns (uint256)
    {
        uint256 shares = super.deposit(assets, receiver);
        unchecked {
            lpBalances[msg.sender] += assets;
            totalDeposits += assets;
        }

        emit DepositSuccessfull(msg.sender, assets);
        return shares;
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
