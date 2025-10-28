// SPDX-License-Identifer: MIT
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {HubVault} from "src/core/HubVault.sol";
import {MockV3Aggregator} from "../../lib/chainlink-evm/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "src/mocks/ERC20Mock.sol";

contract HubVaultTest is Test {
    address public owner = makeAddr("owner");
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");

    HubVault public hubVault;
    ERC20Mock public weth;
    ERC20Mock public usdc;
    MockV3Aggregator public wethUsdFeed;
    MockV3Aggregator public usdcUsdFeed;

    address[] public tokenAddresses;
    address[] public priceFeeds;

    function setUp() public {
        weth = new ERC20Mock("Wrapped ETH", "wEth", 18);
        usdc = new ERC20Mock("USD Coin", "usdc", 6);

        wethUsdFeed = new MockV3Aggregator(8, 2000e8); // 8 decimals, $2000
        usdcUsdFeed = new MockV3Aggregator(8, 1e8); // 8 decimals, $1

        tokenAddresses.push(address(weth));
        tokenAddresses.push(address(usdc));

        priceFeeds.push(address(wethUsdFeed));
        priceFeeds.push(address(usdcUsdFeed));

        hubVault = new HubVault(tokenAddresses, priceFeeds);

        // add spokes and gives them access
        hubVault.addSpoke(userA);

        weth.mint(userA, 10 ether);
        usdc.mint(userA, 20_000e6);

        vm.startPrank(userA);
        weth.approve(address(hubVault), type(uint256).max);
        usdc.approve(address(hubVault), type(uint256).max);
        vm.stopPrank();

        weth.mint(userB, 10 ether);
        usdc.mint(userB, 20_000e6);

        vm.startPrank(userB);
        weth.approve(address(hubVault), type(uint256).max);
        usdc.approve(address(hubVault), type(uint256).max);
        vm.stopPrank();
    }

    function testDeposit() public {
        uint256 initialShares = hubVault.totalSupply();

        // 5 ether  * $2000 = $10_000
        // 10_000 usdc * $1 = $10_000;
        // total usd value deposited = $20_000;
        address[] memory tokensArr = new address[](2);
        uint256[] memory amountsArr = new uint256[](2);

        tokensArr[0] = address(weth);
        tokensArr[1] = address(usdc);

        amountsArr[0] = 5 ether;
        amountsArr[1] = 10_000e6;

        vm.prank(userA); // allowed spoke in the constructor
        hubVault.deposit(tokensArr, amountsArr);

        uint256 sharesAfterDeposit = hubVault.totalSupply();
        assert(sharesAfterDeposit > initialShares);
        assertEq(sharesAfterDeposit, 20_000e18);
    }

    function testNotAllowedSpoke() public {
        address[] memory tokensArr = new address[](2);
        uint256[] memory amountsArr = new uint256[](2);

        tokensArr[0] = address(weth);
        tokensArr[1] = address(usdc);

        amountsArr[0] = 5 ether;
        amountsArr[1] = 10_000e6;

        vm.expectRevert();
        vm.prank(userB); // not allowed spoke
        hubVault.deposit(tokensArr, amountsArr);
    }

    function testZeroDeposit() public {
        address[] memory tokensArr = new address[](2);
        uint256[] memory amountsArr = new uint256[](2);
        vm.prank(userA);
        hubVault.deposit(tokensArr, amountsArr);
    }

    function testInconsistentDeposit() public {
        address[] memory tokensArr = new address[](4);
        uint256[] memory amountsArr = new uint256[](5);
        vm.expectRevert();
        vm.prank(userA);
        hubVault.deposit(tokensArr, amountsArr);
    }

    function testMaxLengthDeposit() public {
        address[] memory tokensArr = new address[](5);
        uint256[] memory amountsArr = new uint256[](5);
        vm.expectRevert();
        vm.prank(userA);
        hubVault.deposit(tokensArr, amountsArr);
    }

    // function testHubDeposit() public {
    //     vm.prank(userA);
    //     uint256 shares = hubVault.deposit(2e18, 4000e6);
    //     uint256 totalShares = hubVault.getShares(userA);

    //     assertEq(shares, totalShares);
    // }

    // TODO TESTS : AUTOMATION, ORACLELIB WITHDRAW, ACCESS CONTROLS
}

/*
    function testDeposit() public {
        uint256 initialShares = vault.totalSupply();
        vm.prank(userA);

        // 5 ether  * $2000 = $10_000
        // 10_000 usdc * $1 = $10_000;
        // total usd value deposited = $20_000;
        address[] memory tokenAddresses;
        address[] memory amountsArr;

        tokenAddresses[0] = address(weth);
        tokenAddresses[1] = address(usdc);
        amounts[0] = 5 ether;
        amounts[1] = 10_000e6;

        vault.deposit(tokenAddresses, amounts);

        uint256 sharesAfterDeposit = vault.totalSupply();
        assert(sharesAfterDeposit > initialShares);
        assertEq(sharesAfterDeposit, 20_000e18);
    }

    function testSingleDeposit() public {
        uint256 initialShares = vault.totalSupply();
        vm.prank(userA);

        address[] memory tokenAddresses;
        address[] memory amounts;

        tokenAddresses[0] = address(weth);
        amounts[0] = 5 ether;
        vault.deposit(tokenAddresses, amounts);

        uint256 sharesAfterDeposit = vault.totalSupply();
        assert(sharesAfterDeposit > initialShares);
        assertEq(sharesAfterDeposit, 10_000e18);
    }

    function testZeroDeposit() public {
        vm.expectRevert();
        vm.prank(userA);
        vault.deposit(0, 0);
    }

    function testDepositAfterPriceChange() public {
        uint256 initialShares = vault.totalSupply();

        address[] memory tokenAddresses;
        address[] memory amounts;

        tokenAddresses[0] = address(weth);
        tokenAddresses[1] = address(usdc);

        amounts[0] = 4 ether;
        amounts[1] = 2_000e6;

        vault.deposit(tokenAddresses, amounts);

        vm.prank(userA);
        // uint256 depositWeth = 4 ether;
        // uint256 depositUsdc = 2000e6;
        vault.deposit(tokenAddresses, amounts); // => $8_000 + $2_000

        uint256 sharesBeforDeposit = vault.totalSupply(); // 10_000

        wethUsdFeed.updateAnswer(3000e8); // 4 weth @3000 = $12_000 and 2_000 usdc => $14_000

        uint256 TVLBeforeDeposit = vault.totalVaultValueUsd();
        uint256 pricePerShareBefore = vault.pricePerShare();

        vm.prank(userB);

        amounts[0] = 5 ether;
        amounts[1] = 2_000e6;
        vault.deposit(tokenAddresses, amounts); // 5 weth @3000 = $15_000 and 2_000 usdc => $17_000

        // uint256 secondDepositAmt = vault.tokenValueUsd(usdc, depositUsdc) +
        //     vault.tokenValueUsd(weth, depositWeth);

        uint256 totalSupplyAfterDeposit = vault.totalSupply(); // 12_142.8 + 10_000 => ~22_142
        uint256 pricePerShareAfter = vault.pricePerShare();

        // price of share remains the same after the increament of the token price
        assertEq(pricePerShareBefore, pricePerShareAfter); // ✅

        assertEq(
            totalSupplyAfterDeposit,
            vault.balanceOf(userA) + vault.balanceOf(userB)
        ); // ✅
        // shares minted
        // assertEq(
        //     vault.balanceOf(userB),
        //     _computeShares(
        //         sharesBeforDeposit,
        //         secondDepositAmt,
        //         TVLBeforeDeposit
        //     )
        // );
    }

    function _computeShares(
        uint256 totalSupply,
        uint256 invested,
        uint256 tvl
    ) public pure returns (uint256) {
        return (invested * totalSupply) / tvl;
    }

    function testWithdraw() public {
        uint256 depositWeth = 4 ether;
        uint256 depositUsdc = 0;
        console2.log(usdc.balanceOf(userA));
    }
*/
/** if initially price is at $2000 and shares minted for total deposit of $10_000 (4 weth @ 2000 => $8000 + 2000 usdc) is 10_000 shares
     * So, investor A has 10_000 shares
     *
     * If price increases to $2_000 -> $3_000:
     * Price per share => 10000 / 10000 => $1 per share
     *
     * TVL becomes 4 eth @ $3000 => $12_000 and 2000 USDC => $2000 => $14_000
     * Price per share => 14_000 / 10000 => $1.4 per share
     *
     * New investor with $6000 (1 weth @ $3000 + 3000 usdc)
     *
     * shares = (6000 * 10_000) / 14000  => 4285.71
     *
     * new supply = 4285.71 + 10000 => 14285.71
     *
     * price per share = 20000 / 14285 => 1.4 per share
     
     */
