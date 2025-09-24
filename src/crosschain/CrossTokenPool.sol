// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;
import {TokenPool} from "../../lib/ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {IERC20} from "../../lib/ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pool} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";

contract CrossTokenPool is TokenPool {
    constructor(
        IERC20 _token,
        address[] memory allowlist,
        address _rmnProxy,
        address _router
    ) TokenPool(_token, 18, allowlist, _rmnProxy, _router) {}

    // called when going to send tokens from this pool to the destination pool
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(lockOrBurnIn);
        address orignalSender = abi.decode(
            lockOrBurnIn.originalSender,
            (address)
        );
        // custom logic to perform here

        // after the custom logic burn the tokens from this pool before sending them
        // i_token.burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.endcode("custom data like interest rate")
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintV1 calldata releaseOrMintIn
    ) external returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);

        // custom logic before releasing or minting the token
        return
            Pool.ReleaseOrMintOutV1({
                destinationAmount: releaseOrMintIn.amount
            });
    }
}
