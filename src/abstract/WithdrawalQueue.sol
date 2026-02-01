// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import {MainVault} from "../core/MainVault.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IWithdrawalQueue} from "../interfaces/IWithdrawalQueue.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IVault} from "../interfaces//IVault.sol";

abstract contract WithdrawalQueue is IWithdrawalQueue {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    IVault private vault;

    /// @notice Queue configuration
    QueueConfig public queueConfig;

    /// @notice Withdrawal requests by ID
    mapping(bytes32 => WithdrawalRequest) internal _withdrawalRequests;

    EnumerableSet.Bytes32Set private _pendingRequestIds; // For iterating pending requests
    /// @notice User's pending request IDs
    mapping(uint64 => mapping(address => EnumerableSet.Bytes32Set))
        internal _userPendingRequests;
    mapping(address => uint256) private _userRequestIds;

    /// @notice Nonce for request ID generation
    uint256 internal _requestNonce;

    function _queueWithdrawal(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint64 _destChain
    ) internal returns (bytes32 requestId) {
        _beforeQueueWithdrawal(_owner, _receiver, _destChain, _shares);

        requestId = _generateRequestId(
            _owner,
            _receiver,
            _shares,
            block.timestamp,
            _destChain
        );

        // if same id exists than revert
        if (_withdrawalRequests[requestId].requestId != bytes32(0))
            revert("Process already exists");

        // Determine status
        WithdrawalStatus status = _determineStatus(_shares);
        uint256 claimableAt = block.timestamp + queueConfig.minDelay;

        WithdrawalRequest memory request = WithdrawalRequest({
            requestId: requestId,
            owner: _owner,
            receiver: _receiver,
            shares: _shares,
            requestedAt: block.timestamp,
            claimableAt: claimableAt,
            destinationChain: _destChain, // 0 == same chain
            status: status // Pending, Ready, Claimed, Cancelled ;
        });
        // add request ID to the states
        _addRequestId(_owner, _destChain, request, requestId);

        // EFFECTS: Post-processing hook (e.g., lock shares)
        _afterQueueWithdrawal(_owner, _shares, _destChain);

        emit Queue(
            requestId,
            _destChain,
            _owner,
            _receiver,
            _shares,
            claimableAt,
            status
        );
    }

    function _claimWithdrawal(
        bytes32 _requestId
    ) internal returns (IVault.WithdrawDetails memory) {
        WithdrawalRequest storage request = _updateWithdrawal(_requestId);
        // Verify ready status
        if (request.status != WithdrawalStatus.Ready) {
            revert("WithdrawalNotClaimableYet()");
        }
        address reqOwner = request.owner;
        address reqReceiver = request.receiver;
        uint256 shares = request.shares;
        uint64 reqChain = request.destinationChain;

        _removeRequestId(reqOwner, reqChain, _requestId); // remove the request from the states

        return _afterClaimWithdraw(shares, reqOwner, reqReceiver, reqChain); // unlock and debit shares
    }

    // @notice update withdraw process status based on vault condition
    function _updateWithdrawal(
        bytes32 _requestId
    ) internal returns (WithdrawalRequest storage request) {
        request = _withdrawalRequests[_requestId];
        if (request.requestId == bytes32(0)) {
            revert("Process does not exists");
        }
        if (request.claimableAt > block.timestamp) {
            revert("Not claimable Yet. Try again in sometime");
        }
        if (request.status != WithdrawalStatus.Pending) {
            revert("Withdraw Process already Claimed or Cancelled");
        }
        WithdrawalStatus status = _determineStatus(request.shares);

        request.status = status;
        request.requestedAt = block.timestamp;
        emit ProcessUpdate(_requestId, status);
    }

    // TODO: May be add the expiry condition which will remove the request from the states

    function _cancelWithdrawal(bytes32 _requestId) internal {
        WithdrawalRequest storage request = _withdrawalRequests[_requestId];
        if (request.requestId == bytes32(0)) {
            revert("Process does not exists");
        }
        // May be process with READY status should also be cancelled
        if (request.status == WithdrawalStatus.Claimed)
            revert("Process already Claimed");

        request.status = WithdrawalStatus.Cancelled;

        _beforeCancelWithdraw(
            request.owner,
            request.shares,
            request.destinationChain
        );
        _removeRequestId(request.owner, request.destinationChain, _requestId);

        emit ProcessUpdate(_requestId, WithdrawalStatus.Cancelled);
    }

    function _addRequestId(
        address _owner,
        uint64 _chain,
        WithdrawalRequest memory request,
        bytes32 _requestId
    ) internal {
        _pendingRequestIds.add(_requestId); // Adding to request set
        _userPendingRequests[_chain][_owner].add(_requestId); // Adding to user mapping for pending request
        _withdrawalRequests[_requestId] = request; // Adding request to the mapping
    }

    function _removeRequestId(
        address _owner,
        uint64 _chain,
        bytes32 _requestId
    ) internal {
        _pendingRequestIds.remove(_requestId);
        _userPendingRequests[_chain][_owner].remove(_requestId);
        delete _withdrawalRequests[_requestId]; // Deleting request to the mapping
    }

    function _determineStatus(
        uint256 shares
    ) internal view returns (WithdrawalStatus) {
        uint256 requestedSharesValueUSD = vault.shareValueUsd(shares);
        uint256 idleFundsUsd = vault.getIdleFundsUsd();
        uint256 totalSupply = vault.totalSupply();
        // Check 1: Liquidity
        if (requestedSharesValueUSD > idleFundsUsd) {
            // WHAT IS THE VALUE IS EQUAL TO THE IDLE FUND AND IS LESS THAN WITHDRAWLIMITUSD ???
            return WithdrawalStatus.Pending;
        }
        if (requestedSharesValueUSD > queueConfig.instantWithdrawLimitUsd) {
            return WithdrawalStatus.Pending;
        }
        // ? what if total supply is 0 ?
        if (totalSupply > 0) {
            uint256 requestedBps = Math.mulDiv(shares, 10000, totalSupply);
            if (requestedBps > queueConfig.instantWithdrawLimitBps) {
                return WithdrawalStatus.Pending;
            }
        }
        return WithdrawalStatus.Ready;
    }

    function _setQueueConfig(QueueConfig calldata _config) internal {
        if (_config.minDelay == 0 || _config.maxDelay <= _config.minDelay) {
            revert("Queue__InvalidConfig()");
        }
        // if (_config.instantWithdrawLimitBps > BPS_DENOMINATOR) {
        if (_config.instantWithdrawLimitBps > 10_000) {
            revert("Queue__InvalidConfig()");
        }

        queueConfig = _config;
    }

    function getWithdrawalStatus(
        bytes32 _processId
    ) public view returns (WithdrawalStatus) {
        return _withdrawalRequests[_processId].status;
    }

    function _generateRequestId(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint256 _timestamp,
        uint64 chainSelector
    ) internal returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _owner,
                    _receiver,
                    _shares,
                    _timestamp,
                    chainSelector
                    // ,
                    // ++_nonce
                )
            );
    }

    // HOOKS
    function _beforeCancelWithdraw(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal virtual;

    function _beforeQueueWithdrawal(
        address _owner,
        address _receiver,
        uint64 _destChain,
        uint256 _shares
    ) internal virtual;

    function _afterQueueWithdrawal(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal virtual;

    function _afterClaimWithdraw(
        uint256 shares,
        address owner,
        address receiver,
        uint64 destChain
    ) internal virtual returns (IVault.WithdrawDetails memory);

    // this is something that must be on vault
    function _requiredFundsToProcess() internal view {}
}
