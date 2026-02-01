// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IVault} from "./IVault.sol";

interface IWithdrawalQueue {
    event Queue(
        bytes32 requestId,
        uint64 destChainSelector,
        address owner,
        address receiver,
        uint256 shares,
        uint256 claimableAt,
        WithdrawalStatus status
    );
    event ProcessUpdate(bytes32 indexed processId, WithdrawalStatus status);
    enum WithdrawalStatus {
        Pending,
        Ready,
        Claimed,
        Cancelled
    }

    struct WithdrawalRequest {
        bytes32 requestId;
        address owner;
        address receiver;
        uint256 shares;
        uint256 requestedAt;
        uint256 claimableAt;
        uint64 destinationChain; // 0 = same chain
        WithdrawalStatus status; // Pending, Ready, Claimed, Cancelled
    }

    struct QueueConfig {
        uint256 minDelay; // e.g., 1 day
        uint256 maxDelay; // e.g., 7 days
        uint256 instantWithdrawLimitBps; // e.g., 500 = 5%
        uint256 instantWithdrawLimitUsd; // e.g., 10_000e18
    }

    // @notice periphery calls this withdraw function to burn shares and receive funds
    // for native withdrawers
    function addWithdrawalInQueue(
        address _owner,
        address _receiver,
        uint256 _shares,
        uint64 _destChain
    ) external returns (bytes32);

    // @notice This function is to claim the withdrawals already processed.
    function claimWithdrawal(
        bytes32 _requestId
    ) external returns (IVault.WithdrawDetails memory);

    function updateWithdrawal(bytes32 _requestId) external;

    function cancelWithdrawal(bytes32 _requestId) external;

    function withdrawalInfo(
        bytes32 _requestId
    ) external returns (WithdrawalRequest memory);

    function setQueueConfig(QueueConfig calldata _config) external;
}
