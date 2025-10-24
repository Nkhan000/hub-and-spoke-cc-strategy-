// SPDX-License-Identifer: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {Vault} from "src/core/Vault.sol";
import {MockV3Aggregator} from "../../lib/chainlink-local/src/data-feeds/MockV3Aggregator.sol";
import {ERC20Mock} from "src/mocks/ERC20Mock.sol";

// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract VaultTest is Test {
    address owner = makeAddr("owner");
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");

    Vault vault;
    ERC20Mock weth;
    ERC20Mock usdc;
    MockV3Aggregator wethUsdFeed;
    MockV3Aggregator usdcUsdFeed;

    function setUp() public {
        weth = new ERC20Mock("Wrapped ETH", "wEth", 18);
        usdc = new ERC20Mock("USD Coin", "usdc", 6);

        // Mock Chainlink price feeds
        // WETH/USD = $2000, USDC/USD = $1
        wethUsdFeed = new MockV3Aggregator(8, 2000e8); // 8 decimals, $2000
        usdcUsdFeed = new MockV3Aggregator(8, 1e8); // 8 decimals, $1

        vault = new Vault(
            address(weth),
            address(usdc),
            address(wethUsdFeed),
            address(usdcUsdFeed)
        );

        weth.mint(userA, 10 ether);
        usdc.mint(userA, 20_000e6);

        vm.startPrank(userA);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        weth.mint(userB, 10 ether);
        usdc.mint(userB, 20_000e6);

        vm.startPrank(userB);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
    ///////////////////////////////////////////////
    // DEPOSIT
    //////////////////////////////////////////////

    function testDeposit() public {
        uint256 initialShares = vault.totalSupply();
        vm.prank(userA);

        // 5 ether  * $2000 = $10_000
        // 10_000 usdc * $1 = $10_000;
        // total usd value deposited = $20_000;
        vault.deposit(5 ether, 10_000e6);

        uint256 sharesAfterDeposit = vault.totalSupply();
        assert(sharesAfterDeposit > initialShares);
        assertEq(sharesAfterDeposit, 20_000e18);
    }

    function testSingleDeposit() public {
        uint256 initialShares = vault.totalSupply();
        vm.prank(userA);
        vault.deposit(5e18, 0);
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
        vm.prank(userA);
        uint256 depositWeth = 4 ether;
        uint256 depositUsdc = 2000e6;
        vault.deposit(depositWeth, depositUsdc); // => $8_000 + $2_000

        uint256 sharesBeforDeposit = vault.totalSupply(); // 10_000

        wethUsdFeed.updateAnswer(3000e8); // 4 weth @3000 = $12_000 and 2_000 usdc => $14_000

        uint256 TVLBeforeDeposit = vault.totalVaultValueUsd();
        uint256 pricePerShareBefore = vault.pricePerShare();

        vm.prank(userB);
        depositWeth = 5 ether;
        depositUsdc = 2000e6;
        vault.deposit(depositWeth, depositUsdc); // 5 weth @3000 = $15_000 and 2_000 usdc => $17_000

        uint256 secondDepositAmt = vault.tokenValueUsd(usdc, depositUsdc) +
            vault.tokenValueUsd(weth, depositWeth); // 18000.000000000000000000 why

        uint256 totalSupplyAfterDeposit = vault.totalSupply(); // 12_142.8 + 10_000 => ~22_142
        uint256 pricePerShareAfter = vault.pricePerShare();

        // price of share remains the same after the increament of the token price
        assertEq(pricePerShareBefore, pricePerShareAfter); // ✅

        assertEq(
            totalSupplyAfterDeposit,
            vault.balanceOf(userA) + vault.balanceOf(userB)
        ); // ✅
        // shares minted
        assertEq(
            vault.balanceOf(userB),
            _computeShares(
                sharesBeforDeposit,
                secondDepositAmt,
                TVLBeforeDeposit
            )
        );
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

    // Test number of shares minted is correct when price changes
    // withdraw
}
