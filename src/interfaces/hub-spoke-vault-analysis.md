# Hub-Spoke-Vault Architecture: Industry Standard Analysis & Improvements

## Executive Summary

Your architecture follows a sound conceptual model. However, to meet industry standards (OpenZeppelin, Yearn, EigenLayer quality), you need structural improvements in: interface segregation, error handling consistency, event standardization, access control patterns, and cross-contract communication.

---

## Part 1: Industry Standard Patterns You Should Adopt

### 1.1 Interface-First Design

**Why it matters:** Top protocols define interfaces BEFORE implementations. This enables:

- Loose coupling between contracts
- Easier upgrades and migrations
- Clear API contracts for integrators
- Better testing with mocks

**Current problem:** SpokeVault directly imports `HubVault` concrete implementation (line 15). This creates tight coupling and makes the system rigid.

### 1.2 Consistent Error Handling

**Industry pattern:** Custom errors with descriptive names, grouped by contract.

**Your current state:** Mixed approach - some custom errors (`Vault__InvalidAddress`), some string reverts (`revert("Empty assets")`).

**Standard approach:**

```solidity
// All errors at contract top, prefixed with contract name
error Vault__ZeroAddress();
error Vault__InvalidAmount();
error Vault__ExceedsMaxTokens(uint256 provided, uint256 max);
error Vault__TokenNotSupported(address token);
error Vault__InsufficientShares(uint256 requested, uint256 available);
error Vault__CooldownActive(uint256 timeRemaining);
```

### 1.3 Event Standardization

**Industry pattern:** Events should be:

- Indexed on key lookup fields (addresses, IDs)
- Comprehensive enough to reconstruct state off-chain
- Consistent naming (past tense verbs)

**Your current issue:** `Deposit` event hardcodes `wethIn`, `usdcIn` — doesn't match multi-asset reality.

**Standard approach:**

```solidity
event Deposited(
    address indexed depositor,
    address indexed receiver,
    address[] tokens,
    uint256[] amounts,
    uint256 sharesMinted,
    uint256 totalValueUsd
);

event Withdrawn(
    address indexed owner,
    address indexed receiver,
    uint256 sharesBurned,
    address[] tokens,
    uint256[] amounts,
    uint256 totalValueUsd
);
```

### 1.4 NatSpec Documentation

**Industry standard:** Every public/external function needs full NatSpec.

**Example:**

```solidity
/// @notice Deposits multiple tokens into the vault in exchange for shares
/// @dev Caller must have approved this contract for all tokens
/// @param receiver Address that will receive the minted shares
/// @param tokens Array of token addresses to deposit
/// @param amounts Array of amounts corresponding to each token
/// @return details Struct containing shares minted and USD value
/// @custom:security non-reentrant
function deposit(
    address receiver,
    address[] calldata tokens,
    uint256[] calldata amounts
) external returns (DepositDetails memory details);
```

### 1.5 Access Control Granularity

**Industry pattern:** Separate roles for separate concerns.

**Your current state:** `DEFAULT_ADMIN_ROLE` does everything.

**Standard approach:**

```solidity
bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN");      // Emergency pause
bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST");  // Strategy management
bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");    // Fund allocation
bytes32 public constant KEEPER_ROLE = keccak256("KEEPER");          // Automated operations
```

---

## Part 2: Specific Code Issues & Fixes

### 2.1 Critical Bugs

#### Bug #1: BasePeriphery passes wrong arrays to spoke (CRITICAL)

**Location:** BasePeriphery.sol lines 283-287

```solidity
// CURRENT (BUGGY):
(address[] memory supportedTokens, uint256[] memory filteredAmounts) = _filterSupportedTokens(tokens, amounts);
// ... but then passes original arrays:
SpokeVault.DepositDetails memory depositDetails = spoke.deposit(provider, tokens, amounts);

// FIXED:
SpokeVault.DepositDetails memory depositDetails = spoke.deposit(provider, supportedTokens, filteredAmounts);
```

#### Bug #2: previewDeposit has inverted logic

**Location:** Vault.sol line 390

```solidity
// CURRENT (BUGGY):
require(len != 0 && len != _amounts.length, "Invalid length");
// This reverts when lengths ARE equal (the valid case)

// FIXED:
require(len != 0 && len == _amounts.length, "Invalid length");
```

#### Bug #3: previewWithdraw double calculation

**Location:** Vault.sol lines 447-452

```solidity
// CURRENT (REDUNDANT):
uint256 amountOut = (vaultBal * _shares) / totalSharesBefore;  // First calc
if (_shares == totalSharesBefore) {
    amountOut = vaultBal;
} else {
    amountOut = Math.mulDiv(vaultBal, _shares, totalSharesBefore);  // Overwrites
}

// FIXED:
uint256 amountOut;
if (_shares == totalSharesBefore) {
    amountOut = vaultBal;
} else {
    amountOut = Math.mulDiv(vaultBal, _shares, totalSharesBefore);
}
```

#### Bug #4: getSupportedTokens doesn't exist

**Location:** SpokeVault.sol line 198

```solidity
// CURRENT (UNDEFINED):
address[] memory tokensAddress = getSupportedTokens();

// FIXED: Either rename or add alias
function getSupportedTokens() public view returns (address[] memory) {
    return getSupportedAssets();
}
```

### 2.2 Missing Functions Required by BasePeriphery

Add these to SpokeVault.sol:

```solidity
/// @notice Check if a token is supported for deposits
/// @param _token Token address to check
/// @return True if token is active and supported
function isSupportedToken(address _token) external view returns (bool) {
    return isActiveAsset(_token);
}

/// @notice Preview withdrawal amounts without executing
/// @param _shares Amount of shares to preview burning
/// @return tokens Array of token addresses
/// @return amounts Array of amounts for each token
/// @return valueUsd Total USD value of withdrawal
function quoteWithdraw(uint256 _shares) external view returns (
    address[] memory tokens,
    uint256[] memory amounts,
    uint256 valueUsd
) {
    return previewWithdraw(_shares);
}
```

### 2.3 Security Improvements Needed

#### Add ReentrancyGuard to Vault.\_deposit

```solidity
// In Vault.sol, the _deposit function should be protected
// Since Vault is abstract, add nonReentrant in SpokeVault's deposit override
function deposit(...) public override onlyRole(PERIPHERY_ROLE) nonReentrant returns (...) {
```

#### Add whenNotPaused to critical functions

```solidity
function deposit(...) public override onlyRole(PERIPHERY_ROLE) nonReentrant whenNotPaused returns (...) {

function withdraw(...) public override onlyRole(PERIPHERY_ROLE) nonReentrant whenNotPaused returns (...) {
```

#### Add slippage protection for hub transfers

```solidity
function transferFundsToHub(
    uint256[] memory amounts,
    address[] memory tokensAddress,
    uint256 minSharesOut  // ADD THIS
) public onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    // ... existing logic ...

    DepositDetails memory details = HubVault(hubInfo.hub).deposit(tokensAddress, amounts);

    if (details.sharesMinted < minSharesOut) {
        revert SpokeVault__SlippageExceeded(details.sharesMinted, minSharesOut);
    }
}
```

---

## Part 3: Complete Interface Definitions

### 3.1 IVault.sol (Base Interface)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVault
/// @notice Interface for multi-asset vault operations
/// @dev Base interface inherited by spoke and hub vault interfaces
interface IVault {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    struct DepositDetails {
        uint256 sharesMinted;
        uint256 totalUsdAmount;
    }

    struct WithdrawDetails {
        address[] tokensReceived;
        uint256[] amountsReceived;
        uint256 withdrawValueInUsd;
    }

    struct TokenInfo {
        address token;
        address priceFeed;
        bool isActive;
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    error Vault__ZeroAddress();
    error Vault__InvalidAmount();
    error Vault__LengthMismatch();
    error Vault__ExceedsMaxTokens(uint256 provided, uint256 max);
    error Vault__TokenNotSupported(address token);
    error Vault__TokenNotActive(address token);
    error Vault__InsufficientShares(uint256 requested, uint256 available);
    error Vault__CooldownActive(uint256 timeRemaining);
    error Vault__InvalidPrice(address token);
    error Vault__ZeroShares();
    error Vault__ZeroDeposit();

    // ============================================================
    //                          EVENTS
    // ============================================================

    event Deposited(
        address indexed depositor,
        address indexed receiver,
        address[] tokens,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalValueUsd
    );

    event Withdrawn(
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event AssetAdded(
        address indexed asset,
        address indexed priceFeed
    );

    event AssetRemoved(address indexed asset);

    event PriceFeedUpdated(
        address indexed asset,
        address indexed oldFeed,
        address indexed newFeed
    );

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Returns the maximum number of tokens allowed in the vault
    function MAX_ALLOWED_TOKENS() external view returns (uint256);

    /// @notice Returns all supported asset addresses
    function getSupportedAssets() external view returns (address[] memory);

    /// @notice Checks if an asset is currently active for deposits
    /// @param asset The asset address to check
    function isActiveAsset(address asset) external view returns (bool);

    /// @notice Returns the total vault value in USD (18 decimals)
    function totalVaultValueUsd() external view returns (uint256);

    /// @notice Returns the current price per share in USD (18 decimals)
    function pricePerShare() external view returns (uint256);

    /// @notice Calculates USD value for a given token amount
    /// @param token The token address
    /// @param amount The amount of tokens
    /// @return valueUsd The USD value with 18 decimals
    function tokenValueUsd(address token, uint256 amount) external view returns (uint256);

    /// @notice Returns the share balance of an account
    /// @param account The account to query
    function getAllShares(address account) external view returns (uint256);

    /// @notice Returns the USD value of an account's shares
    /// @param account The account to query
    function getAllUserSharesValueUsd(address account) external view returns (uint256);

    /// @notice Preview deposit to calculate expected shares
    /// @param tokens Array of token addresses
    /// @param amounts Array of token amounts
    /// @return shares Expected shares to be minted
    function previewDeposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external view returns (uint256 shares);

    /// @notice Preview withdrawal to calculate expected token amounts
    /// @param shares Amount of shares to burn
    /// @return tokens Array of token addresses
    /// @return amounts Array of token amounts to receive
    /// @return valueUsd Total USD value
    function previewWithdraw(uint256 shares) external view returns (
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 valueUsd
    );
}
```

### 3.2 ISpokeVault.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "./IVault.sol";

/// @title ISpokeVault
/// @notice Interface for spoke vault that receives deposits from periphery contracts
/// @dev Spoke vaults aggregate funds and forward to hub vault for strategy deployment
interface ISpokeVault is IVault {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    struct PeripheryInfo {
        address periphery;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    struct HubInfo {
        address hub;
        uint256 totalSharesInHub;
        uint256 lastAllocated;
        uint256 lastWithdrawal;
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    error SpokeVault__NotAuthorizedPeriphery(address caller);
    error SpokeVault__PeripheryNotActive();
    error SpokeVault__HubNotSet();
    error SpokeVault__InvalidHubAddress();
    error SpokeVault__SlippageExceeded(uint256 received, uint256 minimum);
    error SpokeVault__InsufficientHubShares(uint256 requested, uint256 available);
    error SpokeVault__PeripheryHasShares(uint256 shares);
    error SpokeVault__UnclaimedProfitsPending(uint256 amount);

    // ============================================================
    //                          EVENTS
    // ============================================================

    event FundsTransferredToHub(
        address indexed hub,
        address[] tokens,
        uint256[] amounts,
        uint256 hubSharesMinted,
        uint256 totalValueUsd
    );

    event FundsWithdrawnFromHub(
        address indexed hub,
        uint256 hubSharesBurned,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event PeripheryDeposit(
        address indexed periphery,
        address indexed receiver,
        address[] tokens,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalValueUsd
    );

    event PeripheryWithdrawal(
        address indexed periphery,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        address[] tokens,
        uint256[] amounts
    );

    event PeripheryUpdated(
        address indexed oldPeriphery,
        address indexed newPeriphery
    );

    event PeripheryStatusChanged(
        address indexed periphery,
        bool isActive
    );

    event HubUpdated(
        address indexed oldHub,
        address indexed newHub
    );

    // ============================================================
    //                    PERIPHERY FUNCTIONS
    // ============================================================

    /// @notice Deposit tokens from periphery on behalf of a user
    /// @dev Only callable by authorized periphery contract
    /// @param receiver Address to receive minted shares
    /// @param tokens Array of token addresses to deposit
    /// @param amounts Array of amounts for each token
    /// @return details Struct containing shares minted and USD value
    function deposit(
        address receiver,
        address[] memory tokens,
        uint256[] memory amounts
    ) external returns (DepositDetails memory details);

    /// @notice Withdraw tokens for a user, sending to their address
    /// @dev Only callable by authorized periphery contract
    /// @param owner Address that owns the shares to burn
    /// @param shares Amount of shares to burn
    /// @return details Struct containing tokens and amounts withdrawn
    function withdraw(
        address owner,
        uint256 shares
    ) external returns (WithdrawDetails memory details);

    /// @notice Withdraw tokens and send to periphery (for cross-chain)
    /// @dev Only callable by authorized periphery contract
    /// @param owner Address that owns the shares to burn
    /// @param shares Amount of shares to burn
    /// @return details Struct containing tokens and amounts withdrawn
    function withdrawTo(
        address owner,
        uint256 shares
    ) external returns (WithdrawDetails memory details);

    // ============================================================
    //                      HUB FUNCTIONS
    // ============================================================

    /// @notice Transfer all vault funds to the hub vault
    /// @dev Only callable by admin, transfers entire balance
    function transferAllFundsToHub() external;

    /// @notice Transfer specific amounts to hub vault
    /// @param tokens Array of token addresses
    /// @param amounts Array of amounts to transfer
    /// @param minSharesOut Minimum hub shares expected (slippage protection)
    function transferFundsToHub(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 minSharesOut
    ) external;

    /// @notice Withdraw funds from hub vault back to spoke
    /// @param hubShares Amount of hub shares to burn
    /// @param minValueOut Minimum USD value expected (slippage protection)
    function withdrawFromHub(
        uint256 hubShares,
        uint256 minValueOut
    ) external;

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update the periphery contract address
    /// @param newPeriphery New periphery contract address
    function updatePeriphery(address newPeriphery) external;

    /// @notice Disable the current periphery (emergency)
    function disablePeriphery() external;

    /// @notice Re-enable the current periphery
    function enablePeriphery() external;

    /// @notice Update the hub vault address
    /// @param newHub New hub vault address
    function updateHub(address newHub) external;

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Get current periphery information
    function getPeripheryInfo() external view returns (PeripheryInfo memory);

    /// @notice Get current hub information
    function getHubInfo() external view returns (HubInfo memory);

    /// @notice Check if a token is supported (alias for isActiveAsset)
    /// @param token Token address to check
    function isSupportedToken(address token) external view returns (bool);

    /// @notice Quote withdrawal (alias for previewWithdraw)
    /// @param shares Shares to burn
    function quoteWithdraw(uint256 shares) external view returns (
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 valueUsd
    );

    /// @notice Get shares this spoke holds in the hub
    function getHubShares() external view returns (uint256);
}
```

### 3.3 IHubVault.sol (Complete Interface for Your Next Implementation)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "./IVault.sol";

/// @title IHubVault
/// @notice Interface for the hub vault that deploys funds to yield strategies
/// @dev Hub vault receives funds from spoke vaults and allocates to various strategies
interface IHubVault is IVault {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    /// @notice Information about an approved spoke vault
    struct SpokeInfo {
        address spoke;
        uint64 chainSelector;       // CCIP chain selector (0 for same chain)
        uint256 totalDeposited;     // Cumulative deposits from this spoke
        uint256 totalWithdrawn;     // Cumulative withdrawals to this spoke
        uint256 lastActivity;       // Timestamp of last interaction
        bool isActive;              // Whether spoke can deposit/withdraw
    }

    /// @notice Information about a yield strategy
    struct StrategyInfo {
        address strategy;           // Strategy contract address
        string name;                // Human readable name
        uint256 allocation;         // Target allocation in basis points (100 = 1%)
        uint256 currentDeposited;   // Current amount deposited to strategy
        uint256 totalGains;         // Cumulative gains from strategy
        uint256 totalLosses;        // Cumulative losses from strategy
        uint256 lastHarvest;        // Timestamp of last harvest
        bool isActive;              // Whether strategy accepts new deposits
        bool isEmergency;           // Whether strategy is in emergency withdrawal mode
    }

    /// @notice Parameters for strategy allocation
    struct AllocationParams {
        address strategy;
        address[] tokens;
        uint256[] amounts;
        uint256 minValueOut;        // Slippage protection
    }

    /// @notice Result of a harvest operation
    struct HarvestResult {
        address strategy;
        int256 netPnL;              // Positive = profit, negative = loss
        uint256 feesCollected;
        uint256 timestamp;
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    error HubVault__NotAuthorizedSpoke(address caller);
    error HubVault__SpokeNotActive(address spoke);
    error HubVault__SpokeAlreadyExists(address spoke);
    error HubVault__SpokeNotFound(address spoke);
    error HubVault__StrategyNotActive(address strategy);
    error HubVault__StrategyAlreadyExists(address strategy);
    error HubVault__StrategyNotFound(address strategy);
    error HubVault__AllocationExceeds100Percent(uint256 total);
    error HubVault__InsufficientIdleFunds(uint256 requested, uint256 available);
    error HubVault__SlippageExceeded(uint256 received, uint256 minimum);
    error HubVault__HarvestTooSoon(uint256 nextHarvestTime);
    error HubVault__EmergencyModeActive();
    error HubVault__NotInEmergencyMode();
    error HubVault__StrategyHasFunds(address strategy, uint256 amount);
    error HubVault__WithdrawalQueueEmpty();
    error HubVault__MaxStrategiesReached(uint256 max);

    // ============================================================
    //                          EVENTS
    // ============================================================

    // Spoke Events
    event SpokeAdded(
        address indexed spoke,
        uint64 chainSelector
    );

    event SpokeRemoved(address indexed spoke);

    event SpokeStatusChanged(
        address indexed spoke,
        bool isActive
    );

    event SpokeDeposit(
        address indexed spoke,
        address[] tokens,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalValueUsd
    );

    event SpokeWithdrawal(
        address indexed spoke,
        uint256 sharesBurned,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    // Strategy Events
    event StrategyAdded(
        address indexed strategy,
        string name,
        uint256 targetAllocation
    );

    event StrategyRemoved(address indexed strategy);

    event StrategyStatusChanged(
        address indexed strategy,
        bool isActive,
        bool isEmergency
    );

    event StrategyAllocationUpdated(
        address indexed strategy,
        uint256 oldAllocation,
        uint256 newAllocation
    );

    event FundsAllocatedToStrategy(
        address indexed strategy,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event FundsWithdrawnFromStrategy(
        address indexed strategy,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event StrategyHarvested(
        address indexed strategy,
        int256 netPnL,
        uint256 feesCollected,
        uint256 newTotalValue
    );

    // Emergency Events
    event EmergencyModeActivated(address indexed triggeredBy);
    event EmergencyModeDeactivated(address indexed triggeredBy);
    event EmergencyWithdrawal(
        address indexed strategy,
        address[] tokens,
        uint256[] amounts
    );

    // Fee Events
    event FeesCollected(
        address indexed recipient,
        uint256 amount
    );

    event FeeParametersUpdated(
        uint256 managementFee,
        uint256 performanceFee
    );

    // ============================================================
    //                    SPOKE FUNCTIONS
    // ============================================================

    /// @notice Deposit tokens from an authorized spoke vault
    /// @dev Only callable by registered and active spoke vaults
    /// @param tokens Array of token addresses to deposit
    /// @param amounts Array of amounts for each token
    /// @return details Struct containing shares minted and USD value
    function deposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (DepositDetails memory details);

    /// @notice Withdraw tokens back to the calling spoke vault
    /// @dev Only callable by registered and active spoke vaults
    /// @param shares Amount of shares to burn
    /// @return details Struct containing tokens and amounts withdrawn
    function withdraw(
        uint256 shares
    ) external returns (WithdrawDetails memory details);

    /// @notice Withdraw specific tokens back to spoke (if available)
    /// @dev Attempts to fulfill from idle funds first, then strategies
    /// @param shares Amount of shares to burn
    /// @param preferredTokens Tokens the spoke prefers to receive
    /// @param minAmountsOut Minimum amounts for slippage protection
    /// @return details Struct containing tokens and amounts withdrawn
    function withdrawWithPreference(
        uint256 shares,
        address[] calldata preferredTokens,
        uint256[] calldata minAmountsOut
    ) external returns (WithdrawDetails memory details);

    // ============================================================
    //                   STRATEGY FUNCTIONS
    // ============================================================

    /// @notice Allocate idle funds to a specific strategy
    /// @dev Only callable by strategist role
    /// @param params Allocation parameters including slippage protection
    function allocateToStrategy(AllocationParams calldata params) external;

    /// @notice Withdraw funds from a strategy back to hub idle
    /// @dev Only callable by strategist role
    /// @param strategy Strategy address to withdraw from
    /// @param tokens Tokens to withdraw
    /// @param amounts Amounts to withdraw
    /// @param minValueOut Minimum USD value (slippage protection)
    function withdrawFromStrategy(
        address strategy,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256 minValueOut
    ) external;

    /// @notice Harvest gains/losses from a strategy
    /// @dev Can be called by keeper role, updates share price
    /// @param strategy Strategy to harvest
    /// @return result Harvest results including PnL
    function harvest(address strategy) external returns (HarvestResult memory result);

    /// @notice Harvest all active strategies
    /// @dev Iterates through all strategies, can be gas intensive
    /// @return results Array of harvest results
    function harvestAll() external returns (HarvestResult[] memory results);

    /// @notice Rebalance funds across strategies to match target allocations
    /// @dev Only callable by strategist role
    function rebalance() external;

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    // Spoke Management
    /// @notice Register a new spoke vault
    /// @param spoke Spoke vault address
    /// @param chainSelector CCIP chain selector (0 for same chain)
    function addSpoke(address spoke, uint64 chainSelector) external;

    /// @notice Unregister a spoke vault
    /// @dev Spoke must have zero shares before removal
    /// @param spoke Spoke vault address to remove
    function removeSpoke(address spoke) external;

    /// @notice Enable/disable a spoke vault
    /// @param spoke Spoke vault address
    /// @param isActive New active status
    function setSpokeStatus(address spoke, bool isActive) external;

    // Strategy Management
    /// @notice Add a new strategy
    /// @param strategy Strategy contract address
    /// @param name Human readable name
    /// @param targetAllocation Target allocation in basis points
    function addStrategy(
        address strategy,
        string calldata name,
        uint256 targetAllocation
    ) external;

    /// @notice Remove a strategy
    /// @dev Strategy must have zero funds before removal
    /// @param strategy Strategy address to remove
    function removeStrategy(address strategy) external;

    /// @notice Update strategy target allocation
    /// @param strategy Strategy address
    /// @param newAllocation New target allocation in basis points
    function setStrategyAllocation(address strategy, uint256 newAllocation) external;

    /// @notice Enable/disable a strategy for new deposits
    /// @param strategy Strategy address
    /// @param isActive New active status
    function setStrategyStatus(address strategy, bool isActive) external;

    // Fee Management
    /// @notice Update fee parameters
    /// @param managementFeeBps Annual management fee in basis points
    /// @param performanceFeeBps Performance fee on profits in basis points
    function setFees(uint256 managementFeeBps, uint256 performanceFeeBps) external;

    /// @notice Set the fee recipient address
    /// @param recipient Address to receive collected fees
    function setFeeRecipient(address recipient) external;

    // Asset Management
    /// @notice Add a new supported asset
    /// @param asset Token address
    /// @param priceFeed Chainlink price feed address
    function addAsset(address asset, address priceFeed) external;

    /// @notice Remove a supported asset
    /// @dev Asset must have zero balance
    /// @param asset Token address to remove
    function removeAsset(address asset) external;

    /// @notice Update price feed for an asset
    /// @param asset Token address
    /// @param newPriceFeed New Chainlink price feed address
    function updatePriceFeed(address asset, address newPriceFeed) external;

    // ============================================================
    //                   EMERGENCY FUNCTIONS
    // ============================================================

    /// @notice Activate emergency mode - pause deposits, allow only withdrawals
    /// @dev Only callable by guardian role
    function activateEmergencyMode() external;

    /// @notice Deactivate emergency mode
    /// @dev Only callable by admin after situation resolved
    function deactivateEmergencyMode() external;

    /// @notice Emergency withdraw all funds from a strategy
    /// @dev Only callable in emergency mode by guardian
    /// @param strategy Strategy to withdraw from
    function emergencyWithdrawFromStrategy(address strategy) external;

    /// @notice Emergency withdraw all funds from all strategies
    /// @dev Nuclear option - returns all funds to idle
    function emergencyWithdrawAll() external;

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    // Spoke Views
    /// @notice Get information about a spoke vault
    /// @param spoke Spoke vault address
    function getSpokeInfo(address spoke) external view returns (SpokeInfo memory);

    /// @notice Get all registered spoke addresses
    function getAllSpokes() external view returns (address[] memory);

    /// @notice Check if an address is an authorized spoke
    /// @param spoke Address to check
    function isAuthorizedSpoke(address spoke) external view returns (bool);

    // Strategy Views
    /// @notice Get information about a strategy
    /// @param strategy Strategy address
    function getStrategyInfo(address strategy) external view returns (StrategyInfo memory);

    /// @notice Get all registered strategy addresses
    function getAllStrategies() external view returns (address[] memory);

    /// @notice Get current total value deployed to strategies
    function getTotalDeployedValue() external view returns (uint256);

    /// @notice Get current idle (undeployed) value
    function getIdleValue() external view returns (uint256);

    /// @notice Get current allocation percentages for all strategies
    /// @return strategies Array of strategy addresses
    /// @return currentAllocations Current allocation in basis points
    /// @return targetAllocations Target allocation in basis points
    function getAllocations() external view returns (
        address[] memory strategies,
        uint256[] memory currentAllocations,
        uint256[] memory targetAllocations
    );

    // Fee Views
    /// @notice Get current fee parameters
    /// @return managementFeeBps Annual management fee in basis points
    /// @return performanceFeeBps Performance fee in basis points
    /// @return feeRecipient Address receiving fees
    function getFeeParams() external view returns (
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        address feeRecipient
    );

    /// @notice Get pending fees to be collected
    function getPendingFees() external view returns (uint256);

    // State Views
    /// @notice Check if hub is in emergency mode
    function isEmergencyMode() external view returns (bool);

    /// @notice Get the maximum number of strategies allowed
    function maxStrategies() external view returns (uint256);
}
```

### 3.4 IStrategy.sol (For Your Strategy Implementations)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Interface that all hub vault strategies must implement
/// @dev Strategies handle actual yield generation (Aave, Uniswap, etc.)
interface IStrategy {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    struct StrategyParams {
        address hub;                // Hub vault this strategy serves
        address[] supportedTokens;  // Tokens this strategy can accept
        string name;                // Human readable name
        string protocol;            // Protocol name (e.g., "Aave", "Uniswap")
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    error Strategy__NotHub(address caller);
    error Strategy__TokenNotSupported(address token);
    error Strategy__InsufficientBalance(address token, uint256 requested, uint256 available);
    error Strategy__DepositFailed(string reason);
    error Strategy__WithdrawFailed(string reason);
    error Strategy__Paused();

    // ============================================================
    //                          EVENTS
    // ============================================================

    event Deposited(
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event Withdrawn(
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    event Harvested(
        int256 pnl,
        uint256 timestamp
    );

    event EmergencyWithdraw(
        address[] tokens,
        uint256[] amounts
    );

    // ============================================================
    //                    CORE FUNCTIONS
    // ============================================================

    /// @notice Deposit tokens into the strategy
    /// @dev Only callable by hub vault
    /// @param tokens Token addresses to deposit
    /// @param amounts Amounts to deposit
    function deposit(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external;

    /// @notice Withdraw tokens from the strategy
    /// @dev Only callable by hub vault
    /// @param tokens Token addresses to withdraw
    /// @param amounts Amounts to withdraw
    /// @return actualAmounts Actual amounts withdrawn (may differ due to slippage)
    function withdraw(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (uint256[] memory actualAmounts);

    /// @notice Withdraw all funds from strategy (emergency or full exit)
    /// @dev Only callable by hub vault
    /// @return tokens Token addresses returned
    /// @return amounts Amounts returned
    function withdrawAll() external returns (
        address[] memory tokens,
        uint256[] memory amounts
    );

    /// @notice Harvest any pending rewards/gains
    /// @dev Called periodically to realize gains/losses
    /// @return pnl Net profit/loss since last harvest (can be negative)
    function harvest() external returns (int256 pnl);

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the hub vault this strategy serves
    function hub() external view returns (address);

    /// @notice Get strategy name
    function name() external view returns (string memory);

    /// @notice Get underlying protocol name
    function protocol() external view returns (string memory);

    /// @notice Get all tokens this strategy supports
    function supportedTokens() external view returns (address[] memory);

    /// @notice Check if a token is supported
    function isTokenSupported(address token) external view returns (bool);

    /// @notice Get current total value of strategy holdings in USD
    function totalValueUsd() external view returns (uint256);

    /// @notice Get current balance of a specific token in strategy
    /// @param token Token address to query
    function tokenBalance(address token) external view returns (uint256);

    /// @notice Get all token balances
    /// @return tokens Token addresses
    /// @return balances Balance of each token
    function allBalances() external view returns (
        address[] memory tokens,
        uint256[] memory balances
    );

    /// @notice Estimate withdrawable amount for a token
    /// @dev May be less than balance due to lockups, slippage, etc.
    /// @param token Token address
    function estimateWithdrawable(address token) external view returns (uint256);

    /// @notice Check if strategy is paused
    function paused() external view returns (bool);

    /// @notice Get the APY this strategy is currently generating
    /// @return apy APY in basis points (100 = 1%)
    function currentApy() external view returns (uint256 apy);
}
```

---

## Part 4: Implementation Priority Checklist

### Phase 1: Fix Critical Bugs (Do First)

- [ ] Fix BasePeriphery array bug (line 283-287)
- [ ] Fix previewDeposit require logic (line 390)
- [ ] Fix previewWithdraw double calculation
- [ ] Add missing `getSupportedTokens()` alias
- [ ] Add missing `isSupportedToken()` function
- [ ] Add missing `quoteWithdraw()` function

### Phase 2: Add Security Features

- [ ] Add `nonReentrant` to SpokeVault deposit/withdraw
- [ ] Add `whenNotPaused` to critical functions
- [ ] Add slippage protection to hub transfers
- [ ] Add minimum deposit amount check (prevent dust attacks)

### Phase 3: Implement Interfaces

- [ ] Create interfaces directory: `src/interfaces/`
- [ ] Implement IVault.sol
- [ ] Implement ISpokeVault.sol
- [ ] Implement IHubVault.sol
- [ ] Implement IStrategy.sol
- [ ] Refactor SpokeVault to use IHubVault instead of concrete HubVault

### Phase 4: Standardize Code Quality

- [ ] Replace all string reverts with custom errors
- [ ] Update events to match multi-asset reality
- [ ] Add full NatSpec to all public/external functions
- [ ] Standardize loop variable types (use uint256)
- [ ] Remove unused code and commented sections

### Phase 5: Implement HubVault

- [ ] Create HubVault.sol implementing IHubVault
- [ ] Create base Strategy.sol implementing IStrategy
- [ ] Create AaveStrategy.sol
- [ ] Create UniswapStrategy.sol (LP or swap strategy)

---

## Part 5: File Structure Recommendation

```
src/
├── interfaces/
│   ├── IVault.sol
│   ├── ISpokeVault.sol
│   ├── IHubVault.sol
│   ├── IStrategy.sol
│   └── IBasePeriphery.sol
├── core/
│   ├── Vault.sol           (abstract base)
│   ├── SpokeVault.sol
│   └── HubVault.sol
├── periphery/
│   ├── BasePeriphery.sol
│   └── RemotePeriphery.sol
├── strategies/
│   ├── BaseStrategy.sol    (abstract)
│   ├── AaveStrategy.sol
│   └── UniswapStrategy.sol
├── libraries/
│   ├── OracleLib.sol
│   └── ShareMath.sol
└── utils/
    └── Errors.sol          (shared custom errors)
```

Let me do a comprehensive review of your current implementation and create a clear roadmap to HubVault and strategies.

---

## Current State Analysis

### BasePeriphery.sol — Issues Found

| Issue | Severity   | Location                      | Description                                                                                      |
| ----- | ---------- | ----------------------------- | ------------------------------------------------------------------------------------------------ |
| 1     | **Medium** | `_filterSupportedTokens` loop | Missing `unchecked { ++i; }` for zero amount case — infinite loop                                |
| 2     | **Low**    | Unused imports                | `EnumerableSet`, `OracleLib` not used                                                            |
| 3     | **Low**    | Unused storage                | `LiquidityProvider`, `ProviderRequest` structs, `providers` mapping never used                   |
| 4     | **Low**    | Incomplete functions          | `submitProviderRequest`, `acceptProviderRequest`, `requestWithdrawal`, `executeWithdrawal` empty |
| 5     | **Low**    | `isChainAllowed`              | Returns nothing                                                                                  |
| 6     | **Medium** | Cross-chain ledger            | Not implemented yet (we discussed this)                                                          |

### SpokeVault.sol — Issues Found

| Issue | Severity     | Location                        | Description                                                       |
| ----- | ------------ | ------------------------------- | ----------------------------------------------------------------- |
| 1     | **Critical** | `transferFundsToHub`            | Uses `details.sharesMinted` but variable is `depositDetailsOnHub` |
| 2     | **Medium**   | `transferAllFundsToHub`         | Passes wrong parameters — `amounts` is empty array                |
| 3     | **Low**      | Missing `whenNotPaused`         | On `deposit` function                                             |
| 4     | **Medium**   | No cross-chain balance tracking | `crossChainBalances` mapping not implemented                      |
| 5     | **Low**      | `withdrawTo` naming             | Should be `withdrawCrossChain` for clarity                        |

### Vault.sol — Issues Found

| Issue | Severity     | Location                 | Description                                                                            |
| ----- | ------------ | ------------------------ | -------------------------------------------------------------------------------------- |
| 1     | **Critical** | `_filterSupportedTokens` | Loop increment inside `if (amount != 0)` — skips zero amounts but also skips increment |
| 2     | **Medium**   | `previewWithdraw`        | Never populates `amounts` array — returns zeros                                        |
| 3     | **Medium**   | `_deposit`               | Strict equality check can fail due to rounding                                         |
| 4     | **Low**      | `Withdraw` event         | Still has old `wethOut`, `usdcOut` format                                              |
| 5     | **Low**      | String reverts           | Should use custom errors throughout                                                    |

---

## Critical Bug Fixes Needed Now

### 1. Vault.sol `_filterSupportedTokens` — Infinite Loop

```solidity
// CURRENT (BUGGY):
if (amount != 0) {
    // ... logic ...
    unchecked { ++i; }  // ❌ Only increments when amount != 0
}

// FIXED:
if (amount != 0) {
    // ... logic ...
}
unchecked { ++i; }  // ✅ Always increment
```

### 2. Vault.sol `previewWithdraw` — Never Populates Amounts

```solidity
// CURRENT (BUGGY):
uint256[] memory amounts = new uint256[](n);
// ... loop calculates amountOut but never stores it ...
return (tokensArr, amounts, withdrawUsdValue);  // amounts is all zeros!

// FIXED:
for (uint256 i = 0; i < n; i++) {
    // ...
    amounts[i] = amountOut;  // ✅ Store the calculated amount
    withdrawUsdValue += _tokenValueUsd(asset, amountOut);
}
```

### 3. SpokeVault.sol `transferFundsToHub` — Wrong Variable

```solidity
// CURRENT (BUGGY):
if (details.sharesMinted < minSharesOut) {  // ❌ 'details' undefined

// FIXED:
if (depositDetailsOnHub.sharesMinted < minSharesOut) {  // ✅
```

### 4. SpokeVault.sol `transferAllFundsToHub` — Empty Amounts

```solidity
// CURRENT (BUGGY):
uint256[] memory amounts;  // Empty array
transferFundsToHub(amounts, tokensAddress);  // ❌ No minSharesOut parameter

// FIXED:
function transferAllFundsToHub(uint256 minSharesOut) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address[] memory tokensAddress = getSupportedAssets();
    uint256[] memory amounts = new uint256[](tokensAddress.length);

    for (uint256 i = 0; i < tokensAddress.length; i++) {
        amounts[i] = IERC20(tokensAddress[i]).balanceOf(address(this));
    }

    transferFundsToHub(amounts, tokensAddress, minSharesOut);
}
```

---

## Implementation Roadmap

### Phase 1: Fix Critical Bugs (Do First) ⚠️

```
□ Fix _filterSupportedTokens loop increment
□ Fix previewWithdraw amounts population
□ Fix transferFundsToHub variable name
□ Fix transferAllFundsToHub logic
□ Remove strict equality check in _deposit
```

### Phase 2: Complete Withdraw Flow

```
□ Add cross-chain balance tracking to SpokeVault
    - mapping(address => mapping(uint64 => uint256)) crossChainBalances
    - mapping(address => mapping(uint64 => uint256)) lastCrossChainWithdrawal
    - uint256 totalCrossChainShares

□ Add depositCrossChain() to SpokeVault
□ Add withdrawCrossChain() to SpokeVault
□ Update BasePeriphery to use new cross-chain functions
□ Add proper events for cross-chain operations
```

### Phase 3: Clean Up Code Quality

```
□ Replace all string reverts with custom errors
□ Remove unused imports and storage
□ Remove or implement empty TODO functions
□ Standardize event parameters
□ Add NatSpec documentation
□ Add missing view functions (isSupportedToken, quoteWithdraw)
```

### Phase 4: Create Interfaces

```
□ IVault.sol (done - I provided earlier)
□ ISpokeVault.sol (done - I provided earlier)
□ IHubVault.sol (done - I provided earlier)
□ IStrategy.sol (done - I provided earlier)
□ IBasePeriphery.sol (need to create)
```

### Phase 5: Implement HubVault

```
□ Create HubVault.sol implementing IHubVault
    - Spoke management (add/remove/status)
    - Strategy management (add/remove/allocate)
    - Fee collection
    - Emergency functions

□ Core functions:
    - deposit() — called by spokes
    - withdraw() — called by spokes
    - allocateToStrategy()
    - withdrawFromStrategy()
    - harvest()
    - rebalance()
```

### Phase 6: Implement Base Strategy

```
□ Create BaseStrategy.sol (abstract)
    - Common strategy logic
    - Hub interaction
    - Accounting

□ Core functions:
    - deposit()
    - withdraw()
    - withdrawAll()
    - harvest()
    - totalValue()
```

### Phase 7: Implement Specific Strategies

```
□ AaveStrategy.sol
    - Supply/withdraw to Aave
    - Claim rewards
    - Health factor monitoring

□ UniswapStrategy.sol (or UniswapHook.sol)
    - LP provision
    - Fee collection
    - Custom hook logic
```

---

## Immediate Next Steps (Priority Order)

### Step 1: Fix Critical Bugs

Let me provide the fixes:

```solidity
// ============================================
// Vault.sol - Fix _filterSupportedTokens
// ============================================
function _filterSupportedTokens(
    address[] memory _assets,
    uint256[] memory _amounts
) internal view returns (address[] memory, uint256[] memory) {
    uint256 len = _assets.length;
    uint256 maxTokens = supportedAssets.length();

    if (len != _amounts.length || len > maxTokens || len == 0) {
        revert Vault__LengthMismatch();
    }

    address[] memory filteredAssets = new address[](maxTokens);
    uint256[] memory filteredAmounts = new uint256[](maxTokens);
    uint256 uniqueCount;

    for (uint256 i; i < len; ) {
        address asset = _assets[i];
        uint256 amount = _amounts[i];

        if (amount != 0) {
            bool found;
            for (uint256 j; j < uniqueCount; ) {
                if (filteredAssets[j] == asset) {
                    filteredAmounts[j] += amount;
                    found = true;
                    break;
                }
                unchecked { ++j; }
            }

            if (!found) {
                filteredAssets[uniqueCount] = asset;
                filteredAmounts[uniqueCount] = amount;
                unchecked { ++uniqueCount; }
            }
        }

        unchecked { ++i; }  // ✅ MOVED OUTSIDE if block
    }

    if (uniqueCount == 0) revert Vault__NoValidDeposits();

    assembly {
        mstore(filteredAssets, uniqueCount)
        mstore(filteredAmounts, uniqueCount)
    }

    return (filteredAssets, filteredAmounts);
}

// ============================================
// Vault.sol - Fix previewWithdraw
// ============================================
function previewWithdraw(
    uint256 _shares
) public view returns (address[] memory, uint256[] memory, uint256) {
    uint256 totalSharesBefore = totalSupply();
    uint256 n = supportedAssets.length();
    uint256[] memory amounts = new uint256[](n);
    uint256 withdrawUsdValue;

    for (uint256 i; i < n; ) {
        address asset = supportedAssets.at(i);
        uint256 vaultBal = IERC20(asset).balanceOf(address(this));

        uint256 amountOut;
        if (_shares == totalSharesBefore) {
            amountOut = vaultBal;
        } else {
            amountOut = Math.mulDiv(vaultBal, _shares, totalSharesBefore);
        }

        amounts[i] = amountOut;  // ✅ Store the amount
        withdrawUsdValue += _tokenValueUsd(asset, amountOut);

        unchecked { ++i; }
    }

    return (supportedAssets.values(), amounts, withdrawUsdValue);
}

// ============================================
// Vault.sol - Fix _deposit (remove strict check)
// ============================================
function _deposit(...) internal returns (DepositDetails memory depositDetails) {
    // ... existing code ...

    // ❌ REMOVE THIS:
    // require(
    //     (vaultValueAfterDeposit - vaultValueBeforeDeposit) == totalDepositValueUsd
    // );

    // ✅ Optional: Add tolerance check instead
    // uint256 actualIncrease = vaultValueAfterDeposit - vaultValueBeforeDeposit;
    // require(actualIncrease >= totalDepositValueUsd * 99 / 100, "Value mismatch");

    _mint(_receiver, sharesMinted);
    // ... rest ...
}
```

### Step 2: Add Cross-Chain Balance Tracking to SpokeVault

```solidity
// Add to SpokeVault.sol

// ============================================
// CROSS-CHAIN STORAGE
// ============================================
mapping(address => mapping(uint64 => uint256)) public crossChainBalances;
mapping(address => mapping(uint64 => uint256)) public lastCrossChainWithdrawal;
uint256 public totalCrossChainShares;

// ============================================
// CROSS-CHAIN ERRORS
// ============================================
error SpokeVault__InsufficientCrossChainShares(uint256 requested, uint256 available);
error SpokeVault__InvalidChainSelector();
error SpokeVault__CrossChainCooldownActive(uint256 timeRemaining);

// ============================================
// CROSS-CHAIN EVENTS
// ============================================
event CrossChainDeposit(
    address indexed user,
    uint64 indexed chainSelector,
    uint256 sharesMinted,
    uint256 totalValueUsd
);

event CrossChainWithdrawal(
    address indexed user,
    uint64 indexed chainSelector,
    uint256 sharesBurned,
    address[] tokens,
    uint256[] amounts,
    uint256 totalValueUsd
);

// ============================================
// CROSS-CHAIN FUNCTIONS
// ============================================
function depositCrossChain(
    address _user,
    uint64 _chainSelector,
    address[] memory _tokens,
    uint256[] memory _amounts
)
    external
    onlyRole(PERIPHERY_ROLE)
    nonReentrant
    whenNotPaused
    returns (DepositDetails memory depositDetails)
{
    if (_chainSelector == 0) revert SpokeVault__InvalidChainSelector();

    // Mint shares to this contract (not user)
    depositDetails = _deposit(address(this), _tokens, _amounts);

    // Track in cross-chain ledger
    crossChainBalances[_user][_chainSelector] += depositDetails.sharesMinted;
    totalCrossChainShares += depositDetails.sharesMinted;

    emit CrossChainDeposit(
        _user,
        _chainSelector,
        depositDetails.sharesMinted,
        depositDetails.totalUsdAmount
    );
}

function withdrawCrossChain(
    address _user,
    uint64 _chainSelector,
    uint256 _shares
)
    external
    onlyRole(PERIPHERY_ROLE)
    nonReentrant
    whenNotPaused
    returns (WithdrawDetails memory withdrawDetails)
{
    if (_chainSelector == 0) revert SpokeVault__InvalidChainSelector();
    if (_shares == 0) revert Vault__InvalidShares();

    uint256 userBalance = crossChainBalances[_user][_chainSelector];
    if (_shares > userBalance) {
        revert SpokeVault__InsufficientCrossChainShares(_shares, userBalance);
    }

    // Check cooldown
    uint256 lastWithdraw = lastCrossChainWithdrawal[_user][_chainSelector];
    if (block.timestamp < lastWithdraw + WITHDRAWAL_COOLDOWN) {
        revert SpokeVault__CrossChainCooldownActive(
            lastWithdraw + WITHDRAWAL_COOLDOWN - block.timestamp
        );
    }
    lastCrossChainWithdrawal[_user][_chainSelector] = block.timestamp;

    // Update ledger BEFORE external calls (CEI)
    crossChainBalances[_user][_chainSelector] -= _shares;
    totalCrossChainShares -= _shares;

    // Withdraw - shares owned by this contract, tokens go to periphery
    withdrawDetails = _withdraw(address(this), _shares, basePeriphery.periphery);

    emit CrossChainWithdrawal(
        _user,
        _chainSelector,
        _shares,
        withdrawDetails.tokensReceived,
        withdrawDetails.amountsReceived,
        withdrawDetails.withdrawValueInUsd
    );
}

// ============================================
// CROSS-CHAIN VIEW FUNCTIONS
// ============================================
function getCrossChainBalance(
    address _user,
    uint64 _chainSelector
) external view returns (uint256) {
    return crossChainBalances[_user][_chainSelector];
}

function getCrossChainBalanceUsd(
    address _user,
    uint64 _chainSelector
) external view returns (uint256) {
    uint256 shares = crossChainBalances[_user][_chainSelector];
    if (shares == 0) return 0;
    return (shares * pricePerShare()) / 1e18;
}
```

### Step 3: Update BasePeriphery to Use Cross-Chain Functions

```solidity
// Update in BasePeriphery.sol

function _handleDeposit(
    address provider,
    address[] memory assets,
    uint256[] memory amounts,
    bool isCrossChain,
    uint64 sourceChain
) internal returns (SpokeVault.DepositDetails memory depositDetails) {
    // ... validation and transfer logic stays same ...

    if (isCrossChain) {
        // ✅ Use cross-chain specific function
        depositDetails = spoke.depositCrossChain(provider, sourceChain, assets, amounts);
    } else {
        // Native deposit - shares go to user as ERC20
        depositDetails = spoke.deposit(provider, assets, amounts);
    }
}

function _handleWithdraw(
    address provider,
    uint256 shares,
    bool isCrossChain,
    uint64 sourceChain
) internal returns (SpokeVault.WithdrawDetails memory withdrawDetails) {
    if (shares == 0) revert BasePeriphery__InvalidShares();
    if (provider == address(0)) revert BasePeriphery__ZeroAddress();

    if (isCrossChain) {
        // ✅ Use cross-chain specific function
        withdrawDetails = spoke.withdrawCrossChain(provider, sourceChain, shares);
    } else {
        // Native withdrawal - tokens go directly to user
        withdrawDetails = spoke.withdraw(provider, shares);
    }
}
```

---

## After Fixes: HubVault Implementation

---

## Summary: What to Do Next

| Priority | Task                                            | Effort    |
| -------- | ----------------------------------------------- | --------- |
| 1        | Fix `_filterSupportedTokens` loop               | 5 min     |
| 2        | Fix `previewWithdraw` amounts                   | 5 min     |
| 3        | Fix `transferFundsToHub` bugs                   | 10 min    |
| 4        | Remove strict equality check in `_deposit`      | 2 min     |
| 5        | Add cross-chain storage/functions to SpokeVault | 30 min    |
| 6        | Update BasePeriphery for cross-chain            | 15 min    |
| 7        | Clean up unused code                            | 20 min    |
| 8        | Create HubVault                                 | 2-3 hours |
| 9        | Create BaseStrategy                             | 1-2 hours |
| 10       | Create AaveStrategy                             | 2-3 hours |
| 11       | Create UniswapStrategy/Hook                     | 3-4 hours |

---

Want me to help you fix the critical bugs first, or should we move directly to implementing HubVault with the understanding that you'll fix those bugs?

---
