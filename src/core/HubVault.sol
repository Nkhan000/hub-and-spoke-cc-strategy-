// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault} from "./Vault.sol";

import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults, use the funds in the different strategies to yield profits
 */

interface IStrategy {
    function deposit(uint256[] memory amounts) external returns (uint256);

    function getProfitAmountUSD() external view returns (uint256);

    function onFundsReceived(
        address[] memory tokenAddresses,
        uint256[] memory amounts
    ) external returns (uint256);
}

// TODO : Aggregator and chainlink oracle

contract HubVault is Vault, AccessControl, ReentrancyGuard, Pausable {
    using OracleLib for AggregatorV3Interface;
    using SafeERC20 for IERC20;
    //===================================
    // ERRORS
    //===================================
    error HubVault__InvalidAddress();
    error HubVault__SpokeNotAllowed(address spoke);
    error HubVault__FailedToAddSpoke();
    error HubVault__FailedToRemoveSpoke();
    error HubVault__SpokeAlreadyExists();
    error HubVault__SpokeDoesNotExists();
    error HubVault__InvalidSender();
    error HubVault__BurnSharesFirst();
    error HubVault__StrategyAlreadyExists();
    error HubVault__BurnAllSharesBeforeRemove();
    error HubVault__StrategyDoesNotExists();
    error MinimumAllocationNotMet(address _token, uint256 depositAmtUsd);

    error HubVault__InactiveStrategy();

    //===================================
    // ROLES
    //===================================

    bytes32 public constant ALLOCATOR_ROLE = keccak256("HUB_ALLOCATOR");
    bytes32 public constant SPOKE_ROLE = keccak256("SPOKE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY");

    uint256 public constant MIN_PROFIT_TO_SEND = 1e18;
    uint256 public constant MIN_HARVEST_TIME = 1 hours;
    uint256 public constant MIN_ALLOCATION_USD = 10e18;

    //===================================
    // STRUCTS
    //===================================

    struct StrategyInfo {
        address strategyAddress;
        uint256 claimableProfit;
        uint256 totalLoss;
        uint256 lastHarvest;
        uint256 consecutiveLosses;
        bool isActive;
    }

    struct SpokeInfo {
        address spokeAddress;
        uint256 shares;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
    }

    //===================================
    // MAPPINGS
    //===================================
    mapping(address => SpokeInfo) public spokeInfo;
    mapping(address => StrategyInfo) public strategyInfo;
    uint256 private totalProfit;

    //===================================
    // EVENTS
    //===================================
    event SpokeAdded(address _spoke);
    event SpokeRemoved(address _spoke);
    event StrategyAdded(address _strategy);
    event StrategyRemoved(address _strategy);
    event FundsAllocatedToStrategy(uint256 _depositedAmtInUsd);

    event DepositSuccessfull(
        uint256 _amountUsdc,
        uint256 _amountWeth,
        uint256 shares
    );

    event WithdrawSuccessfull(uint256 withdrawAmt, uint256 sharesBurnt);

    /// @dev Required to resolve multiple inheritance of supportsInterface
    // function supportsInterface(
    //     bytes4 interfaceId
    // ) public view override(AccessControl) returns (bool) {
    //     return AccessControl.supportsInterface(interfaceId);
    // }

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds
    ) Vault(_tokens, _priceFeeds) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ALLOCATOR_ROLE, msg.sender);
        // _grantRole(SPOKE_ROLE, address(spoke));
    }

    //===================================
    // MODIFIERS
    //===================================

    modifier isSpoke(address _spoke) {
        if (spokeInfo[_spoke].spokeAddress == address(0))
            revert HubVault__InvalidAddress();
        _;
    }

    modifier isStrategy(address _strategy) {
        if (strategyInfo[_strategy].strategyAddress == address(0))
            revert HubVault__InvalidAddress();
        _;
    }

    modifier isStrategyActive(address _strategy) {
        if (!strategyInfo[_strategy].isActive)
            revert HubVault__InactiveStrategy();
        _;
    }

    // ============================================
    // STRATEGY MANAGEMENT
    // ============================================
    function addStrategy(
        address _strategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_strategy == address(0)) revert HubVault__InvalidAddress();
        if (strategyInfo[_strategy].strategyAddress != address(0))
            revert HubVault__StrategyAlreadyExists();

        strategyInfo[_strategy] = StrategyInfo({
            strategyAddress: _strategy,
            claimableProfit: 0,
            totalLoss: 0,
            lastHarvest: block.timestamp,
            consecutiveLosses: 0,
            isActive: true
        });

        grantRole(STRATEGY_ROLE, _strategy);

        emit StrategyAdded(_strategy);
    }

    function removeStrategy(
        address _strategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_strategy == address(0)) revert HubVault__InvalidAddress();
        if (strategyInfo[_strategy].strategyAddress == address(0))
            revert HubVault__StrategyDoesNotExists();
        StrategyInfo storage s = strategyInfo[_strategy];
        if (s.claimableProfit > 0) revert("Claim the profits");

        // strategy if still has some money than revert the remove and withdraw from the strategy first
        // more checks to be done !!

        delete strategyInfo[_strategy];

        emit StrategyRemoved(_strategy);
    }

    // ============================================
    // SPOKE MANAGEMENT
    // ============================================

    function addSpoke(
        address _spoke
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_spoke == address(0)) revert HubVault__InvalidAddress();
        if (spokeInfo[_spoke].spokeAddress != address(0))
            revert HubVault__SpokeAlreadyExists(); // spoke already exists maybe a better error message would do

        spokeInfo[_spoke] = SpokeInfo({
            spokeAddress: _spoke,
            shares: 0,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0
        });
        grantRole(SPOKE_ROLE, _spoke);

        emit SpokeAdded(_spoke);
    }

    function _removeSpoke(
        address _spoke
    ) internal onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_spoke == address(0)) revert HubVault__InvalidAddress();
        if (spokeInfo[_spoke].spokeAddress == address(0))
            revert HubVault__SpokeDoesNotExists(); // spoke already exists maybe a better error message would do

        // BEFORE DELETING SEND BACK THE FUNDS TO THIS SPOKE
        if (
            spokeInfo[_spoke].shares > 0 ||
            spokeInfo[_spoke].unclaimedProfit > 0
        ) revert HubVault__BurnSharesFirst();

        // DELETE THE SPOKE FROM THE MAPPING
        delete spokeInfo[_spoke];
        grantRole(SPOKE_ROLE, _spoke);

        emit SpokeAdded(_spoke);
    }

    function deposit(
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    )
        public
        override
        onlyRole(SPOKE_ROLE)
        returns (DepositDetails memory depositDetails)
    {
        address sender = msg.sender;
        if (sender != spokeInfo[sender].spokeAddress)
            revert HubVault__InvalidSender();

        depositDetails = _deposit(_tokensAddresses, _amounts);

        SpokeInfo storage s = spokeInfo[sender];
        s.shares += depositDetails.sharesMinted;
        s.lastDeposit = block.timestamp;

        // emit DepositSuccessfull(_amountUsdc, _amountWeth, shares);
        // return (shares, totalDepositsInUsd);
    }

    function withdraw(
        uint256 _shares
    )
        public
        override
        onlyRole(SPOKE_ROLE)
        nonReentrant
        returns (WithdrawDetails memory withdrawDetails)
    {
        address sender = msg.sender;
        if (sender != spokeInfo[sender].spokeAddress)
            revert HubVault__InvalidSender();

        withdrawDetails = _withdraw(_shares);
        SpokeInfo storage s = spokeInfo[msg.sender];

        require(s.shares >= _shares, "Error in number of shares");

        s.shares -= _shares;
        s.lastWithdrawal = block.timestamp;

        emit WithdrawSuccessfull(withdrawDetails.withdrawValueInUsd, _shares);
    }

    // ============================================
    // EXTERNAL / PUBLIC
    // ============================================

    function allocateFundsToStrategy(
        address _strategy,
        uint256[] memory amounts
    )
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        isStrategyActive(_strategy)
    {
        address[] memory tokenAddresses = getSupportedTokens();
        require(
            amounts.length == tokenAddresses.length,
            "Invalid lenght for amounts array"
        );

        uint256 totalDepositAmt;
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            IERC20 token = IERC20(tokenAddresses[i]);
            uint256 amt = amounts[i];

            // CONVERT TO USD
            uint256 depositAmtUsd = tokenValueUsd(token, amt);
            // CHECK
            if (depositAmtUsd < MIN_ALLOCATION_USD)
                revert MinimumAllocationNotMet(address(token), depositAmtUsd);

            token.safeTransfer(_strategy, amt);

            totalDepositAmt += depositAmtUsd;
        }

        uint256 receivedUsd = IStrategy(_strategy).onFundsReceived(
            tokenAddresses,
            amounts
        );
        require((totalDepositAmt - receivedUsd) <= 1e16); // tolerance of 10000000000000000

        emit FundsAllocatedToStrategy(receivedUsd);
    }

    function harvestProfit(
        address _strategy
    )
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        isStrategyActive(_strategy)
    {
        // uint256 profitedAmount = IStrategy(_strategy).getProfitAmountUSD();
    }

    //
    function sendSpokeProfit(
        address _spoke
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        //
    }

    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
        // EMIT
    }

    // ============================================
    // INTERNAL
    // ============================================

    // ============================================
    // GETTERS
    // ============================================
    function getShares(address _spoke) external view returns (uint256) {
        uint256 shares = spokeInfo[_spoke].shares;
        require(shares == balanceOf(_spoke), "Inconsistent Shares");
        return shares;
    }

    // Emergency functions
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}

// function sendProfitToSpokes() external onlyStrategy;
// function investToStrategy() external onlyOwnerOrAutomation;
// function harvestProfit() external onlyAutomation;
