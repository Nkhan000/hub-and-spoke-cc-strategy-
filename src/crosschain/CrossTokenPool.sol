// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {TokenPool} from "../../lib/ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {IERC20} from "../../lib/ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Pool} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {IERC20} from "../../lib/ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract CrossTokenPool is TokenPool {
    using SafeERC20 for IERC20;

    mapping(uint64 => address) private remoteTokens;

    event RemoteTokenSet(uint64 chainSelector, address tokenAddress);

    constructor(
        IERC20 _token,
        address[] memory allowlist,
        address _rmnProxy,
        address _router
    )
        TokenPool(
            _token,
            IERC20Metadata(address(_token)).decimals(),
            allowlist,
            _rmnProxy,
            _router
        )
    {}

    function setRemoteToken(
        uint64 chainSelector,
        address tokenAddress
    ) external onlyOwner {
        require(tokenAddress != address(0), "Invalid Token");
        require(chainSelector != 0, "Invalid Chain Selector");
        remoteTokens[chainSelector] = tokenAddress;
        emit RemoteTokenSet(chainSelector, tokenAddress);
    }

    // Match the base signature exactly; TokenPool may define this external view virtual
    // function getRemoteToken(
    //     uint64 chainSelector
    // ) public view virtual override returns (address) {
    //     address token = remoteTokens[chainSelector];
    //     require(token != address(0), "Remote token not set");
    //     return token;
    // }

    // called when going to send tokens from this pool to the destination pool
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(lockOrBurnIn);
        address orignalSender = lockOrBurnIn.originalSender;
        // custom logic to perform here

        // after the custom logic burn the tokens from this pool before sending them
        // i_token.burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode("custom data like interest rate")
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);

        // custom logic before releasing or minting the token

        // transfer out the token
        // IERC20(token()).safeTransfer(receiver, amount);

        return
            Pool.ReleaseOrMintOutV1({
                destinationAmount: releaseOrMintIn.amount
            });
    }

    // function bridgeTokens(
    //     uint256 amountTOBridge,
    //     uint256 localFork,
    //     uint256 remoteFork,
    //     Register.NetworkDetails memory localNetworkDetails,
    //     Register.NetworkDetails memory remoteNetworkDetails,
    //     address localToken,
    //     address rebaseToken
    // ) public {}
}
