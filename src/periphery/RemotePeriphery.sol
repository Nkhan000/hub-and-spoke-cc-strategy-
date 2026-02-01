// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
// import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
// import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
// import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
// import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
// // import {SpokeVault} from "../core/SpokeVault.sol";
// import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
// import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";

// /**
//  * @title RemotePeriphery
//  * @notice Helper contract for users on other chains to send tokens to Base Periphery
//  */
// contract RemotePeriphery {
//     IRouterClient public immutable ROUTER;
//     address public immutable LINK_TOKEN;
//     uint256 public constant MAX_ALLOWED = 4;

//     struct BasePeriphery {
//         address baseAddress;
//         uint64 chainSelector;
//     }

//     BasePeriphery public basePeriphery;

//     event TokensSentToPeriphery(
//         bytes32 indexed messageId,
//         address indexed user,
//         address[] tokens,
//         uint256[] amounts,
//         address periphery,
//         uint64 chainSelector
//     );

//     constructor(
//         address _router,
//         address _linkToken,
//         address _basePeriphery,
//         uint64 _baseChainSelector
//     ) {
//         if (
//             _router == address(0) ||
//             _basePeriphery == address(0) ||
//             _linkToken == address(0)
//         ) revert("Invalid/Zero address");

//         ROUTER = IRouterClient(_router);
//         LINK_TOKEN = _linkToken;

//         basePeriphery = BasePeriphery({
//             baseAddress: _basePeriphery,
//             chainSelector: _baseChainSelector
//         });
//     }

//     /**
//      * @notice Send tokens from current chain to Periphery on mainnet
//      * @param tokens Token address array on current chain
//      * @param amounts Amounts array to send
//      * @param opr Integer value for type of operation to perform (deposit/withdraw/share balance)
//      * @param shares Mainnet chain selector (amount of shares)
//      */
//     function sendToPeriphery(
//         address[] memory tokens,
//         uint256[] memory amounts,
//         uint8 opr,
//         uint256 shares
//     ) external returns (bytes32 messageId) {
//         // Transfer tokens from user
//         if (tokens.length != amounts.length)
//             revert("Inconsistent length of tokens address and amounts");
//         if (tokens.length > MAX_ALLOWED)
//             revert("Tokens length must be under or equal to MAX_ALLOWED");

//         uint256 len = tokens.length;
//         Client.EVMTokenAmount[]
//             memory tokenAmounts = new Client.EVMTokenAmount[](len);

//         for (uint256 i = 0; i < len; i++) {
//             address token = tokens[i];
//             uint256 amt = amounts[i];
//             // transfering the token to this contract
//             IERC20(token).transferFrom(msg.sender, address(this), amt);

//             // (safe allowance) approving the router to spend the token
//             IERC20(token).approve(address(ROUTER), 0);
//             IERC20(token).approve(address(ROUTER), amt);

//             // Build token amounts
//             tokenAmounts[i] = Client.EVMTokenAmount({
//                 token: token,
//                 amount: amt
//             });
//         }

//         // Encode sender address
//         bytes memory data = abi.encode(msg.sender, opr, shares);

//         // Build CCIP message
//         Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
//             receiver: abi.encode(basePeriphery.baseAddress),
//             data: data,
//             tokenAmounts: tokenAmounts,
//             extraArgs: Client._argsToBytes(
//                 Client.EVMExtraArgsV1({gasLimit: 200_000}) // Gas for periphery processing
//             ),
//             feeToken: LINK_TOKEN
//         });

//         // Get fee and send
//         uint256 fee = ROUTER.getFee(basePeriphery.chainSelector, message);
//         // require(msg.value >= fee, "Insufficient fee");

//         if (fee == 0) revert("Invalid Fee");
//         messageId = ROUTER.ccipSend(basePeriphery.chainSelector, message);

//         emit TokensSentToPeriphery(
//             messageId,
//             msg.sender,
//             tokens,
//             amounts,
//             basePeriphery.baseAddress,
//             basePeriphery.chainSelector
//         );

//         // Refund excess
//         // if (msg.value > fee) {
//         //     payable(msg.sender).transfer(msg.value - fee);
//         // }

//         return messageId;
//     }
// }
