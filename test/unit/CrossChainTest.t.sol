// SDPX License Identifier: MIT

pragma solidity ^0.8.0;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {HubVault} from "../../src/core/HubVault.sol";
// import {CCIPLocalSimulatorFork, Register} from "lib/chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {SpokeVault} from "../../src/core/SpokeVault.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

contract CrossChainTest is Test {
    HubVault hubVaultWeth;
    SpokeVault spokeVault;

    ERC20Mock weth_sepolia;
    ERC20Mock weth_arb;
    ERC20Mock usdc_sepolia;
    ERC20Mock usdc_arb;

    uint256 sepoliaFork;
    uint256 arbSepoliaFork;
    address public owner = makeAddr("owner");

    // CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    // Register.NetworkDetails sepoliaNetworkDetails;
    // Register.NetworkDetails arbSepoliaNetworkDetails;

    //  struct NetworkDetails {
    //     uint64 chainSelector;
    //     address routerAddress;
    //     address linkAddress;
    //     address wrappedNativeAddress;
    //     address ccipBnMAddress;
    //     address ccipLnMAddress;
    //     address rmnProxyAddress;
    //     address registryModuleOwnerCustomAddress;
    //     address tokenAdminRegistryAddress;
    // }

    // ccipLocalSimulatorFork.requestLinkFromFaucet(user, fee); // To get link tokens from the simulator

    function setUp() public {
        /*
        sepoliaFork = vm.createSelectFork("sepolia");
        arbSepoliaFork = vm.createFork("arb-sepolia");

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Deploy and Configure on Sepolia
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );
        vm.startPrank(owner);
        weth_sepolia = new ERC20Mock();
        usdc_sepolia = new ERC20Mock();
        hubVaultWeth = new HubVault(
            weth_sepolia,
            sepoliaNetworkDetails.routerAddress, sepoliaNetworkDetails.linkAddress
        );
        vm.stopPrank();

        // Deploy and configure on Arbitrum Sepolia
        vm.selectFork(arbSepoliaFork);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );
        vm.startPrank(owner);
        weth_arb = new ERC20Mock();
        usdc_arb = new ERC20Mock();
        vm.stopPrank();
        */
    }
}
