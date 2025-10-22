// SPDX-License-Identifer: MIT

pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {HubVault} from "src/core/HubVault.sol";
import {CrossToken} from "src/CrossToken.sol";

contract HubVaultTest is Test {
    HubVault vault;
    ERC20Mock WETH;
    ERC20Mock USDC;
    ERC20 crossToken;
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address lp = makeAddr("LP");
    address lp2 = makeAddr("LP222");

    function setUp() public {}
    ///////////////////////////////////////////////
    // DEPOSIT
    //////////////////////////////////////////////

    function testDepositToVaultBeforeYeild() public {}

    // uint256 userShares = vault.balanceOf(userAddress);
    // uint256 userAssets = vault.previewRedeem(userShares);

    function testMintToVaultBeforeYeild() public {}

    function testWithdraw() public {}

    function testTwoDifferentTokensInVault() public {}

    // Minting
    function testMinting() public {
        //
    }

    function testRedeem() public {
        //
    }
}
