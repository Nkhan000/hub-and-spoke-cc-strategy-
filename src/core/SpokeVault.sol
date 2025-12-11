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
import {HubVault} from "../core/HubVault.sol";

contract SpokeVault is Vault, AccessControl, Pausable, ReentrancyGuard {
    //ERRORS
    error SpokeVault__ProviderAlreadyExists();
    error SpokeVault__InvalidChainSelector();
    error SpokeVault__InvalidAddress();
    error SpokeVault__NotAllowedPeriphery();

    // EVENTS
    event LiquidityProviderAdded();

    event RoleGranted(address _account, bytes32 _role);
    event RoleRevoked(address _account, bytes32 _role);

    event TransferredFundsToHub(
        address[] tokensDeposited,
        uint256[] amountsDeposited,
        uint256 sharesMinted,
        uint256 totalValueDeposited
    );
    event WithdrawnFundsFromHub(
        address[] tokensReceived,
        uint256[] amountsReceived,
        uint256 sharesBurnt,
        uint256 totalValueReceived
    );
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
    // address public immutable BASE_PERIPHERY_CONTRACT;
    // STATE VARIABLES

    // STRUCTS
    struct BasePeripheryInfo {
        address periphery;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    struct HubInfo {
        address hub;
        uint256 totalProfitEarned;
        uint256 lastAllocated;
        uint256 lastWithdrawal;
    }

    // ROLES

    bytes32 public constant ALLOCATOR_ROLE = keccak256("SPOKE_ALLOCATOR");
    bytes32 public constant PERIPHERY_ROLE = keccak256("BASE_PERIPHERY");

    // MAPPINGS
    // mapping(address => BasePeripheryInfo) public basePeripheryInfo;
    BasePeripheryInfo public basePeriphery;
    HubInfo public hubInfo;

    // MODIFIERS
    modifier isPeriphery(address _periphery) {
        if (_periphery != basePeriphery.periphery)
            revert SpokeVault__NotAllowedPeriphery();
        _;
    }

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds,
        address _periphery,
        address _hub
    ) Vault(_tokens, _priceFeeds) {
        require(_periphery != address(0), SpokeVault__InvalidAddress());

        basePeriphery = BasePeripheryInfo({
            periphery: _periphery,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0,
            isActive: true
        });

        hubInfo = HubInfo({
            hub: _hub,
            totalProfitEarned: 0,
            lastAllocated: 0,
            lastWithdrawal: 0
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
    // HUB VAULT FUNCIONTS
    // ===========================================

    // @notice called by spoke vault owner to send all funds to the hub vault
    function transferAllFundsToHub() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256[] memory amounts;
        address[] memory tokensAddress = getSupportedTokens();

        transferFundsToHub(amounts, tokensAddress);
    }

    // @notice called by spoke vault owner to send funds to the hub vault
    function transferFundsToHub(
        uint256[] memory amounts,
        address[] memory tokensAddress
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            amounts.length == tokensAddress.length,
            "Invalid lengths for amounts and tokens"
        );
        for (uint256 i = 0; i < tokensAddress.length; i++) {
            amounts[i] = IERC20(tokensAddress[i]).balanceOf(address(this)); //
            IERC20(tokensAddress[i]).approve(hubInfo.hub, amounts[i]);
        }
        DepositDetails memory depositDetailsOnHub = HubVault(hubInfo.hub)
            .deposit(tokensAddress, amounts);

        emit TransferredFundsToHub(
            tokensAddress,
            amounts,
            depositDetailsOnHub.sharesMinted,
            depositDetailsOnHub.totalUsdAmount
        );
    }

    // @notice called by spoke vault owner to withdraw funds from the HUB VAULT
    function withdrawFromHub(
        uint256 _shares
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WithdrawDetails memory withdrawDetails = HubVault(hubInfo.hub).withdraw(
            _shares
        );

        emit WithdrawnFundsFromHub(
            withdrawDetails.tokensReceived,
            withdrawDetails.amountsReceived,
            _shares,
            withdrawDetails.withdrawValueInUsd
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
        basePeriphery = newPeriphery;

        emit BasePeripheryUpdated(_newPeriphery);
    }

    function disablePeriphery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!basePeriphery.isActive) return;
        basePeriphery.isActive = false;

        emit BasePeripheryDisabled();
    }

    function enablePeriphery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (basePeriphery.isActive) return;
        basePeriphery.isActive = true;

        emit BasePeripheryEnabled();
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
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
