// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault} from "./Vault.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

contract MainVault is Vault, AccessControl, Pausable, ReentrancyGuard {
    //ERRORS
    error MainVault__ProviderAlreadyExists();
    error MainVault__InvalidChainSelector();
    error MainVault__InvalidAddress();
    error MainVault__NotAllowedPeriphery();
    error MainVault__SlippageExceeded(
        uint256 sharesMinted,
        uint256 minSharesOut
    );

    // EVENTS
    event LiquidityProviderAdded();

    event RoleGranted(address _account, bytes32 _role);
    event RoleRevoked(address _account, bytes32 _role);

    event DepositReceivedFromPeriphery(
        address receiver,
        address[] tokensAddresses,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalUsdAmount
    );
    event PeripheryWithdraw(
        address owner,
        address[] tokensReceived,
        uint256[] amountReceived,
        uint256 sharesBurnt
    );
    event BasePeripheryUpdated(address newPeriphery);
    event BasePeripheryDisabled();
    event BasePeripheryEnabled();

    // CONSTANTS & IMMUTABLES

    // STATE VARIABLES

    // STRUCTS
    struct BasePeripheryInfo {
        address periphery;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    // ROLES

    bytes32 public constant ALLOCATOR_ROLE = keccak256("SPOKE_ALLOCATOR");
    bytes32 public constant PERIPHERY_ROLE = keccak256("BASE_PERIPHERY");

    // MAPPINGS
    // mapping(address => BasePeripheryInfo) public basePeripheryInfo;
    BasePeripheryInfo public basePeriphery;

    // MODIFIERS
    modifier isPeriphery(address _periphery) {
        if (_periphery != basePeriphery.periphery)
            revert MainVault__NotAllowedPeriphery();
        _;
    }

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds,
        address _periphery
    ) Vault(_tokens, _priceFeeds) {
        require(_periphery != address(0), MainVault__InvalidAddress());

        basePeriphery = BasePeripheryInfo({
            periphery: _periphery,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0,
            isActive: true
        });

        // CHAIN_SELECTOR = _chainSelector;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ALLOCATOR_ROLE, msg.sender);
        _grantRole(PERIPHERY_ROLE, _periphery);
    }

    // @notice Base periphery calls this deposit function to deposit funds
    // As Base Periphery will be receiving funds from multiple
    function deposit(
        address _receiver,
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    )
        public
        override
        nonReentrant
        onlyRole(PERIPHERY_ROLE)
        returns (DepositDetails memory depositDetails)
    {
        // replay protection if meta carries messageId
        // if (meta.length >= 32) {
        //     bytes32 messageId = bytes32(meta[:32]); // example convention
        //     if (processedMessage[messageId]) revert("Message already processed");
        //     processedMessage[messageId] = true;
        // }
        depositDetails = _deposit(_receiver, _tokensAddresses, _amounts);
        emit DepositReceivedFromPeriphery(
            _receiver,
            _tokensAddresses,
            _amounts,
            depositDetails.sharesMinted,
            depositDetails.totalUsdAmount
        );
    }

    // @notice periphery calls this withdraw function to burn shares and receive funds
    function withdraw(
        address _owner,
        uint256 _shares
    )
        public
        override
        nonReentrant
        whenNotPaused
        onlyRole(PERIPHERY_ROLE)
        returns (WithdrawDetails memory withdrawDetails)
    {
        withdrawDetails = _withdraw(_owner, _shares, address(0));
        emit PeripheryWithdraw(
            _owner,
            withdrawDetails.tokensReceived,
            withdrawDetails.amountsReceived,
            _shares
        );
    }

    // called by periphery to withdraw for an owner on cross chain network. receives the tokens first and then initiate the cross chain transfer
    function withdrawTo(
        address _owner,
        uint256 _shares
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(PERIPHERY_ROLE)
        returns (WithdrawDetails memory withdrawDetails)
    {
        withdrawDetails = _withdraw(_owner, _shares, basePeriphery.periphery);

        emit PeripheryWithdraw(
            _owner,
            withdrawDetails.tokensReceived,
            withdrawDetails.amountsReceived,
            _shares
        );
    }

    // ===========================================
    // PERIPHERY MANAGEMENTS
    // ===========================================

    function updatePeriphery(
        address _newPeriphery
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newPeriphery == address(0))
            revert("Invalid Address for new periphery");

        if (_newPeriphery == basePeriphery.periphery)
            revert("Same address as the old periphery");
        if (balanceOf(basePeriphery.periphery) > 0)
            revert("Burn shares before updating the periphery");
        if (basePeriphery.unclaimedProfit > 0)
            revert("Transfer unclaimed profits first ");

        revokeRole(PERIPHERY_ROLE, basePeriphery.periphery);

        BasePeripheryInfo memory newPeriphery = BasePeripheryInfo({
            periphery: _newPeriphery,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0,
            isActive: true
        });
        grantRole(PERIPHERY_ROLE, newPeriphery.periphery);
        basePeriphery = newPeriphery;

        emit BasePeripheryUpdated(_newPeriphery);
    }

    function disablePeriphery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!basePeriphery.isActive) return; // do we need this check ??
        basePeriphery.isActive = false;

        emit BasePeripheryDisabled();
    }

    function enablePeriphery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (basePeriphery.isActive) return;
        basePeriphery.isActive = true;

        emit BasePeripheryEnabled();
    }

    // ===========================================
    // TOKEN MANAGEMENT
    // ===========================================

    function addAssets(
        address[] calldata _newAssets,
        address[] calldata _priceFeeds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addAssets(_newAssets, _priceFeeds);
    }

    function removeAssets(
        address[] calldata _newAssets
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _removeAssets(_newAssets);
    }

    function updatePriceFeed(
        address _asset,
        address _newPriceFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updatePriceFeed(_asset, _newPriceFeed);
    }

    function enableAsset(address _asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _enableAsset(_asset);
    }

    function disableAsset(
        address _asset
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _disableAsset(_asset);
    }

    // ===========================================
    // ROLE GRANTING FUNCTION
    // ===========================================
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
        emit RoleGranted(account, role);
        // EMIT
    }

    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
        emit RoleRevoked(account, role);
    }

    // Emergency functions
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }
}
