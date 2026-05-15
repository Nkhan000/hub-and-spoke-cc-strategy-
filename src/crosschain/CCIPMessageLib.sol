// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import {ICCIPHandler} from "../interfaces/ICCIPHandler.sol";

/// @title CCIPMessageLib
/// @author Nazir Khan
/// @notice Library for encoding and decoding CCIP messages
/// @dev Provides type-safe encoding/decoding for all message types

library CCIPMessageLib {
    // ============ ERRORS ============

    error InvalidPayloadLength();
    error InvalidMessageType();

    // ============ DEPOSIT MESSAGES ============

    /// @notice Encode deposit request payload (Spoke -> Hub)
    function encodeDepositRequest(
        uint64 sourceChain,
        address user,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 minSharesOut
    ) internal pure returns (bytes memory) {
        return abi.encode(sourceChain, user, tokens, amounts, minSharesOut);
    }

    /// @notice Decode deposit request payload
    function decodeDepositRequest(
        bytes memory payload
    )
        internal
        pure
        returns (
            uint64 sourceChain,
            address user,
            address[] memory tokens,
            uint256[] memory amounts,
            uint256 minSharesOut
        )
    {
        (sourceChain, user, tokens, amounts, minSharesOut) = abi.decode(
            payload,
            (uint64, address, address[], uint256[], uint256)
        );
    }

    /// @notice Encode deposit confirmation payload (Hub -> Spoke)
    function encodeDepositConfirmed(
        bytes32 originalMessageId,
        address user,
        uint256 sharesMinted,
        uint256 usdValue
    ) internal pure returns (bytes memory) {
        return abi.encode(originalMessageId, user, sharesMinted, usdValue);
    }

    /// @notice Decode deposit confirmation payload
    function decodeDepositConfirmed(
        bytes memory payload
    )
        internal
        pure
        returns (
            bytes32 originalMessageId,
            address user,
            uint256 sharesMinted,
            uint256 usdValue
        )
    {
        (originalMessageId, user, sharesMinted, usdValue) = abi.decode(
            payload,
            (bytes32, address, uint256, uint256)
        );
    }

    // ============ WITHDRAWAL MESSAGES ============

    /// @notice Encode withdrawal request payload (Spoke -> Hub)
    function encodeWithdrawRequest(
        uint64 sourceChain,
        address owner,
        address receiver,
        uint256 shares
    ) internal pure returns (bytes memory) {
        return abi.encode(sourceChain, owner, receiver, shares);
    }

    /// @notice Decode withdrawal request payload
    function decodeWithdrawRequest(
        bytes memory payload
    )
        internal
        pure
        returns (
            uint64 sourceChain,
            address owner,
            address receiver,
            uint256 shares
        )
    {
        (sourceChain, owner, receiver, shares) = abi.decode(
            payload,
            (uint64, address, address, uint256)
        );
    }

    /// @notice Encode withdrawal queued notification (Hub -> Spoke)
    function encodeWithdrawQueued(
        bytes32 requestId,
        address owner,
        uint256 shares,
        uint256 claimableAt,
        uint8 status
    ) internal pure returns (bytes memory) {
        return abi.encode(requestId, owner, shares, claimableAt, status);
    }

    /// @notice Decode withdrawal queued notification
    function decodeWithdrawQueued(
        bytes memory payload
    )
        internal
        pure
        returns (
            bytes32 requestId,
            address owner,
            uint256 shares,
            uint256 claimableAt,
            uint8 status
        )
    {
        (requestId, owner, shares, claimableAt, status) = abi.decode(
            payload,
            (bytes32, address, uint256, uint256, uint8)
        );
    }

    /// @notice Encode withdrawal tokens payload (Hub -> Spoke, with tokens)
    function encodeWithdrawTokens(
        bytes32 requestId,
        address receiver,
        uint256 sharesBurned,
        uint256 usdValue
    ) internal pure returns (bytes memory) {
        return abi.encode(requestId, receiver, sharesBurned, usdValue);
    }

    /// @notice Decode withdrawal tokens payload
    function decodeWithdrawTokens(
        bytes memory payload
    )
        internal
        pure
        returns (
            bytes32 requestId,
            address receiver,
            uint256 sharesBurned,
            uint256 usdValue
        )
    {
        (requestId, receiver, sharesBurned, usdValue) = abi.decode(
            payload,
            (bytes32, address, uint256, uint256)
        );
    }

    /// @notice Encode withdrawal cancel request (Spoke -> Hub)
    function encodeWithdrawCancel(
        bytes32 requestId,
        address owner
    ) internal pure returns (bytes memory) {
        return abi.encode(requestId, owner);
    }

    /// @notice Decode withdrawal cancel request
    function decodeWithdrawCancel(
        bytes memory payload
    ) internal pure returns (bytes32 requestId, address owner) {
        (requestId, owner) = abi.decode(payload, (bytes32, address));
    }

    /// @notice Encode withdrawal cancelled confirmation (Hub -> Spoke)
    function encodeWithdrawCancelled(
        bytes32 requestId,
        address owner,
        uint256 sharesReturned
    ) internal pure returns (bytes memory) {
        return abi.encode(requestId, owner, sharesReturned);
    }

    /// @notice Decode withdrawal cancelled confirmation
    function decodeWithdrawCancelled(
        bytes memory payload
    )
        internal
        pure
        returns (bytes32 requestId, address owner, uint256 sharesReturned)
    {
        (requestId, owner, sharesReturned) = abi.decode(
            payload,
            (bytes32, address, uint256)
        );
    }

    /// @notice Encode claim request (Spoke -> Hub)
    function encodeWithdrawClaim(
        bytes32 requestId,
        address claimer
    ) internal pure returns (bytes memory) {
        return abi.encode(requestId, claimer);
    }

    /// @notice Decode claim request
    function decodeWithdrawClaim(
        bytes memory payload
    ) internal pure returns (bytes32 requestId, address claimer) {
        (requestId, claimer) = abi.decode(payload, (bytes32, address));
    }

    // ============ SYNC MESSAGES ============

    /// @notice Encode sync request (Spoke -> Hub or Hub -> Spoke)
    function encodeSyncRequest(
        uint64 chainSelector,
        address user
    ) internal pure returns (bytes memory) {
        return abi.encode(chainSelector, user);
    }

    /// @notice Decode sync request
    function decodeSyncRequest(
        bytes memory payload
    ) internal pure returns (uint64 chainSelector, address user) {
        (chainSelector, user) = abi.decode(payload, (uint64, address));
    }

    /// @notice Encode sync response (Hub -> Spoke)
    function encodeSyncResponse(
        address user,
        uint256 totalShares,
        uint256 lockedShares,
        uint256 usdValue
    ) internal pure returns (bytes memory) {
        return abi.encode(user, totalShares, lockedShares, usdValue);
    }

    /// @notice Decode sync response
    function decodeSyncResponse(
        bytes memory payload
    )
        internal
        pure
        returns (
            address user,
            uint256 totalShares,
            uint256 lockedShares,
            uint256 usdValue
        )
    {
        (user, totalShares, lockedShares, usdValue) = abi.decode(
            payload,
            (address, uint256, uint256, uint256)
        );
    }

    // ============ UTILITY ============

    /// @notice Wrap payload with message type for transmission
    // function wrapMessage(
    //     ICCIPHandler.MessageType messageType,
    //     bytes memory payload
    // ) internal pure returns (bytes memory) {
    //     return abi.encode(uint8(messageType), payload);
    // }

    /// @notice Unwrap received message
    // function unwrapMessage(
    //     bytes memory data
    // )
    //     internal
    //     pure
    //     returns (ICCIPHandler.MessageType messageType, bytes memory payload)
    // {
    //     uint8 typeNum;
    //     (typeNum, payload) = abi.decode(data, (uint8, bytes));

    //     if (typeNum > uint8(ICCIPHandler.MessageType.SYNC_RESPONSE)) {
    //         revert InvalidMessageType();
    //     }

    //     messageType = ICCIPHandler.MessageType(typeNum);
    // }

    // ============ REQUEST ID GENERATION ============

    /// @notice Generate unique withdrawal request ID
    /// @dev Includes chain info to prevent cross-chain collisions
    function generateRequestId(
        uint64 sourceChain,
        address owner,
        address receiver,
        uint256 shares,
        uint256 timestamp,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    sourceChain,
                    owner,
                    receiver,
                    shares,
                    timestamp,
                    nonce
                )
            );
    }
}
