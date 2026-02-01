// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Vault, VaultErrors, VaultConstants} from "../abstract/Vault.sol";
import {WithdrawalQueue} from "../abstract/WithdrawalQueue.sol";

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {VaultConstants} from "../libraries/constants/VaultConstants.sol";

contract MainVault is
    Vault,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    WithdrawalQueue
{
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice User shares by chain and address
    /// @dev userShares[chainSelector][userAddress] = totalShares
    mapping(uint64 => mapping(address => uint256)) public userShares;

    /// @notice Total shares per chain (for invariant checks)
    mapping(uint64 => uint256) public chainTotalShares;

    /// @notice Nonce of request
    uint256 private _nonce;

    BasePeripheryInfo public basePeriphery;

    // MODIFIERS
    modifier isPeriphery(address _periphery) {
        if (_periphery != basePeriphery.periphery)
            revert VaultErrors.MainVault__NotAllowedPeriphery();
        _;
    }

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds,
        address _periphery
    ) Vault(_tokens, _priceFeeds) {
        require(
            _periphery != address(0),
            VaultErrors.MainVault__InvalidAddress()
        );

        basePeriphery = BasePeripheryInfo({
            periphery: _periphery,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0,
            isActive: true
        });

        // CHAIN_SELECTOR = _chainSelector;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VaultConstants.ALLOCATOR_ROLE, msg.sender);
        _grantRole(VaultConstants.PERIPHERY_ROLE, _periphery);
    }

    // =============================
    // DEPOSIT & WITHDRAW
    // =============================
    /// @notice Anyone can call this deposit function to deposit funds from mainnet
    function deposit(
        address _receiver,
        address[] calldata _tokens,
        uint256[] calldata _amounts,
        uint256 _minSharesOut
    )
        public
        nonReentrant
        whenNotPaused
        returns (DepositDetails memory depositDetails)
    {
        depositDetails = _deposit(_receiver, _tokens, _amounts);

        // Slippage check
        if (depositDetails.sharesMinted < _minSharesOut) {
            revert VaultErrors.MainVault__SlippageExceeded(
                _minSharesOut,
                depositDetails.sharesMinted
            );
        }
        // Credit shares to user on hub chain
        _creditShares(
            VaultConstants.HUB_CHAIN,
            msg.sender,
            depositDetails.sharesMinted
        );
        emit Deposit(
            _receiver,
            _tokens,
            _amounts,
            depositDetails.sharesMinted,
            depositDetails.totalUsdAmount
        );
    }

    function deposit(
        uint64 _sourceChain,
        address _receiver,
        address[] calldata _tokens,
        uint256[] calldata _amounts,
        uint256 _minSharesOut
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(VaultConstants.PERIPHERY_ROLE)
        returns (DepositDetails memory depositDetails)
    {
        // here msg.sender could be periphery contract sending tokens after receiving them through CCIP.
        // here we are minting shares to this mainVault contract as a holder of tokens

        // Process deposit (tokens transferred from periphery/msg.sender)
        depositDetails = _deposit(_receiver, _tokens, _amounts);

        // Slippage check
        if (depositDetails.sharesMinted < _minSharesOut) {
            revert VaultErrors.MainVault__SlippageExceeded(
                _minSharesOut,
                depositDetails.sharesMinted
            );
        }
        // Credit shares to user on source chain
        _creditShares(_sourceChain, _receiver, depositDetails.sharesMinted);
    }

    // HOOK
    function _beforeQueueWithdrawal(
        address _owner,
        address _receiver,
        uint64 _destChain,
        uint256 _shares
    ) internal override {
        require(_owner != address(0), "Invalid Owner");

        (uint256 available, , ) = getSharesInfo(_destChain, _owner);
        if (_shares > available) revert("Insufficient Shares");

        if (_receiver == address(0) && msg.sender != basePeriphery.periphery)
            revert(
                "Only periphery can call this function with receiver being zero address"
            );
    }

    function _afterQueueWithdrawal(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal override {
        // Lock shares AFTER successful queue creation
        _lockShares(_owner, _shares, _destChain);
    }

    function _beforeCancelWithdraw(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal override {
        // unLock shares before successful queue canceling
        _unlockShares(_owner, _shares, _destChain);
    }

    function _afterClaimWithdraw(
        uint256 shares,
        address owner,
        address receiver,
        uint64 destChain
    ) internal override returns (WithdrawDetails memory withdrawDetails) {
        // unclock shares
        _unlockShares(owner, shares, destChain);
        // debit shares
        _debitShares(destChain, owner, shares);
        // actual withdrawal and transfer the tokens
        withdrawDetails = _withdraw(owner, shares, receiver);
    }

    // @notice periphery calls this withdraw function to burn shares and receive funds
    // for native withdrawers
    function addWithdrawalInQueue(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint64 _destChainSelector
    ) external override nonReentrant whenNotPaused returns (bytes32) {
        bytes32 processId = _queueWithdrawal(
            _owner,
            _receiver,
            _shares,
            _destChainSelector
        );

        return processId;
    }

    // @notice This function is to claim the withdrawals already processed.
    function claimWithdrawal(
        bytes32 _requestId
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (WithdrawDetails memory withdrawDetails)
    {
        // MAY BE ADD BETTER CHECK FOR ACCESS of this function as it should called by any user.
        // if (msg.sender != request.owner && msg.sender != request.receiver)
        //     revert("Only owner or receiver could claim the withdraw");

        return _claimWithdrawal(_requestId);
    }

    function updateWithdrawal(
        bytes32 _requestId
    ) external override nonReentrant whenNotPaused {
        _updateWithdrawal(_requestId);
    }

    function cancelWithdrawal(
        bytes32 _requestId
    ) external override nonReentrant whenNotPaused {
        // request.status = WithdrawalStatus.Cancelled;
        // Canceling request is effectively removing the request from the internal mapping

        _cancelWithdrawal(_requestId);
    }

    function withdrawalInfo(
        bytes32 _requestId
    ) external view override whenNotPaused returns (WithdrawalRequest memory) {
        //
        WithdrawalRequest storage request = _withdrawalRequests[_requestId];
        if (request.requestId == bytes32(0)) revert("Invalid Process Id");
        return request;
    }

    // ===========================================
    // PERIPHERY MANAGEMENTS & QUEUE MANAGEMENT
    // ===========================================

    function setQueueConfig(QueueConfig calldata _config) external override {
        _setQueueConfig(_config);
    }

    function updatePeriphery(
        address _newPeriphery
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newPeriphery == address(0))
            revert("Invalid Address for new periphery");

        if (_newPeriphery == basePeriphery.periphery)
            revert("Same address as the old periphery");
        // this check is likely to be removed later as periphery will never hold tokens after or before any transaction
        if (balanceOf(basePeriphery.periphery) > 0)
            revert("Burn shares before updating the periphery");
        if (basePeriphery.unclaimedProfit > 0)
            revert("Transfer unclaimed profits first ");

        revokeRole(VaultConstants.PERIPHERY_ROLE, basePeriphery.periphery);

        BasePeripheryInfo memory newPeriphery = BasePeripheryInfo({
            periphery: _newPeriphery,
            unclaimedProfit: 0,
            lastDeposit: 0,
            lastWithdrawal: 0,
            isActive: true
        });
        grantRole(VaultConstants.PERIPHERY_ROLE, newPeriphery.periphery);
        basePeriphery = newPeriphery;

        emit BasePeripheryUpdated(_newPeriphery);
    }

    function changePeripheryStatus(
        bool _isActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        basePeriphery.isActive = _isActive;
        emit BasePeripheryStatusUpdated(_isActive);
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

    // ======================================
    //  CREDITING & DEBITING SHARES
    // ======================================

    function _creditShares(
        uint64 _chain,
        address _user,
        uint256 _shares
    ) internal whenNotPaused {
        userShares[_chain][_user] += _shares;
        chainTotalShares[_chain] += _shares;

        emit SharesCredited(_chain, _user, _shares, userShares[_chain][_user]);
    }

    function _debitShares(
        uint64 _chain,
        address _user,
        uint256 _shares
    ) internal whenNotPaused {
        uint256 currShares = userShares[_chain][_user];
        if (currShares < _shares) {
            revert("Insufficient Shares");
        }

        userShares[_chain][_user] = currShares - _shares;
        chainTotalShares[_chain] -= _shares;

        emit SharesDebited(_chain, _user, _shares, userShares[_chain][_user]);
    }

    // ===========================
    // GETTERS
    // ===========================
    function getSharesInfo(
        uint64 _chain,
        address _user
    )
        public
        view
        returns (uint256 available, uint256 locked, uint256 totalShares)
    {
        totalShares = userShares[_chain][_user];
        locked = lockedShares[_chain][_user];
        available = totalShares - locked;
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
