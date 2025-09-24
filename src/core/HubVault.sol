// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
interface IStrategy {
    function withdraw(uint256 amount) external returns (bool);
    function reportProfit() external returns (uint256);
    function withdrawAll() external returns (bool);
    // function get
}

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and use the funds in the different strategies to yield profits
 */

contract HubVault is ERC4626, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 constant PERFORMANCE_FEE = 100;
    uint256 constant MIN_PROFIT = 20e18;
    uint256 private totalAllocations;
    uint256 private totalFeesCollected;

    // maps all allocations to the strategy
    mapping(address => uint256) internal strategyAllocations;
    // maps all the profits from the strategy
    mapping(address => uint256) internal strategyProfits;
    //
    mapping(address => bool) internal isAllowedStrategy;

    // ERRORS
    error HubVault__AmountMustBeMoreThanZero();
    error HubVault__FundsAllocationFailed();
    error HubVault__StrategyNotAllowed(address strategy);
    error HubVault__EmergencyWithdrawalFailed(address strategy);

    /// EVENTS
    event StrategyAdded(address _strategy);
    event StrategyFundsAllocated(address strategy, uint256 amount);
    event StrategyFundsWithdrawn(address strategy, uint256 amount);
    event ProfitsCollected(address strategy, uint256 profit, uint256 amount);
    event FeesCollected(address to, uint256 amount);
    event EmergencyWithdrawal(address strategy, uint256 amount);

    // CONSTRUCTOR
    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Cross Token", "CT") Ownable(msg.sender) {
        // asset = _asset;
    }

    /////////////// modifiers
    modifier allowedStrategy(address strategy) {
        require(
            isAllowedStrategy[strategy],
            HubVault__StrategyNotAllowed(strategy)
        );
        _;
    }

    modifier notZeroAmount(uint256 amount) {
        require(amount > 0, HubVault__AmountMustBeMoreThanZero());
        _;
    }

    //////////////////////////////////
    /////// STRATEGY MANAGEMENT /////
    ////////////////////////////////

    // add strategies like Uniswap or AAVE
    function addStrategy(address _strategy) external onlyOwner nonReentrant {
        require(!isAllowedStrategy[_strategy], "Strategy already listed");

        isAllowedStrategy[_strategy] = true;
        emit StrategyAdded(_strategy);
    }

    function allocateFundsToStrategy(
        address strategy,
        uint256 amount
    ) public onlyOwner whenNotPaused nonReentrant allowedStrategy(strategy) {
        // CHECKS
        require(
            amount <= IERC20(asset()).balanceOf(address(this)),
            "Insufficient funds in the vault"
        );

        // AFFECTS
        unchecked {
            strategyAllocations[strategy] += amount;
            totalAllocations += amount;
        }
        // INTERACTION
        bool success = IERC20(asset()).transfer(strategy, amount);
        require(success, HubVault__FundsAllocationFailed());

        emit StrategyFundsAllocated(strategy, amount);
    }

    // it assumes that strategy contract has allowed to transfer funds to this contract
    function withdrawFromStrategy(
        address strategy,
        uint256 amount
    ) external onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        require(
            strategyAllocations[strategy] >= amount,
            "Not enough allocated"
        );
        uint256 totalAllocated = strategyAllocations[strategy];
        require(totalAllocated > 0, "Strategy has no funds");

        // @audit when withdrawing from the strategy we must settle all the on the ongoing swaps or maybe cancel them. and make sure all the profits generated all gets accounted to this contract

        // In case of emergency withdraw
        if (amount == type(uint256).max) {
            strategyAllocations[strategy] = 0;
            totalAllocations -= totalAllocated;
            bool success = IStrategy(strategy).withdrawAll();
            require(success, HubVault__EmergencyWithdrawalFailed(strategy));
        } else {
            // EFFECTS
            strategyAllocations[strategy] -= amount;
            totalAllocations -= amount;

            // TODO
            bool success = IStrategy(strategy).withdraw(amount);
            require(success, "withdraw failed");
        }

        emit StrategyFundsWithdrawn(strategy, amount);
    }

    // Must work like if profit is collected than fe
    function collectProfit(
        address strategy
    ) external onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        uint256 profit = IStrategy(strategy).reportProfit();
        require(profit >= MIN_PROFIT, "NOT ENOUGH PROFIT");

        // @audit
        uint256 fee = (profit * PERFORMANCE_FEE) / 10000; // BPS;

        totalFeesCollected += fee;

        emit ProfitsCollected(strategy, profit, fee);
    }

    ///////////////////////////////////////////////////////
    /////////////////// OWNER CLAIMS /////////////////////
    /////////////////////////////////////////////////////

    function claimFees(
        address to
    ) external onlyOwner whenNotPaused nonReentrant {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "Not Enough Amount to Collect");

        totalFeesCollected = 0;
        IERC20(asset()).safeTransfer(to, amount);

        emit FeesCollected(to, amount);
    }

    ////////////////////////////////////////////
    // DEPOSIT / REDEEMING / MINTING VAULT TOKENS
    ///////////////////////////////////////////
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256) {
        // might add fees on deposit when strategy will be implemented
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
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    // function afterDeposit(uint256 assets, uint256 shares) internal override {
    //     //
    // }

    // function beforeWithdraw(uint256 assets, uint256 shares) internal override {
    //     //
    // }

    //////////////////////////////////
    // GETTER FUNCTIONS
    //////////////////////////////////

    function getIsAllowedStrategy(address strategy) public view returns (bool) {
        return isAllowedStrategy[strategy];
    }

    function getFundsAllocatedToStrategy(
        address strategy
    ) public view returns (uint256) {
        return strategyAllocations[strategy];
    }

    function getTotalAllocations() public view returns (uint256) {
        return totalAllocations;
    }

    function totalAssets() public view override returns (uint256) {
        // return super.totalAssets();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle + totalAllocations;
    }

    // revert on native eth transfer
    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
