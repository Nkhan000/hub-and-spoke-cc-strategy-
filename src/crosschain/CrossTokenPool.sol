// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {TokenPool} from "../../lib/ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {Pool} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {IERC20} from "../../lib/ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

// import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// import {IERC20} from "../../lib/ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract CrossTokenPool is TokenPool {
    using SafeERC20 for IERC20;

    error ZeroToken();
    error ZeroRouter();

    IERC20 private immutable i_TOKEN;
    address private immutable i_router;
    address private immutable i_RMNProxy;

    // bookkeeping
    mapping(uint64 => uint256) public lockedAmountPerChain;
    mapping(uint64 => bytes) public remotePoolAddress; // abi.encode(remotePoolAddress)
    mapping(uint64 => bytes) public remoteTokenAddress; // abi.encode(remoteTokenAddress)

    event Locked(address sender, uint64 remoteChain, uint256 amount);
    event Released(
        address caller,
        address receiver,
        uint64 remoteChain,
        uint256 amount
    );
    event RemotePoolSet(
        uint64 remoteChain,
        bytes remotePoolAddr,
        bytes remoteTokenAddr
    );

    constructor(
        IERC20 _token,
        address _rmnProxy,
        address _router,
        uint8 _decimals,
        address[] memory allowlist
    ) TokenPool(_token, _decimals, allowlist, _rmnProxy, _router) {
        //
        if (address(_token) == address(0)) revert ZeroToken();
        if (_router == address(0)) revert ZeroRouter();
        i_TOKEN = _token;
        i_router = _router;
        i_RMNProxy = _rmnProxy;
    }

    // called when going to send tokens from this pool to the destination pool
    // @notice burns the token on the source chain
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(lockOrBurnIn);
        // custom logic to perform here

        // after the custom logic burn the tokens from this pool before sending them
        // i_TOKEN.burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode("custom data like interest rate")
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);

        //     // Step 1: Transfer the bridged tokens from TokenPool to HubVault
        //     i_TOKEN.safeTransfer(address(i_hubVault), releaseOrMintIn.amount);

        //     // Step 2: Notify HubVault of arrival
        //     (uint64 sourceChain,) = abi.decode(releaseOrMintIn.extraData, (uint64, address));
        //     i_hubVault.onTokensReceived(sourceChain, releaseOrMintIn.amount, releaseOrMintIn.extraData);

        // custom logic before releasing or minting the token

        // transfer out the token
        // IERC20(token()).safeTransfer(receiver, amount);
        // eg
        // This will also mint any interest that has accrued since the last time the user's balance was updated.
        // IRebaseToken(address(i_TOKEN)).mint(receiver, releaseOrMintIn.amount, userInterestRate);

        // step 3
        return
            Pool.ReleaseOrMintOutV1({
                destinationAmount: releaseOrMintIn.amount
            });
    }
}

// function releaseOrMint(
//     Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
// ) external override onlyRMNProxy returns (Pool.ReleaseOrMintOutV1 memory) {
//     // Step 1: Transfer the bridged tokens from TokenPool to HubVault
//     i_TOKEN.safeTransfer(address(i_hubVault), releaseOrMintIn.amount);

//     // Step 2: Notify HubVault of arrival
//     (uint64 sourceChain,) = abi.decode(releaseOrMintIn.extraData, (uint64, address));
//     i_hubVault.onTokensReceived(sourceChain, releaseOrMintIn.amount, releaseOrMintIn.extraData);

//     emit ReleasedToVault(sourceChain, releaseOrMintIn.amount);

//     // Step 3: Return the struct expected by Chainlink CCIP
//     return Pool.ReleaseOrMintOutV1({
//         destinationAmount: releaseOrMintIn.amount
//     });
// }
