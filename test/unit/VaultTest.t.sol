// SPDX-License-Identifer: MIT

pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "src/core/Vault.sol";
import {MockV3Aggregator} from "../../lib/chainlink-local/src/data-feeds/MockV3Aggregator.sol";
import {ERC20Mock} from "src/mocks/ERC20Mock.sol";

// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract VaultTest is Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");

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

        weth.mint(user, 10 ether);
        usdc.mint(user, 20_000e6);

        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
    ///////////////////////////////////////////////
    // DEPOSIT
    //////////////////////////////////////////////

    function testDeposit() public {
        uint256 initialShares = vault.totalSupply();
        vm.prank(user);

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
        vm.prank(user);
        vault.deposit(5e18, 0);
        uint256 sharesAfterDeposit = vault.totalSupply();
        assert(sharesAfterDeposit > initialShares);
        assertEq(sharesAfterDeposit, 10_000e18);
    }

    function testZeroDeposit() public {
        vm.expectRevert();
        vm.prank(user);
        vault.deposit(0, 0);
    }

    // uint256 userShares = vault.balanceOf(userAddress);
    // uint256 userAssets = vault.previewRedeem(userShares);
}
