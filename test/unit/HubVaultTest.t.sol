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

    function setUp() public {
        WETH = new ERC20Mock();
        vm.startPrank(owner);
        vault = new HubVault(WETH);
        vm.stopPrank();

        WETH.mint(lp, 200e18);
        WETH.mint(lp2, 200e18);
        vm.prank(lp);
        WETH.approve(address(vault), 100e18);
        vm.prank(lp2);
        WETH.approve(address(vault), 200e18);
    }
    ///////////////////////////////////////////////
    // DEPOSIT
    //////////////////////////////////////////////

    function testDepositToVaultBeforeYeild() public {
        uint256 LP1DEPOSIT = 10e18;
        uint256 LP2DEPOSIT = 200e18;

        vm.prank(lp);
        vault.deposit(LP1DEPOSIT, lp);

        vm.prank(lp2);
        vault.deposit(LP2DEPOSIT, lp2);

        assertEq(vault.balanceOf(lp), LP1DEPOSIT);
        assertEq(vault.balanceOf(lp2), LP2DEPOSIT);
    }

    // uint256 userShares = vault.balanceOf(userAddress);
    // uint256 userAssets = vault.previewRedeem(userShares);

    function testMintToVaultBeforeYeild() public {
        uint256 LP1DEPOSIT = 10e18;
        vm.startPrank(lp);
        vault.deposit(LP1DEPOSIT, lp);

        uint256 shares = 20e18;
        vault.mint(shares, lp);

        assertEq(vault.balanceOf(lp), shares + LP1DEPOSIT);
    }

    function testWithdraw() public {
        uint256 LP1DEPOSIT = 10e18;
        vm.prank(lp);
        vault.deposit(LP1DEPOSIT, lp);
        vm.prank(lp2);
        vault.deposit(LP1DEPOSIT, lp2);

        assertEq(vault.balanceOf(lp), LP1DEPOSIT);
        assertEq(vault.balanceOf(lp2), LP1DEPOSIT);

        vault.withdraw(10e18, lp, lp2);
    }

    function testTwoDifferentTokensInVault() public {
        uint256 LP1DEPOSIT = 10e18;
        vm.prank(lp);
        vault.deposit(LP1DEPOSIT, lp);

        address lp3 = makeAddr("lp3");
        USDC = new ERC20Mock();
        USDC.mint(lp3, 10e18);

        vm.startPrank(lp3);
        USDC.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(10e18, lp3);
    }

    // Minting
    function testMinting() public {
        //
    }

    function testRedeem() public {
        //
    }
}
