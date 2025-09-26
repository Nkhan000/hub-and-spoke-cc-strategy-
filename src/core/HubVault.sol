// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../strategies/IStrategy.sol";

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults on from different chain use the funds in the different strategies to yield profits
 */

contract HubVault is ERC4626, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 constant PERFORMANCE_FEE = 300;

    uint256 immutable i_MIN_PROFIT;
    uint256 private totalAllocations;
    uint256 private totalFeesCollected;
    uint256 private totalSpokeBalance;
    uint256 private totalProfitAfterFee;
    uint256 private totalRealizedLosses;

    // maps all allocations to the strategy
    mapping(address => uint256) internal strategyAllocations;
    //
    mapping(address => bool) internal isAllowedStrategy;
    // spoke vaults funds mapping
    mapping(address => uint256) internal spokeBalances;
    //
    mapping(address => bool) internal isAllowedSpoke;

    // arrays
    EnumerableSet.AddressSet private allStrategies;
    EnumerableSet.AddressSet private allSpokeVaults;

    // ERRORS
    error HubVault__AmountMustBeMoreThanZero();
    error HubVault__FundsAllocationFailed();
    error HubVault__StrategyNotAllowed(address strategy);
    error HubVault__EmergencyWithdrawalFailed(address strategy);
    error HubVault__SpokeNotAllowed(address spoke);
    error HubVault__NotMsgSenderOrSpoke(address spoke);

    /// EVENTS
    event StrategyAdded(address _strategy);
    event SpokeAdded(address _spoke);
    event StrategyRemoved(address _strategy);
    event SpokeRemoved(address _spoke);
    event StrategyFundsAllocated(address strategy, uint256 amount);
    event StrategyFundsWithdrawn(address strategy, uint256 amount);
    event ProfitsCollected(address strategy, uint256 profit, uint256 fee);
    event LossRealized(address strategy, uint256 loss);
    event FeesCollected(address to, uint256 amount);
    event EmergencyWithdrawal(address strategy, uint256 amount);
    event AssetsWithdrawn__SharesBurnt(uint256 assets, uint256 shares);

    // CONSTRUCTOR
    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Cross Token", "CT") Ownable(msg.sender) {
        // asset = _asset;
        i_MIN_PROFIT = 20 * 10 ** decimals();
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

    modifier allowedSpoke(address spoke) {
        require(isAllowedSpoke[spoke], HubVault__SpokeNotAllowed(spoke));
        _;
    }

    modifier allowedSpokeAndSender(address spoke) {
        require(
            isAllowedSpoke[spoke] && msg.sender == spoke,
            HubVault__NotMsgSenderOrSpoke(spoke)
        );
        _;
    }

    //////////////////////////////////
    /////// STRATEGY MANAGEMENT /////
    ////////////////////////////////

    // add strategies like Uniswap or AAVE
    function addStrategy(address _strategy) external onlyOwner nonReentrant {
        require(!isAllowedStrategy[_strategy], "Strategy already listed");
        require(allStrategies.add(_strategy), "Failed to add strategy");

        isAllowedStrategy[_strategy] = true;
        emit StrategyAdded(_strategy);
    }

    function removeStrategy(
        address _strategy
    ) external onlyOwner nonReentrant whenPaused {
        require(isAllowedStrategy[_strategy], "Strategy already removed");
        require(allStrategies.remove(_strategy), "Failed to remove strategy");
        require(strategyAllocations[_strategy] == 0, "withdraw funds first");
        delete isAllowedStrategy[_strategy];

        emit StrategyRemoved(_strategy);
    }

    function addSpoke(address _spoke) external onlyOwner nonReentrant {
        require(!isAllowedSpoke[_spoke], "Spoke already listed");
        require(allSpokeVaults.add(_spoke), "Failed to add spoke");

        isAllowedSpoke[_spoke] = true;
        // allSpokeVaults.push(_spoke); emit event
        emit SpokeAdded(_spoke);
    }

    function removeSpoke(
        address _spoke
    ) external onlyOwner nonReentrant whenPaused {
        require(isAllowedSpoke[_spoke], "Spoke already removed");
        require(allSpokeVaults.remove(_spoke), "Failed to remove spoke");
        delete isAllowedSpoke[_spoke];

        // Optionally: Transfer remaining balance to owner or spoke
        uint256 amount = spokeBalances[_spoke];
        if (amount > 0) {
            spokeBalances[_spoke] = 0;
            totalSpokeBalance -= amount;
            IERC20(asset()).safeTransfer(_spoke, amount);
        }
        emit SpokeRemoved(_spoke);
    }

    ///

    function allocateFundsToStrategy(
        address strategy,
        uint256 amount
    ) external onlyOwner whenNotPaused nonReentrant allowedStrategy(strategy) {
        // CHECKS
        require(
            amount <= IERC20(asset()).balanceOf(address(this)),
            "Insufficient funds in the vault"
        );

        // EFFECTS
        unchecked {
            strategyAllocations[strategy] += amount;
            totalAllocations += amount;
        }

        // INTERACTION
        IERC20(asset()).approve(strategy, amount);
        bool success = IStrategy(strategy).deposit(amount); // strategy pulls asset
        require(success, HubVault__FundsAllocationFailed());

        emit StrategyFundsAllocated(strategy, amount);
    }

    // it assumes that strategy contract has allowed to transfer funds to this contract
    function withdrawFromStrategy(
        address strategy,
        uint256 amount
    ) public onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        _harvest(strategy);
        require(
            strategyAllocations[strategy] >= amount,
            "Not enough allocated"
        );
        uint256 totalAllocated = strategyAllocations[strategy];
        require(totalAllocated > 0, "Strategy has no funds");

        // Sync allocations with actual strategy state
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

    // This functions should collect the acrued profit from the strategy to this vault
    function _harvest(
        address strategy
    ) internal onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        uint256 initialBalance = IERC20(asset()).balanceOf(address(this));

        // collects profit
        (uint256 profit, uint256 loss) = IStrategy(strategy)
            .reportProfitAndLoss();

        require(
            profit == 0 || loss == 0,
            "Profit and loss cannot both be non-zero"
        ); // Enforces mutual exclusivity

        if (profit > 0) {
            require(profit >= i_MIN_PROFIT, "NOT ENOUGH PROFIT");

            IStrategy(strategy).collectAllProfits();
            // verify profit was transfered
            uint256 received = IERC20(asset()).balanceOf(address(this)) -
                initialBalance;
            require(received >= profit, "Profit not received");

            // Calculate and record fee
            uint256 fee = (profit * PERFORMANCE_FEE) / 10000;
            require(fee <= profit, "Invalid performance fee");

            totalFeesCollected += fee;
            totalProfitAfterFee += (profit - fee);

            emit ProfitsCollected(strategy, profit, fee);
        } else if (loss > 0) {
            //
            require(
                strategyAllocations[strategy] >= loss,
                "Losses exceeds allocations"
            );
            strategyAllocations[strategy] -= loss;
            totalAllocations -= loss;
            totalRealizedLosses += loss;

            emit LossRealized(strategy, loss);
        }
    }

    function distributeProfit() external onlyOwner nonReentrant whenPaused {
        require(totalProfitAfterFee > 0, "Not enough profit to distribute");
        require(totalSpokeBalance > 0, "No spoke balance to distribute to");

        uint256 totalDistributed;
        address[] memory spokes = allSpokeVaults.values();
        for (uint16 i = 0; i < spokes.length; ++i) {
            address spoke = spokes[i];
            //                     (total balance of a spoke * totalProfits) / totalProfitsToDistribute
            uint256 amountToPay = (spokeBalances[spoke] * totalProfitAfterFee) /
                totalSpokeBalance;
            if (amountToPay > 0) {
                IERC20(asset()).safeTransfer(spoke, amountToPay);
                totalDistributed += amountToPay;
            }
        }
        uint256 remaining = totalProfitAfterFee - totalDistributed;
        if (remaining > 0) {
            IERC20(asset()).safeTransfer(owner(), remaining);
        }

        totalProfitAfterFee = 0; // reset
    }

    ///////////////////////////////////////////////////////
    /////////////////// OWNER CLAIMS /////////////////////
    /////////////////////////////////////////////////////

    // transfer collected fees to the owner
    function claimFees(
        address to
    ) external onlyOwner whenNotPaused nonReentrant {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "Not Enough Amount to Collect");
        require(to != address(0), "Invalid address");

        totalFeesCollected = 0;
        IERC20(asset()).approve(to, amount);
        IERC20(asset()).safeTransfer(to, amount);

        emit FeesCollected(to, amount);
    }

    /////////////////////////////////////////////////
    // DEPOSIT / REDEEMING / MINTING VAULT TOKENS //
    ///////////////////////////////////////////////
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        notZeroAmount(assets)
        allowedSpoke(msg.sender)
        returns (uint256)
    {
        uint256 shares = super.deposit(assets, receiver);
        _afterDeposit(assets, receiver);
        //
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        allowedSpoke(msg.sender)
        notZeroAmount(shares)
        returns (uint256)
    {
        uint256 assets = super.mint(shares, receiver);
        _afterDeposit(assets, receiver);
        // emits
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        whenNotPaused
        allowedSpokeAndSender(owner)
        notZeroAmount(assets)
        returns (uint256)
    {
        require(
            spokeBalances[owner] >= assets,
            "Insufficient funds to withdraw"
        );
        unchecked {
            spokeBalances[owner] -= assets;
            totalSpokeBalance -= assets;
        }
        uint256 shares = super.withdraw(assets, receiver, owner);
        emit AssetsWithdrawn__SharesBurnt(assets, shares);
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        whenNotPaused
        allowedSpokeAndSender(owner)
        notZeroAmount(shares)
        returns (uint256)
    {
        // uint256 assets = previewRedeem(shares);

        uint256 assets = super.redeem(shares, receiver, owner);

        require(
            spokeBalances[owner] >= assets,
            "Insufficient funds to withdraw"
        );
        unchecked {
            spokeBalances[owner] -= assets;
            totalSpokeBalance -= assets;
        }
        emit AssetsWithdrawn__SharesBurnt(assets, shares);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC                     
    //////////////////////////////////////////////////////////////*/

    function _afterDeposit(uint256 assets, address receiver) internal {
        spokeBalances[receiver] += assets;
        totalSpokeBalance += assets;
    }

    // function beforeWithdraw(uint256 assets, uint256 shares) internal {
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
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 total = idle + totalAllocations;
        return total;
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
