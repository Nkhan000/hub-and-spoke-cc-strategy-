// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

contract StrategyManager is Ownable, ReentrancyGuard {
    event StrategyRegistered(
        bytes32 indexed id,
        address adapter,
        uint256 allocation
    );
    event StrategyHarvested(
        bytes32 indexed id,
        uint256 profit,
        uint256 loss,
        uint256 fee
    );
    event StrategyRebalanced(bytes32 indexed id, int256 delta); // + deposit, - withdraw
    event StrategyDeactivated(bytes32 indexed id);

    constructor() Ownable(msg.sender) {}

    struct StrategyConfig {
        // ---------- SLOT 0 -----------//
        address adapter;
        uint16 targetAllocation; // Max 65,535 — plenty for BPS
        uint32 lastHarvest; // 32 bits (fits Timestamps here until year 2106)
        bool active; // 8 bits
        bool emergencyMode; // 8 bits
        // ---------------------------- //
        uint256 currentDeposited; // SLOT 1
        uint256 totalProfit; // SLOT 2
        uint256 totalLoss; // SLOT 3
    }

    struct TokenInfo {
        address token;
        address priceFeed;
        // bool isActive
        // bytes32[] investedIn;
    }

    address public vault;
    // uint256 public totalAllocated;
    // mapping(address => TokenInfo) private tokensInvested;
    mapping(bytes32 => StrategyConfig) private strategies;
    bytes32[] public strategyIds;

    uint32 public constant MIN_HARVEST_TIME = 5 days;
    uint16 public constant MAX_BPS = 10_000; // 100%
    uint16 public constant PERFORMANCE_FEE_BPS = 1_000; // 10% of profit

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    //
    function registerStrategy() public onlyVault returns (bytes32 strategyId) {
        // check if the assets required by the strategy are allowed or is active
        // configure max allocation (allocation BPS)
        //
        //  strategyId = keccak256(abi.encodePacked(adapter, block.timestamp));
        //
        // set coniguration for strategies
        // update local vairables for strategies
    }

    function allocateFunds() public onlyVault {}

    // Harvesting

    function harvest(bytes32 strategyId) public onlyOwner nonReentrant {
        StrategyConfig storage config = strategies[strategyId];
        require(config.active, "Inactive strategy");
        require(
            block.timestamp + config.lastHarvest >= MIN_HARVEST_TIME,
            "Harvesting too soon."
        );
        (uint256 profit, uint256 loss) = IStrategy(config.adapter).harvest();
        uint256 fee;
        uint256 netProfit;

        if (profit > 0) {
            fee = (profit * PERFORMANCE_FEE_BPS) / MAX_BPS;
            netProfit = profit - fee;
            // IERC20() here we have to transfer fee in such a way that it withdraws tokens evenly
            config.totalProfit += netProfit; // profit in usdc
        }

        if (loss > 0) {
            // what else can be done
            config.totalLoss += loss;
        }

        config.lastHarvest = uint32(block.timestamp);

        // Tell vault to update pricePerShare
        // IVault(vault).reportStrategyPerformance(strategyId, netProfit, loss);

        // emit StrategyHarvested(strategyId, netProfit, loss, fee);
    }

    // rebalance
    function rebalance(bytes32 strategyId) public onlyOwner nonReentrant {}
    // tend

    // reporting
}
