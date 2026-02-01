// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
// import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
// import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
// import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
// import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
// import {MainVault} from "../core/MainVault.sol";
// import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
// import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";

// // import {HubVault} from "../core/HubVault.sol";
// /**
//  * @title  Periphery
//  * @notice Contract for Periphery contract that coordinates deposits/withdrawals
//  * @dev Handles both native (same-chain) and cross-chain operations via CCIP
//  * Works with main Vault that extends abstract Vault contract with multi-asset support
//  * Main periphery (on vault chain) inherits CCIPReceiver
//  * Remote peripheries (on other chains) send messages to main periphery
//  */

// contract BasePeriphery is
//     CCIPReceiver,
//     AccessControl,
//     Pausable,
//     ReentrancyGuard
// {
//     using SafeERC20 for IERC20;
//     using EnumerableSet for EnumerableSet.AddressSet;

//     function supportsInterface(
//         bytes4 interfaceId
//     ) public view override(AccessControl, CCIPReceiver) returns (bool) {
//         return
//             AccessControl.supportsInterface(interfaceId) ||
//             CCIPReceiver.supportsInterface(interfaceId);
//     }

//     // ================================================================
//     // ERRORS
//     // ================================================================
//     error BasePeriphery__ZeroAddress();
//     error BasePeriphery__LengthMismatch();
//     error BasePeriphery__UnsupportedToken(address token);
//     error BasePeriphery__ChainNotAllowed(uint64 selector);
//     error BasePeriphery__ProviderInactive(address provider);
//     error BasePeriphery__InvalidShares();
//     error BasePeriphery__RequestNotFound(uint8 requestId);
//     error BasePeriphery__RequestAlreadyProcessed(uint8 requestId);
//     // error BasePeriphery__UnsupportedToken();
//     error BasePeriphery__InvalidOrSupportedTokensReceived();

//     // ================================================================
//     // EVENTS
//     // ================================================================
//     event ProviderRequestSubmitted(
//         uint8 indexed requestId,
//         address indexed provider,
//         uint64 indexed chainSelector
//     );

//     event ProviderRequestAccepted(
//         uint8 indexed requestId,
//         address indexed provider,
//         uint64 indexed chainSelector
//     );

//     event LiquidityReceived(
//         address indexed provider,
//         uint64 indexed sourceChain,
//         uint256 sharesMinted
//     );

//     event WithdrawalRequested(address indexed provider, uint256 shares);

//     event WithdrawalProcessed(
//         address indexed provider,
//         uint64 indexed destinationChain,
//         uint256[] tokenAmounts
//     );

//     event SupportedTokenAdded(address token, address priceFeed);
//     event TokenRemoved(address token);

//     event CrossChainMessageReceived();

//     event CCIPMessageSent(
//         bytes32 messageId,
//         Client.EVM2AnyMessage message,
//         uint256 fee
//     );

//     event BasePeriphery__FundsWithdrawn(
//         address provider,
//         uint256 shares,
//         uint256[] amountsReceived,
//         address[] tokensReceived,
//         bool isCrossChain
//     );

//     // ================================================================
//     // STRUCTS
//     // ================================================================

//     struct LiquidityProvider {
//         address provider;
//         uint256 lastActivity; // block timestamp for accounting / cooldowns
//         uint64 chainSelector;
//         bool isActive; // controls deposit/withdraw access
//     }

//     struct ProviderRequest {
//         uint8 requestId;
//         address provider;
//         uint64 chainSelector; // origin or destination chain
//         uint256 requestedAt;
//         bool isAccepted;
//         bool isCompleted;
//     }

//     // ================================================================
//     // STORAGE
//     // ================================================================
//     mapping(address => LiquidityProvider) public providers;
//     mapping(bytes32 => bool) public processedMessages;
//     mapping(uint8 => ProviderRequest) public providerRequests;
//     mapping(uint64 chainId => mapping(address sender => bool))
//         public isAllowedSender;

//     // uint64[] internal allowedChains;
//     mapping(uint64 => bool) public allowedChains;
//     // Storage for tracking approvals
//     mapping(address => bool) private _approvedToVault;

//     uint8 internal nextRequestId;
//     MainVault main;

//     // ================================================================
//     // CONSTANTS
//     // ================================================================
//     uint16 public constant MAX_ALLOWED_CHAINS = 4;
//     uint256 public constant TOLERANCE = 1000;
//     bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
//     address public ROUTER;
//     address public LINK_TOKEN;

//     // ================================================================
//     // MODIFIERS
//     // ================================================================

//     // ================================================================
//     // CONSTRUCTOR
//     // ================================================================
//     constructor(
//         address _router,
//         address _linkToken,
//         address _main
//     ) CCIPReceiver(_router) {
//         if (
//             _router == address(0) ||
//             _main == address(0) ||
//             _linkToken == address(0)
//         ) revert BasePeriphery__ZeroAddress();

//         main = MainVault(_main);

//         ROUTER = _router;
//         LINK_TOKEN = _linkToken;

//         _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//         _grantRole(OPERATOR_ROLE, msg.sender);
//     }

//     function setAllowedChains(
//         uint64[] memory _chainSelectors
//     ) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         for (uint16 i = 0; i < _chainSelectors.length; i++) {
//             uint64 chain = _chainSelectors[i];
//             bool supported = IRouterClient(ROUTER).isChainSupported(chain);
//             if (supported) allowedChains[chain] = true;
//         }
//     }

//     // ================================================================
//     // CCIP RECEIVE
//     // ================================================================
//     /**
//      * @notice Entry point for receiving cross-chain messages.
//      * @dev Handles liquidity deposits and withdrawal settlements.
//      *  - Validate source chain selector.
//      *  - Decode message payload (deposit or withdrawal).
//      *  - Route to dedicated internal handler.
//      */
//     function _ccipReceive(
//         Client.Any2EVMMessage memory message
//     ) internal override {
//         bytes32 msgId = message.messageId;
//         if (processedMessages[msgId]) revert("Message already processed");
//         processedMessages[msgId] = true;

//         uint64 sourceChain = message.sourceChainSelector;

//         // check whether chain is allowed
//         if (!allowedChains[sourceChain])
//             revert BasePeriphery__ChainNotAllowed(sourceChain);

//         // Validate chain is active
//         // if (!config.isActive) {
//         //     revert CCIP__ChainNotActive(sourceChain);
//         // }

//         // check whether the sender is allowed or not
//         address sender = abi.decode(message.sender, (address));
//         // if (!isAllowedSender[sourceChain][sender])
//         //     revert("Unauthorized cross-chain sender");

//         // decoding the payload (address of owner of shares(provider) and type of operation)
//         (address provider, uint8 opr, uint256 shares) = abi.decode(
//             message.data,
//             (address, uint8, uint256)
//         );

//         emit CrossChainMessageReceived();
//     }

//     function _routeMessage(
//         uint8 _opcode,
//         address _provider,
//         uint64 _sourceChain,
//         uint256 _shares,
//         Client.EVMTokenAmount calldata _tokensAmount
//     ) internal {
//         // opr 1 => deposit, 2 => withdraw, 3 => getSharesAmtUsd
//         if (_opcode == uint8(1)) {
//             _handleCrossChainDeposit(_provider, _tokensAmount, _sourceChain);
//         } else if (_opcode == uint8(2)) {
//             _handleCrossChainWithdrawal(_provider, _shares, _sourceChain);
//         } else {
//             revert("Invalid Opcode Provided");
//         }
//         // get shares - get total share values .. aply this opcodes as well
//     }

//     // =============================================
//     // CROSS CHAIN MESSAGE SEND
//     // =============================================

//     function _sendCCIPMessage(
//         address[] memory tokens,
//         uint256[] memory amounts,
//         address _receiver,
//         uint64 _chainSelector,
//         bytes memory _data
//     ) internal {
//         bool supportedChain = allowedChains[_chainSelector];
//         if (!supportedChain)
//             revert("chain not supported for cross chain messaging");

//         if (tokens.length != amounts.length) revert("Invalid length");
//         uint256 len = tokens.length;

//         Client.EVMTokenAmount[]
//             memory tokenAmounts = new Client.EVMTokenAmount[](len);

//         // 1. Approve token pool for this token
//         // Get the correct token pool for this token + chain
//         for (uint16 i = 0; i < len; ) {
//             address token = tokens[i];
//             uint256 amt = amounts[i];

//             // Safely approving ROUTER to spend the asset
//             IERC20(token).forceApprove(ROUTER, amt);

//             tokenAmounts[i] = Client.EVMTokenAmount({
//                 token: token,
//                 amount: amt
//             });

//             unchecked {
//                 ++i;
//             }
//         }

//         bytes memory data = _data;

//         // create the CCIP message to send
//         Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
//             receiver: abi.encode(_receiver),
//             data: data,
//             tokenAmounts: tokenAmounts,
//             extraArgs: Client._argsToBytes(
//                 Client.EVMExtraArgsV1({gasLimit: 200_000})
//             ),
//             feeToken: LINK_TOKEN
//         });

//         // decision are yet to be made to use native tokens as fees or link token
//         // for now we will stick with link tokens

//         // calculate fee
//         uint256 fee = IRouterClient(ROUTER).getFee(_chainSelector, message);
//         if (fee == 0) revert("Invalid CCIP Fee");
//         uint256 linkBalance = IERC20(LINK_TOKEN).balanceOf(address(this));
//         if (linkBalance < fee) revert("Insufficient LINK for fees");
//         IERC20(LINK_TOKEN).approve(address(ROUTER), fee);

//         // send message
//         bytes32 messageId = IRouterClient(ROUTER).ccipSend(
//             _chainSelector,
//             message
//         );

//         emit CCIPMessageSent(messageId, message, fee);
//     }

//     // ===================================================
//     // DEPOSIT/ WITHDRAW
//     // ===================================================

//     /**
//      * @notice for native senders
//      * @param provider Receiver of the shares after depositing tokens
//      * @param tokens tokens array
//      * @param amounts amounts array
//      */
//     function deposit(
//         address provider,
//         address[] memory tokens,
//         uint256[] memory amounts
//     )
//         public
//         nonReentrant
//         whenNotPaused
//         returns (MainVault.DepositDetails memory)
//     {
//         return _handleDeposit(provider, tokens, amounts, false, 0);

//         // emit BasePeriphery__DepositReceived(provider, tokens, amounts);
//     }

//     /**
//      * @param provider address of provider from the different chain
//      * @param tokenAmtsArr array of tokens and respective amounts
//      * @param sourceChain chain selector from where the transaction initiated
//      */
//     function _handleCrossChainDeposit(
//         address provider,
//         Client.EVMTokenAmount[] memory tokenAmtsArr,
//         uint64 sourceChain
//     ) internal returns (MainVault.DepositDetails memory) {
//         (
//             address[] memory tokens,
//             uint256[] memory amounts
//         ) = _decodeAndValidateEvmTokenAmount(tokenAmtsArr);

//         // CCIP already delivered tokens to this contract
//         return _handleDeposit(provider, tokens, amounts, true, sourceChain);
//     }

//     function _handleDeposit(
//         address provider,
//         address[] memory assets,
//         uint256[] memory amounts,
//         bool isCrossChain,
//         uint64 sourceChain
//     ) internal returns (MainVault.DepositDetails memory depositDetails) {
//         uint256 len = assets.length;
//         address[] memory supportedAssets = main.getSupportedAssets();
//         if (len > supportedAssets.length || len == 0)
//             revert("Invalid length of tokens or amounts");

//         // bool containsUnsupported = false;
//         // check for unsupported asset. If unsupported asset than revert entire batch
//         for (uint256 i = 0; i < len; ) {
//             if (!main.isActiveAsset(assets[i])) {
//                 if (isCrossChain) {
//                     _sendCCIPMessage(
//                         assets,
//                         amounts,
//                         provider,
//                         sourceChain,
//                         ""
//                     );
//                 }
//                 revert BasePeriphery__InvalidOrSupportedTokensReceived();
//             }
//             unchecked {
//                 ++i;
//             }
//         }

//         // now all the tokens are active/supported
//         for (uint256 i = 0; i < len; ) {
//             address asset = assets[i];
//             uint256 amt = amounts[i];

//             if (amt != 0) {
//                 if (!isCrossChain) {
//                     IERC20(asset).safeTransferFrom(
//                         provider,
//                         address(this),
//                         amt
//                     );
//                 }
//                 // IERC20(asset).forceApprove(address(main), type(uint256).max); // maximum approval
//                 if (!_approvedToVault[asset]) {
//                     IERC20(asset).forceApprove(
//                         address(main),
//                         type(uint256).max
//                     );
//                     _approvedToVault[asset] = true;
//                 }
//             }

//             unchecked {
//                 ++i;
//             }
//         }
//         // sends the supported assets to the main (list may contain duplicate but will be filtered on vault end)
//         depositDetails = main.deposit(provider, assets, amounts);
//     }

//     // =====================================
//     // WITHDRAWAL FUNCTIONS
//     // =====================================

//     /**
//      * @notice native user calls this function for withdrawing their shares on main
//      * @param shares amount of shares to burn
//      * @dev In this case msg.sender can be the address of provider for _handleWithdraw function as it is a native user
//      */
//     function withdraw(
//         uint256 shares
//     )
//         external
//         nonReentrant
//         whenNotPaused
//         returns (MainVault.WithdrawDetails memory withdrawDetails)
//     {
//         if (shares == 0) revert BasePeriphery__InvalidShares();

//         // emit
//         return _handleWithdraw(msg.sender, shares, false);
//     }

//     /**
//      * @param provider address of the user who owns the shares
//      * @param shares amount of shares to burn
//      * @param isCrossChain Boolean for whether operation is for cross chain or native chain
//      */
//     function _handleWithdraw(
//         address provider,
//         uint256 shares,
//         bool isCrossChain
//     ) internal returns (MainVault.WithdrawDetails memory withdrawDetails) {
//         if (shares == 0) revert BasePeriphery__InvalidShares();

//         if (provider == address(0)) revert BasePeriphery__ZeroAddress();
//         // calculate the balance before the withdraw -> will help in cross chain function

//         if (!isCrossChain) {
//             withdrawDetails = main.withdraw(provider, shares); // withdraws assets to the native users
//         } else {
//             withdrawDetails = main.withdrawTo(provider, shares); // withdraws assets to the periphery
//         }
//         emit BasePeriphery__FundsWithdrawn(
//             provider,
//             shares,
//             withdrawDetails.amountsReceived,
//             withdrawDetails.tokensReceived,
//             isCrossChain
//         );
//     }

//     function _handleCrossChainWithdrawal(
//         address provider,
//         uint256 shares,
//         uint64 _sourceChainSelector
//     ) internal {
//         // check for balance received when withdraw funds
//         // (, , uint256 expectedValue) = main.previewWithdraw(shares);
//         MainVault.WithdrawDetails memory withdrawDetails = _handleWithdraw(
//             provider,
//             shares,
//             true
//         );

//         // create a ccip message and send the funds to the original sender
//         _sendCCIPMessage(
//             withdrawDetails.tokensReceived,
//             withdrawDetails.amountsReceived,
//             provider,
//             _sourceChainSelector,
//             bytes("")
//         );
//     }

//     function _decodeAndValidateEvmTokenAmount(
//         Client.EVMTokenAmount[] memory tokenAmtsArr
//     )
//         internal
//         view
//         returns (address[] memory tokens, uint256[] memory amounts)
//     {
//         uint256 len = tokenAmtsArr.length;
//         if (len == 0 || len > main.MAX_ALLOWED_TOKENS())
//             // tokens length from the main
//             revert BasePeriphery__LengthMismatch();

//         tokens = new address[](len);
//         amounts = new uint256[](len);

//         for (uint16 i = 0; i < len; i++) {
//             address tokenAddr = tokenAmtsArr[i].token;
//             uint256 tokenAmt = tokenAmtsArr[i].amount;
//             tokens[i] = tokenAddr;
//             amounts[i] = tokenAmt;
//         }
//         return (tokens, amounts);
//     }

//     // ================================================================
//     // PROVIDER REQUEST FLOW (origin chain)
//     // ================================================================
//     /**
//      * @notice Called by provider before sending tokens cross-chain.
//      * TODO:
//      *  - store request
//      *  - generate requestId
//      */
//     function submitProviderRequest(
//         uint64 chainSelector
//     ) external returns (uint8 requestId) {
//         // TODO
//     }

//     /**
//      * @notice Admin approves provider request before CCIP deposit.
//      * @dev Allows controlled onboarding.
//      * TODO:
//      *  - mark request accepted
//      */
//     function acceptProviderRequest(
//         uint8 requestId
//     ) external onlyRole(OPERATOR_ROLE) {
//         //
//     }

//     // ================================================================
//     // WITHDRAWAL FLOW
//     // ================================================================
//     /**
//      * @notice Provider initiates a withdrawal.
//      * TODO:
//      *  - validate provider active
//      *  - validate shares
//      *  - record pending withdrawal
//      *  - event
//      */
//     function requestWithdrawal(uint256 shares) external nonReentrant {
//         // TODO
//     }

//     /**
//      * @notice Operator triggers cross-chain withdrawal execution.
//      * TODO:
//      *  - encode CCIP payload for withdrawal
//      *  - send to remote chain
//      *  - event
//      */
//     function executeWithdrawal(
//         address provider,
//         uint64 destinationChain
//     ) external onlyRole(OPERATOR_ROLE) {
//         // TODO
//     }

//     // ================================================================
//     // ADMIN / TOKEN MANAGEMENT
//     // ================================================================

//     function setAllowedSender(
//         uint64 chainId,
//         address sender,
//         bool allowed
//     ) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         isAllowedSender[chainId][sender] = allowed;
//     }

//     function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
//         paused() ? _unpause() : _pause();
//     }

//     // ================================================================
//     // VIEW HELPERS
//     // ================================================================

//     function getPriceFeed(address token) external view returns (address) {
//         // return address(tokenInformations[token].priceFeed);
//     }

//     function isChainAllowed(uint64 selector) public view returns (bool) {
//         return allowedChains[selector];
//     }
// }

// // periphery -> spoke vault -> hub -> strategies
// // periphery -> vault -> strategies
