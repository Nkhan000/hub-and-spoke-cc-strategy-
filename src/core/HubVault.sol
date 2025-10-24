// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault} from "./Vault.sol";
// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

// import {IStrategy} from "../strategies/IStrategy.sol";
// import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults, use the funds in the different strategies to yield profits
 */

interface ISpoke {

}

// TODO : Aggregator and chainlink oracle

contract HubVault is Vault, AccessControl, ReentrancyGuard, Pausable {
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

    //===================================
    // ROLES
    //===================================

    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");
    bytes32 public constant SPOKE_ROLE = keccak256("SPOKE");

    //===================================
    // STRUCTS
    //===================================

    struct StrategyInfo {
        uint256 allocation;
        uint256 totalProfit;
        uint256 totalLoss;
        uint256 lastHarvest;
        uint256 consecutiveLosses;
        bool isActive;
    }

    struct SpokeInfo {
        address spokeAddress;
        uint256 deposits;
        uint256 shares;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
    }

    //===================================
    // MAPPINGS
    //===================================
    mapping(address => SpokeInfo) public spokeInfo;

    //===================================
    // EVENTS
    //===================================
    event SpokeAdded(address _spoke);
    event SpokeRemoved(address _spoke);

    event DepositSuccessfull(
        uint256 _amountUsdc,
        uint256 _amountWeth,
        uint256 shares
    );

    /// @dev Required to resolve multiple inheritance of supportsInterface
    // function supportsInterface(
    //     bytes4 interfaceId
    // ) public view override(AccessControl) returns (bool) {
    //     return AccessControl.supportsInterface(interfaceId);
    // }

    constructor(
        address _weth,
        address _usdc,
        address _wethUsdFeed,
        address _usdcUsdFeed
    ) Vault(_weth, _usdc, _wethUsdFeed, _usdcUsdFeed) {
        //
        require(
            _weth != address(0) ||
                _usdc != address(0) ||
                _wethUsdFeed != address(0) ||
                _usdcUsdFeed != address(0),
            HubVault__InvalidAddress()
        );
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
            deposits: 0,
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
        // SpokeInfo
        // BEFORE DELETING SEND BACK THE FUNDS TO THIS SPOKE
        // if()

        // DELETE THE SPOKE FROM THE MAPPING
        delete spokeInfo[_spoke];
        grantRole(SPOKE_ROLE, _spoke);

        emit SpokeAdded(_spoke);
    }

    function deposit(
        uint256 _amountWeth,
        uint256 _amountUsdc
    ) public override onlyRole(SPOKE_ROLE) returns (uint256) {
        address sender = msg.sender;
        if (sender != spokeInfo[sender].spokeAddress)
            revert HubVault__InvalidSender();

        uint256 shares = _deposit(_amountWeth, _amountUsdc);
        uint256 totalDeposits = tokenValueUsd(weth, _amountWeth) +
            tokenValueUsd(usdc, _amountUsdc);

        SpokeInfo storage s = spokeInfo[sender];
        s.shares += shares;
        s.deposits += totalDeposits;
        s.lastDeposit = block.timestamp;

        emit DepositSuccessfull(_amountUsdc, _amountWeth, shares);
        return shares;
    }

    function withdraw(
        uint256 shares
    )
        public
        override
        onlyRole(SPOKE_ROLE)
        returns (uint256 wethOut, uint256 usdcOut)
    {
        //
    }

    // ============================================
    // INTERNAL
    // ============================================
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
        // EMIT
    }
}

// function sendProfitToSpokes() external onlyStrategy;
// function investToStrategy() external onlyOwnerOrAutomation;
// function harvestProfit() external onlyAutomation;
