// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {MainVault} from "../core/MainVault.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract CCIPHandler is CCIPReceiver, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // ====================
    // ERRORS
    // =====================
    error Periphery__InvalidMessageType(uint8 messageType);
    error CCIPHandler__LengthMismatch();

    // it will be abstract for the periphery.
    // it should be able to receive/send tokens cross chain
    // it should be able to receive operations to perform
    // handle deposit
    // handle withdraw -> addToProcess, cancelProcess, updateProcess, checkStatus, claimProcess
    //

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, CCIPReceiver) returns (bool) {
        return
            AccessControl.supportsInterface(interfaceId) ||
            CCIPReceiver.supportsInterface(interfaceId);
    }

    enum MessageType {
        // Hub -> Spoke
        DEPOSIT_CONFIRMED, // Confirm deposit, credit shares
        BURN_SHARES, // Send withdrawal tokens to user
        WITHDRAW_UPDATE, // Notify withdrawal is queued
        WITHDRAW_READY, // Notify withdrawal is ready to claim
        WITHDRAW_CANCEL, // Request cancellation
        // WITHDRAW_CANCEL, // Confirm cancellation
        // Spoke -> Hub
        DEPOSIT_REQUEST, // Request deposit with tokens
        WITHDRAW_REQUEST, // Request withdrawal
        WITHDRAW_CLAIM, // Claim ready withdrawal
        // Bidirectional
        HEARTBEAT, // Health check
        SYNC_REQUEST, // Request state sync
        SYNC_RESPONSE // State sync response
    }
    /// @notice Configuration for a supported chain
    struct ChainConfig {
        uint64 chainSelector; // CCIP chain selector
        address periphery; // Periphery contract address
        bool isActive; // Whether chain is enabled
        uint256 gasLimit; // Gas limit for messages to this chain
    }

    /// @notice Cross-chain message envelope
    struct CCIPMessage {
        bytes32 messageId; // CCIP message ID
        uint64 sourceChain; // Source chain selector
        uint64 destChain; // Destination chain selector
        address sender; // Original sender
        MessageType messageType; // Type of message
        bytes payload; // Encoded payload data
        uint256 timestamp; // When message was sent
    }
    struct MessageStatus {
        bytes32 messageId;
        bool delivered;
        bool processed;
        uint256 deliveredAt;
        bytes32 responseMessageId; // If response was sent
    }

    // ===============================
    // STATES
    // ===============================

    /// @notice Set of supported chain selectors
    EnumerableSet.UintSet internal _supportedChains;

    /// @notice Chain selector -> configuration
    mapping(uint64 => ChainConfig) internal _chainConfigs;

    /// @notice Message ID -> status
    // mapping(bytes32 => MessageStatus) internal _messageStatuses;

    /// @notice Processed message IDs (replay protection)
    mapping(bytes32 => bool) internal _processedMessages;

    /// @notice Default gas limit for cross-chain messages
    uint256 public defaultGasLimit;

    /// @notice This chain's selector
    uint64 public immutable thisChainSelector;

    /// @notice Address of the main Vault
    MainVault private vault;

    address private ROUTER;

    constructor(address _vault, address _router) CCIPReceiver(_router) {
        if (_router == address(0))
            revert("Invalid Address for Router provided");
        ROUTER = _router;
        vault = MainVault(_vault);
        defaultGasLimit = 500_000;
    }

    // Receive tokens/opr
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override nonReentrant {
        // verify the soruce chain
        uint64 sourceChain = message.sourceChainSelector;
        if (!_supportedChains.contains(sourceChain)) {
            revert("INVALID CHAIN");
        }
        // validate whether the chain is active or not -> TODO:
        // validate sender -> allowed periphery sending messages from the other chain ....
        address sender = abi.decode(message.sender, (address));

        // replay protection verify the msgId from the payload
        bytes32 msgId = message.messageId;
        if (_processedMessages[msgId]) revert("Message already processed");
        _processedMessages[msgId] = true;

        // decoding the payload (address of owner of shares(provider) and type of operation)
        (
            address owner,
            MessageType messageType,
            bytes memory payload
        ) = _unwrapMessage(message.data);

        // perform action based on the message type and the payload
        _routeMessage(
            messageType,
            payload,
            owner,
            sourceChain,
            sender,
            message.destTokenAmounts
        );

        // add the message status for the status of the message ... maybe ??
    }

    function sendCCIPMessage(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint64 _chain,
        address _reciever,
        MessageType _type,
        bytes memory _data
    ) external payable nonReentrant returns (bytes32) {
        // chain validation
        if (!_supportedChains.contains(_chain)) {
            revert("INVALID CHAIN");
        }
        if (_tokens.length != _amounts.length)
            revert("Token amounts length mismatched");

        uint256 len = _tokens.length;
        // pulling tokens from the senders
        for (uint256 i = 0; i < len; i++) {
            IERC20(_tokens[i]).safeTransferFrom(
                msg.sender,
                address(this),
                _amounts[i]
            );
        }
        // Creating _tokens _amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](len);

        for (uint256 i = 0; i < len; i++) {
            tokenAmounts[i] = Client.EVMTokenAmount({
                token: _tokens[i],
                amount: _amounts[i]
            });

            IERC20(_tokens[i]).approve(ROUTER, 0);
            IERC20(_tokens[i]).approve(ROUTER, _amounts[i]);
        }

        bytes memory data = abi.encode(_reciever, _type, _data);

        // here receiver is address of user on the other chain to receive tokens

        // creating a CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_chainConfigs[_chain].periphery), // periphery on the other chain to receive tokens
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: address(0), // Pay in native
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: _chainConfigs[_chain].gasLimit
                })
            )
        });

        // calculate fee
        uint256 fee = IRouterClient(ROUTER).getFee(_chain, message);
        if (fee == 0) revert("Invalid CCIP Fee/Invalid Message");
        if (msg.value < fee) revert("Fee amount is insufficient");

        // send message
        bytes32 messageId = IRouterClient(ROUTER).ccipSend(_chain, message);
        return messageId;
    }

    // ========================
    // CHAIN CONFIG
    // ========================

    // add access guard
    function setChainConfig(
        uint64 chainSelector,
        address remotePeriphery,
        bool isActive,
        uint256 gasLimit
    ) external {
        require(chainSelector != 0, "CHAIN_ZERO");
        require(remotePeriphery != address(0), "REMOTE_ZERO");
        _chainConfigs[chainSelector] = ChainConfig({
            chainSelector: chainSelector, // CCIP chain selector
            periphery: remotePeriphery, // Periphery contract address
            isActive: isActive, // Whether chain is enabled
            gasLimit: gasLimit
        });
        // emit
    }

    // PERIPHERY -> ON MAINNET
    // DEPOSIT -> RECEIVING DEPOSIT AND MINTING SHARES ON VAULT
    // WITHDRAW REQUEST -> ADDING WITHDRAW TO QUEUE                         --------- USER ON THE OTHER SHOULD KNOW THE REQUEST ID TO PROCESS
    // CLAIMING REQUEST -> IF CLAIMABLE THEN SEND TOKENS TO THE DEPOSITOR -----------
    // CANCEL REQUEST -> IF CANCELABLE THEN CANCEL THE WITHDRAW REQUEST

    // ===============================
    // HANDLERS INBOUND
    // ===============================

    // send tokens/message

    // handle deposit

    function _handleDepositConfirmed(
        address _receiver,
        uint64 _sourceChain,
        uint256 _minSharesOut,
        Client.EVMTokenAmount[] memory _tokensAmount
    ) internal {
        uint256 len = _tokensAmount.length;
        if (len > 10 || len == 0) revert("Invalid length of tokensAmounts");
        // at this point we assume we have a valid message
        (
            address[] memory tokens,
            uint256[] memory amounts
        ) = _decodeAndValidateEvmTokenAmount(_tokensAmount);

        // MainVault.DepositDetails memory depositDetails =

        // allow this vault to spend tokens from this contract
        _allowTokens(tokens, amounts, address(vault));
        // In this case, this contract already has the tokens from the CCIP router and when .deposit on vault then it will be msg.sender
        vault.deposit(_sourceChain, _receiver, tokens, amounts, _minSharesOut);
    }

    // handle add withdraw
    function _handleAddWithdraw(
        address _owner,
        address _receiver,
        uint256 _sharesToBurn,
        uint64 _chainSelector
    ) internal {
        vault.addWithdrawalInQueue(
            _owner,
            _receiver,
            _sharesToBurn,
            _chainSelector
        );
    }

    function _handleClaimWithdraw(
        bytes32 _requestId,
        address _receiver,
        uint64 _chain,
        bytes memory data
    ) internal {
        //
        MainVault.WithdrawDetails memory details = vault.claimWithdrawal(
            _requestId
        );
        // if code reaches to this point, it means there was no revert while claiming the withdraw and we can process sending the tokens cross chain
        // _allowTokens(details.tokensWithdrawn, details.amountsWithdrawn, ROUTER);
    }

    // if(details.tokensWithdrawn.length > 0)

    function _handleUpdateWithdraw(bytes32 _requestId) internal {
        vault.updateWithdrawal(_requestId);
    }

    function _handleCancelWithdraw(bytes32 _requestId) internal {
        vault.cancelWithdrawal(_requestId);
    }

    // we will implement the getters for cross chain users later
    function _handleGetShareInfo() internal {
        // vault.getShareInfo(_sourceChain, _owner);
        // then initiates a cross chain
    }

    function _handleGetWithdrawStatus() internal {}

    // ========================
    // HANDLERS OUTBOUND
    // ========================

    // SEND DEPOSIT
    // SEND WITHDRAW REQUEST

    // =======================
    // INTERNALS
    // =======================

    function _routeMessage(
        MessageType _msgType,
        bytes memory _payload,
        address user,
        uint64 sourceChain,
        address periphery,
        Client.EVMTokenAmount[] memory _tokensAmount
    ) internal {
        (
            address receiver,
            uint256 minSharesOut,
            uint256 sharesToBurn,
            bytes32 requestId
        ) = _unwrapPayload(_payload);

        if (_msgType == MessageType.DEPOSIT_CONFIRMED) {
            _handleDepositConfirmed(
                receiver,
                sourceChain,
                minSharesOut,
                _tokensAmount
            );
        } else if (_msgType == MessageType.BURN_SHARES) {
            _handleAddWithdraw(periphery, receiver, sharesToBurn, sourceChain);
        } else if (_msgType == MessageType.WITHDRAW_UPDATE) {
            _handleUpdateWithdraw(requestId);
        } else if (_msgType == MessageType.WITHDRAW_CANCEL) {
            _handleCancelWithdraw(requestId);
        } else if (_msgType == MessageType.WITHDRAW_CLAIM) {
            _handleClaimWithdraw(requestId, receiver, sourceChain, "");
        } else {
            revert Periphery__InvalidMessageType(uint8(_msgType));
        }
    }

    function _unwrapMessage(
        bytes memory data
    )
        internal
        pure
        returns (
            address reciever,
            MessageType messageType,
            bytes memory payload
        )
    {
        uint8 typeNum;
        (reciever, typeNum, payload) = abi.decode(
            data,
            (address, uint8, bytes)
        );

        if (typeNum > uint8(MessageType.SYNC_RESPONSE)) {
            revert("Invalid Message Type");
        }

        if (reciever == address(0)) revert("Invalid receiver address");
        messageType = MessageType(typeNum);
    }

    function _unwrapPayload(
        bytes memory _payload
    )
        internal
        pure
        returns (
            address receiver,
            uint256 minShares,
            uint256 sharesToBurn,
            bytes32 requestId
        )
    {
        (receiver, minShares, sharesToBurn, requestId) = abi.decode(
            _payload,
            (address, uint256, uint256, bytes32)
        );
    }

    function _allowTokens(
        address[] memory tokens,
        uint256[] memory amounts,
        address spender
    ) internal {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; ) {
            address token = tokens[i];
            IERC20(token).approve(spender, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _decodeAndValidateEvmTokenAmount(
        Client.EVMTokenAmount[] memory tokenAmtsArr
    )
        internal
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 len = tokenAmtsArr.length;
        if (len == 0 || len > 10)
            // tokens length from the main
            revert CCIPHandler__LengthMismatch();

        tokens = new address[](len);
        amounts = new uint256[](len);

        for (uint16 i = 0; i < len; i++) {
            address tokenAddr = tokenAmtsArr[i].token;
            uint256 tokenAmt = tokenAmtsArr[i].amount;
            tokens[i] = tokenAddr;
            amounts[i] = tokenAmt;
        }
        return (tokens, amounts);
    }
}
