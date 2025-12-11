// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SpokeVault} from "../core/SpokeVault.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";

// import {HubVault} from "../core/HubVault.sol";
/**
 * @title  Periphery
 * @notice Contract for Periphery contract that coordinates deposits/withdrawals
 * @dev Handles both native (same-chain) and cross-chain operations via CCIP
 * Works with Spoke Vault that extends abstract Vault contract with multi-asset support
 * Main periphery (on vault chain) inherits CCIPReceiver
 * Remote peripheries (on other chains) send messages to main periphery
 */

contract BasePeriphery is
    CCIPReceiver,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, CCIPReceiver) returns (bool) {
        return
            AccessControl.supportsInterface(interfaceId) ||
            CCIPReceiver.supportsInterface(interfaceId);
    }

    // ================================================================
    // ERRORS
    // ================================================================
    error BasePeriphery__ZeroAddress();
    error BasePeriphery__LengthMismatch();
    error BasePeriphery__UnsupportedToken(address token);
    error BasePeriphery__ChainNotAllowed(uint64 selector);
    error BasePeriphery__ProviderInactive(address provider);
    error BasePeriphery__InvalidShares();
    error BasePeriphery__RequestNotFound(uint8 requestId);
    error BasePeriphery__RequestAlreadyProcessed(uint8 requestId);

    // ================================================================
    // EVENTS
    // ================================================================
    event ProviderRequestSubmitted(
        uint8 indexed requestId,
        address indexed provider,
        uint64 indexed chainSelector
    );

    event ProviderRequestAccepted(
        uint8 indexed requestId,
        address indexed provider,
        uint64 indexed chainSelector
    );

    event LiquidityReceived(
        address indexed provider,
        uint64 indexed sourceChain,
        uint256 sharesMinted
    );

    event WithdrawalRequested(address indexed provider, uint256 shares);

    event WithdrawalProcessed(
        address indexed provider,
        uint64 indexed destinationChain,
        uint256[] tokenAmounts
    );

    event SupportedTokenAdded(address token, address priceFeed);
    event TokenRemoved(address token);

    event CrossChainMessageReceived();

    event CCIPMessageSent(
        bytes32 messageId,
        Client.EVM2AnyMessage message,
        uint256 fee
    );

    // ================================================================
    // STRUCTS
    // ================================================================

    struct LiquidityProvider {
        address provider;
        uint256 lastActivity; // block timestamp for accounting / cooldowns
        uint64 chainSelector;
        bool isActive; // controls deposit/withdraw access
    }

    struct ProviderRequest {
        uint8 requestId;
        address provider;
        uint64 chainSelector; // origin or destination chain
        uint256 requestedAt;
        bool isAccepted;
        bool isCompleted;
    }

    // ================================================================
    // STORAGE
    // ================================================================
    mapping(address => LiquidityProvider) public providers;
    mapping(bytes32 => bool) public processedMessages;
    mapping(uint8 => ProviderRequest) public providerRequests;
    mapping(uint64 chainId => mapping(address sender => bool))
        public isAllowedSender;

    // uint64[] internal allowedChains;
    mapping(uint64 => bool) public allowedChains;

    uint8 internal nextRequestId;
    SpokeVault spoke;

    // ================================================================
    // CONSTANTS
    // ================================================================
    uint16 public constant MAX_ALLOWED_CHAINS = 4;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public ROUTER;
    address public LINK_TOKEN;

    // ================================================================
    // MODIFIERS
    // ================================================================

    // ================================================================
    // CONSTRUCTOR
    // ================================================================
    constructor(
        address _router,
        address _linkToken,
        address _spoke
    ) CCIPReceiver(_router) {
        if (
            _router == address(0) ||
            _spoke == address(0) ||
            _linkToken == address(0)
        ) revert BasePeriphery__ZeroAddress();

        spoke = SpokeVault(_spoke);

        ROUTER = _router;
        LINK_TOKEN = _linkToken;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function setAllowedChains(
        uint64[] memory _chainSelectors
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint16 i = 0; i < _chainSelectors.length; i++) {
            uint64 chain = _chainSelectors[i];
            bool supported = IRouterClient(ROUTER).isChainSupported(chain);
            if (supported) allowedChains[chain] = true;
        }
    }

    // ================================================================
    // CCIP RECEIVE
    // ================================================================
    /**
     * @notice Entry point for receiving cross-chain messages.
     * @dev Handles liquidity deposits and withdrawal settlements.
     *  - Validate source chain selector.
     *  - Decode message payload (deposit or withdrawal).
     *  - Route to dedicated internal handler.
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        bytes32 msgId = message.messageId;
        if (processedMessages[msgId]) revert("Message already processed");
        processedMessages[msgId] = true;

        uint64 sourceChain = message.sourceChainSelector;

        // check whether chain is allowed
        if (!allowedChains[sourceChain])
            revert BasePeriphery__ChainNotAllowed(sourceChain);

        // check whether the sender is allowed or not
        address sender = abi.decode(message.sender, (address));
        if (!isAllowedSender[sourceChain][sender])
            revert("Unauthorized cross-chain sender");

        // decoding the payload (address of owner of shares(provider) and type of operation)
        (address provider, uint8 opr, uint256 shares) = abi.decode(
            message.data,
            (address, uint8, uint256)
        );

        // opr 1 => deposit, 2 => withdraw, 3 => getSharesAmtUsd
        if (opr == uint8(1)) {
            _handleCrossChainDeposit(
                provider,
                message.destTokenAmounts,
                sourceChain
            );
        } else if (opr == uint8(2)) {
            _handleCrossChainWithdrawal(provider, shares, sourceChain);
        } else {
            revert("Invalid Opcode Provided");
        }
        // get shares - get total share values

        emit CrossChainMessageReceived();
    }

    /**
     * @notice for native senders
     * @param provider Receiver of the shares after depositing tokens
     * @param tokens tokens array
     * @param amounts amounts array
     */
    function deposit(
        address provider,
        address[] memory tokens,
        uint256[] memory amounts
    ) public nonReentrant returns (SpokeVault.DepositDetails memory) {
        return _handleDeposit(provider, tokens, amounts, false);

        // emit BasePeriphery__DepositReceived(provider, tokens, amounts);
    }

    /**
     * @param provider address of provider from the different chain
     * @param tokenAmtsArr array of tokens and respective amounts
     * @param sourceChain chain selector from where the transaction initiated
     */
    function _handleCrossChainDeposit(
        address provider,
        Client.EVMTokenAmount[] memory tokenAmtsArr,
        uint64 sourceChain
    ) internal returns (SpokeVault.DepositDetails memory) {
        (
            address[] memory tokens,
            uint256[] memory amounts
        ) = _decodeAndValidateEvmTokenAmount(tokenAmtsArr);

        // CCIP already delivered tokens to this contract
        return _handleDeposit(provider, tokens, amounts, true);
    }

    function _handleDeposit(
        address provider,
        address[] memory tokens,
        uint256[] memory amounts,
        bool isCrossChain
    ) internal returns (SpokeVault.DepositDetails memory) {
        // this way we only transfer supported tokens to this protocol
        (
            address[] memory supportedTokens,
            uint256[] memory filteredAmounts
        ) = _filterSupportedTokens(tokens, amounts);

        LiquidityProvider storage providerInfo = providers[provider];
        if (!isCrossChain) {
            for (uint16 i = 0; i < supportedTokens.length; i++) {
                address token = supportedTokens[i];
                uint256 amt = filteredAmounts[i];
                if (amt == 0) continue;

                IERC20(token).safeTransferFrom(provider, address(this), amt);
            }
        }
        SpokeVault.DepositDetails memory depositDetails = spoke.deposit(
            provider,
            tokens,
            amounts
        );

        return depositDetails;
    }

    // =====================================
    // WITHDRAWAL FUNCTIONS
    // =====================================

    /**
     * @notice native user calls this function for withdrawing their shares on spoke
     * @param shares amount of shares to burn
     * @dev In this case msg.sender can be the address of provider for _handleWithdraw function as it is a native user
     */
    function withdraw(
        uint256 shares
    ) external returns (SpokeVault.WithdrawDetails memory withdrawDetails) {
        return _handleWithdraw(msg.sender, shares, false);
    }

    /**
     *
     * @param provider address of the user who owns the shares
     * @param shares amount of shares to burn
     * @param isCrossChain Boolean for whether operation is for cross chain or native chain
     */
    function _handleWithdraw(
        address provider,
        uint256 shares,
        bool isCrossChain
    ) internal returns (SpokeVault.WithdrawDetails memory withdrawDetails) {
        // calculate the balance before the withdraw -> will help in cross chain function

        if (!isCrossChain) {
            withdrawDetails = spoke.withdraw(provider, shares);
        } else {
            withdrawDetails = spoke.withdrawTo(provider, shares);
        }
    }

    function _handleCrossChainWithdrawal(
        address provider,
        uint256 shares,
        uint64 _sourceChainSelector
    ) internal {
        // check for balance received when withdraw funds
        (, , uint256 expectedValue) = spoke.quoteWithdraw(shares);
        SpokeVault.WithdrawDetails memory withdrawDetails = _handleWithdraw(
            provider,
            shares,
            true
        );

        require(
            withdrawDetails.withdrawValueInUsd == expectedValue,
            "Invalid Amount Withdrawn"
        );

        // create a ccip message and send the funds to the original sender
        _sendCCIPMessage(
            withdrawDetails.tokensReceived,
            withdrawDetails.amountsReceived,
            provider,
            _sourceChainSelector,
            bytes("")
        );
    }

    // =============================================
    // CROSS CHAIN MESSAGE SEND
    // =============================================

    function _sendCCIPMessage(
        address[] memory tokens,
        uint256[] memory amounts,
        address _receiver,
        uint64 _chainSelector,
        bytes memory _data
    ) internal {
        bool supportedChain = allowedChains[_chainSelector];
        if (!supportedChain)
            revert("chain not supported for cross chain messaging");

        if (tokens.length != amounts.length) revert("Invalid length");
        uint256 len = tokens.length;
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](len);

        // 1. Approve token pool for this token
        // Get the correct token pool for this token + chain
        for (uint16 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 amt = amounts[i];

            // Safely approving ROUTER to spend the asset
            IERC20(token).approve(ROUTER, 0);
            IERC20(token).approve(ROUTER, amt);
            tokenAmounts[i] = Client.EVMTokenAmount({
                token: token,
                amount: amt
            });
        }

        bytes memory data = _data;

        // create the CCIP message to send
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            feeToken: LINK_TOKEN
        });

        // decision are yet to be made to use native tokens as fees or link token
        // for now we will stick with native tokens

        // calculate fee
        uint256 fee = IRouterClient(ROUTER).getFee(_chainSelector, message);
        if (fee == 0) revert("Invalid CCIP Fee");
        uint256 linkBalance = IERC20(LINK_TOKEN).balanceOf(address(this));
        if (linkBalance < fee) revert("Insufficient LINK for fees");
        IERC20(LINK_TOKEN).approve(address(ROUTER), fee);

        // send message
        bytes32 messageId = IRouterClient(ROUTER).ccipSend(
            _chainSelector,
            message
        );

        emit CCIPMessageSent(messageId, message, fee);
    }

    // ===========================================
    function _filterSupportedTokens(
        address[] memory tokens,
        uint256[] memory amounts
    ) internal returns (address[] memory, uint256[] memory) {
        uint256 len = tokens.length;
        uint256 supportedCount = 0;

        for (uint256 i = 0; i < len; i++) {
            if (spoke.isSupportedToken(tokens[i])) supportedCount++;
        }

        address[] memory filtered = new address[](supportedCount);
        uint256[] memory filteredAmounts = new uint256[](supportedCount);
        uint256 j = 0;

        for (uint256 i = 0; i < len; i++) {
            if (spoke.isSupportedToken(tokens[i])) {
                filtered[j] = tokens[i];
                filteredAmounts[j] = amounts[i];
                j++;
            }
        }

        return (filtered, filteredAmounts);
    }

    function _decodeAndValidateEvmTokenAmount(
        Client.EVMTokenAmount[] memory tokenAmtsArr
    ) internal returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 len = tokenAmtsArr.length;
        if (len == 0 || len > spoke.MAX_ALLOWED_TOKENS())
            // tokens length from the spoke
            revert BasePeriphery__LengthMismatch();
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

    // ================================================================
    // PROVIDER REQUEST FLOW (origin chain)
    // ================================================================
    /**
     * @notice Called by provider before sending tokens cross-chain.
     * TODO:
     *  - store request
     *  - generate requestId
     */
    function submitProviderRequest(
        uint64 chainSelector
    ) external returns (uint8 requestId) {
        // TODO
    }

    /**
     * @notice Admin approves provider request before CCIP deposit.
     * @dev Allows controlled onboarding.
     * TODO:
     *  - mark request accepted
     */
    function acceptProviderRequest(
        uint8 requestId
    ) external onlyRole(OPERATOR_ROLE) {
        //
    }

    // ================================================================
    // WITHDRAWAL FLOW
    // ================================================================
    /**
     * @notice Provider initiates a withdrawal.
     * TODO:
     *  - validate provider active
     *  - validate shares
     *  - record pending withdrawal
     *  - event
     */
    function requestWithdrawal(uint256 shares) external nonReentrant {
        // TODO
    }

    /**
     * @notice Operator triggers cross-chain withdrawal execution.
     * TODO:
     *  - encode CCIP payload for withdrawal
     *  - send to remote chain
     *  - event
     */
    function executeWithdrawal(
        address provider,
        uint64 destinationChain
    ) external onlyRole(OPERATOR_ROLE) {
        // TODO
    }

    // ================================================================
    // ADMIN / TOKEN MANAGEMENT
    // ================================================================

    function addTokenInfo() external onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setAllowedSender(
        uint64 chainId,
        address sender,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isAllowedSender[chainId][sender] = allowed;
    }

    function addSupportedToken(
        address token,
        address priceFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // TODO: add new token + feed with checks
    }

    function removeSupportedToken(
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // TODO: remove token from supported list + mapping
    }

    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    // ================================================================
    // VIEW HELPERS
    // ================================================================

    function getPriceFeed(address token) external view returns (address) {
        // return address(tokenInformations[token].priceFeed);
    }

    function isChainAllowed(uint64 selector) public view returns (bool) {
        // TODO: iterate allowedChains
    }
}
