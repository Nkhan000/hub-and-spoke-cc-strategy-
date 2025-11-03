// SPDX-License-Identifer: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {HubVault} from "src/core/HubVault.sol";
import {Vault} from "src/core/Vault.sol";
import {MockV3Aggregator} from "../../lib/chainlink-evm/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "src/mocks/ERC20Mock.sol";

contract HubVaultTest is Test {
    address public owner = makeAddr("owner");
    address public userA = makeAddr("userA");
    address public userB = makeAddr("userB");

    HubVault public hubVault;
    ERC20Mock public weth;
    ERC20Mock public usdc;
    ERC20Mock public wbtc;
    MockV3Aggregator public wethUsdFeed;
    MockV3Aggregator public usdcUsdFeed;
    MockV3Aggregator public wbtcUsdFeed;

    address[] public tokenAddresses;
    address[] public priceFeeds;

    uint256 public constant INITIIAL_SUPPLY = 100e18;

    function setUp() public {
        weth = new ERC20Mock("Wrapped ETH", "wEth", 18);
        usdc = new ERC20Mock("USD Coin", "usdc", 6);
        wbtc = new ERC20Mock("Wrapped Bitcoin", "wBtc", 8);

        wethUsdFeed = new MockV3Aggregator(8, 2000e8); // 8 decimals, $2000
        usdcUsdFeed = new MockV3Aggregator(8, 1e8); // 8 decimals, $1
        wbtcUsdFeed = new MockV3Aggregator(8, 100_000e8); // 8 decimals, $100_00

        tokenAddresses.push(address(weth));
        tokenAddresses.push(address(usdc));
        tokenAddresses.push(address(wbtc));

        priceFeeds.push(address(wethUsdFeed));
        priceFeeds.push(address(usdcUsdFeed));
        priceFeeds.push(address(wbtcUsdFeed));

        vm.startPrank(owner);
        hubVault = new HubVault(tokenAddresses, priceFeeds);

        // add spokes and gives them access
        hubVault.addSpoke(userA);
        vm.stopPrank();

        weth.mint(userA, 5 ether);
        usdc.mint(userA, 5_000e6);
        wbtc.mint(userA, 1e8);

        vm.startPrank(userA);
        weth.approve(address(hubVault), type(uint256).max);
        usdc.approve(address(hubVault), type(uint256).max);
        wbtc.approve(address(hubVault), type(uint256).max);
        vm.stopPrank();

        weth.mint(userB, 5 ether);
        usdc.mint(userB, 5_000e6);
        wbtc.mint(userB, 1e8);

        vm.startPrank(userB);
        weth.approve(address(hubVault), type(uint256).max);
        usdc.approve(address(hubVault), type(uint256).max);
        wbtc.approve(address(hubVault), type(uint256).max);
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
        assertEq(sharesAfterDeposit, INITIIAL_SUPPLY);
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

    function testMultiUsersDeposit() public {
        (uint256 sharesA, ) = _depositForUser(5 ether, 5_000e6, 0, userA);

        vm.prank(owner);
        hubVault.addSpoke(userB);

        (uint256 sharesB, ) = _depositForUser(4 ether, 4_000e6, 1e8, userB);

        assertEq(sharesA, INITIIAL_SUPPLY);
        assertEq(sharesA, hubVault.getShares(userA));

        assertEq(sharesB, hubVault.totalSupply() - sharesA);
        assertEq(sharesB, hubVault.getShares(userB));
    }

    // =================================
    // WITHDRAW
    // =================================

    function testMultiUsersWithdraw() public {
        uint256 totalUserABalanceBeforeDeposit = _totalBalanceOfUserInUsd(
            userA
        );
        uint256 totalUserBBalanceBeforeDeposit = _totalBalanceOfUserInUsd(
            userB
        );
        _depositForUser(5 ether, 5_000e6, 0, userA);

        vm.prank(owner);
        hubVault.addSpoke(userB);

        _depositForUser(4 ether, 4_000e6, 1e8, userB);

        uint256 allSharesOfA = hubVault.getShares(userA);

        vm.prank(userA);
        uint256 withdrawAmtA = hubVault.withdraw(allSharesOfA);

        uint256 totalUserABalanceAfterWithdraw = _totalBalanceOfUserInUsd(
            userA
        );

        assertApproxEqAbs(
            totalUserABalanceAfterWithdraw,
            totalUserABalanceBeforeDeposit,
            1e15
        );

        uint256 allSharesOfB = hubVault.getShares(userB);

        vm.prank(userB);
        uint256 withdrawAmtB = hubVault.withdraw(allSharesOfB); // 100 units of shares

        uint256 totalUserBBalanceAfterWithdraw = _totalBalanceOfUserInUsd(
            userB
        );

        assertApproxEqAbs(
            totalUserBBalanceAfterWithdraw,
            totalUserBBalanceBeforeDeposit,
            1e15
        );
    }

    function _totalBalanceOfUserInUsd(address user) public returns (uint256) {
        return
            hubVault.tokenValueUsd(weth, weth.balanceOf(user)) +
            hubVault.tokenValueUsd(usdc, usdc.balanceOf(user)) +
            hubVault.tokenValueUsd(wbtc, wbtc.balanceOf(user));
    }

    function _depositForUser(
        uint256 _wethAmt,
        uint256 _usdcAmt,
        uint256 _wbtcAmt,
        address _user
    ) public returns (uint256, uint256) {
        address[] memory tokensArr = new address[](3);
        uint256[] memory amountsArr = new uint256[](3);

        tokensArr[0] = address(weth);
        tokensArr[1] = address(usdc);
        tokensArr[2] = address(wbtc);

        amountsArr[0] = _wethAmt;
        amountsArr[1] = _usdcAmt;
        amountsArr[2] = _wbtcAmt;

        vm.prank(_user); // not allowed spoke
        (uint256 shares, uint256 totalDepositedValue) = hubVault.deposit(
            tokensArr,
            amountsArr
        );
        return (shares, totalDepositedValue);
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
