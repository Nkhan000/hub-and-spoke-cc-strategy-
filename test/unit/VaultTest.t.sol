// SPDX-License-Identifer: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {Vault} from "src/core/Vault.sol";
import {MockV3Aggregator} from "../../lib/chainlink-evm/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "src/mocks/ERC20Mock.sol";

// import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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

        address[] memory tokenAddresses;
        tokenAddresses[0] = address(weth);
        tokenAddresses[1] = address(usdc);

        address[] memory priceFeeds;
        priceFeeds[0] = address(wethUsdFeed);
        priceFeeds[1] = address(usdcUsdFeed);
        /*
        vault = new Vault(tokenAddresses, priceFeeds);*/

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

    // Test number of shares minted is correct when price changes
    // withdraw
}
