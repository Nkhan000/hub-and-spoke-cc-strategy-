// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "./IVault.sol";

/// @title ISpokeVault
/// @author Nazir Khan
/// @notice Interface for spoke vault that receives deposits from periphery contracts
/// @dev Spoke vaults aggregate funds from users and forward to hub vault for strategy deployment
interface ISpokeVault is IVault {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    /// @notice Information about the connected base periphery
    /// @param periphery Periphery contract address
    /// @param unclaimedProfit Pending profits not yet distributed
    /// @param lastDeposit Timestamp of last deposit from periphery
    /// @param lastWithdrawal Timestamp of last withdrawal to periphery
    /// @param isActive Whether periphery is currently active
    struct PeripheryInfo {
        address periphery;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    /// @notice Information about the connected hub vault
    /// @param hub Hub vault contract address
    /// @param totalSharesInHub Shares this spoke holds in hub
    /// @param lastAllocated Timestamp of last allocation to hub
    /// @param lastWithdrawal Timestamp of last withdrawal from hub
    struct HubInfo {
        address hub;
        uint256 totalSharesInHub;
        uint256 lastAllocated;
        uint256 lastWithdrawal;
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Thrown when caller is not the authorized periphery
    /// @param caller Address that attempted the call
    error SpokeVault__NotAuthorizedPeriphery(address caller);

    /// @notice Thrown when periphery is not active
    error SpokeVault__PeripheryNotActive();

    /// @notice Thrown when hub vault is not configured
    error SpokeVault__HubNotSet();

    /// @notice Thrown when invalid hub address is provided
    error SpokeVault__InvalidHubAddress();

    /// @notice Thrown when slippage exceeds acceptable limit
    /// @param received Actual amount received
    /// @param minimum Minimum expected amount
    error SpokeVault__SlippageExceeded(uint256 received, uint256 minimum);

    /// @notice Thrown when trying to withdraw more hub shares than available
    /// @param requested Shares requested
    /// @param available Shares available
    error SpokeVault__InsufficientHubShares(
        uint256 requested,
        uint256 available
    );

    /// @notice Thrown when trying to update periphery that still has shares
    /// @param shares Remaining shares held by periphery
    error SpokeVault__PeripheryHasShares(uint256 shares);

    /// @notice Thrown when periphery has unclaimed profits
    /// @param amount Unclaimed profit amount
    error SpokeVault__UnclaimedProfitsPending(uint256 amount);

    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when funds are transferred to hub vault
    /// @param hub Hub vault address
    /// @param tokens Token addresses transferred
    /// @param amounts Amounts transferred
    /// @param hubSharesMinted Shares minted in hub vault
    /// @param totalValueUsd USD value of transfer
    event FundsTransferredToHub(
        address indexed hub,
        address[] tokens,
        uint256[] amounts,
        uint256 hubSharesMinted,
        uint256 totalValueUsd
    );

    /// @notice Emitted when funds are withdrawn from hub vault
    /// @param hub Hub vault address
    /// @param hubSharesBurned Shares burned in hub vault
    /// @param tokens Token addresses received
    /// @param amounts Amounts received
    /// @param totalValueUsd USD value of withdrawal
    event FundsWithdrawnFromHub(
        address indexed hub,
        uint256 hubSharesBurned,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    /// @notice Emitted when periphery deposits funds
    /// @param periphery Periphery contract address
    /// @param receiver Address receiving the shares
    /// @param tokens Deposited token addresses
    /// @param amounts Deposited amounts
    /// @param sharesMinted Shares minted to receiver
    /// @param totalValueUsd USD value of deposit
    event PeripheryDeposit(
        address indexed periphery,
        address indexed receiver,
        address[] tokens,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalValueUsd
    );

    /// @notice Emitted when periphery withdraws funds
    /// @param periphery Periphery contract address
    /// @param owner Share owner address
    /// @param receiver Address receiving the tokens
    /// @param sharesBurned Shares burned
    /// @param tokens Token addresses withdrawn
    /// @param amounts Amounts withdrawn
    event PeripheryWithdrawal(
        address indexed periphery,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        address[] tokens,
        uint256[] amounts
    );

    /// @notice Emitted when periphery is updated
    /// @param oldPeriphery Previous periphery address
    /// @param newPeriphery New periphery address
    event PeripheryUpdated(
        address indexed oldPeriphery,
        address indexed newPeriphery
    );

    /// @notice Emitted when periphery status changes
    /// @param periphery Periphery address
    /// @param isActive New status
    event PeripheryStatusChanged(address indexed periphery, bool isActive);

    /// @notice Emitted when hub is updated
    /// @param oldHub Previous hub address
    /// @param newHub New hub address
    event HubUpdated(address indexed oldHub, address indexed newHub);

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

    /// @notice Withdraw tokens and send to periphery (for cross-chain transfers)
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
    /// @dev Only callable by admin role
    function transferAllFundsToHub() external;

    /// @notice Transfer specific amounts to hub vault
    /// @dev Only callable by admin role
    /// @param tokens Array of token addresses to transfer
    /// @param amounts Array of amounts to transfer
    /// @param minSharesOut Minimum hub shares expected (slippage protection)
    function transferFundsToHub(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 minSharesOut
    ) external;

    /// @notice Withdraw funds from hub vault back to spoke
    /// @dev Only callable by admin role
    /// @param hubShares Amount of hub shares to burn
    /// @param minValueOut Minimum USD value expected (slippage protection)
    function withdrawFromHub(uint256 hubShares, uint256 minValueOut) external;

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    /// @notice Update the periphery contract address
    /// @dev Old periphery must have zero shares and no unclaimed profits
    /// @param newPeriphery New periphery contract address
    function updatePeriphery(address newPeriphery) external;

    /// @notice Disable the current periphery (emergency)
    /// @dev Prevents new deposits/withdrawals through periphery
    function disablePeriphery() external;

    /// @notice Re-enable the current periphery
    function enablePeriphery() external;

    /// @notice Update the hub vault address
    /// @dev Should only be done when no funds are in old hub
    /// @param newHub New hub vault address
    function updateHub(address newHub) external;

    /// @notice Add new supported assets
    /// @param assets Array of token addresses to add
    /// @param priceFeeds Array of Chainlink price feed addresses
    function addAssets(
        address[] calldata assets,
        address[] calldata priceFeeds
    ) external;

    /// @notice Remove supported assets
    /// @dev Assets must have zero balance before removal
    /// @param assets Array of token addresses to remove
    function removeAssets(address[] calldata assets) external;

    /// @notice Update price feed for an asset
    /// @param asset Token address
    /// @param newPriceFeed New Chainlink price feed address
    function updatePriceFeed(address asset, address newPriceFeed) external;

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Get current periphery information
    /// @return info PeripheryInfo struct
    function getPeripheryInfo() external view returns (PeripheryInfo memory);

    /// @notice Get current hub information
    /// @return info HubInfo struct
    function getHubInfo() external view returns (HubInfo memory);

    /// @notice Check if a token is supported (alias for isActiveAsset)
    /// @param token Token address to check
    /// @return True if token is supported and active
    function isSupportedToken(address token) external view returns (bool);

    /// @notice Quote withdrawal amounts (alias for previewWithdraw)
    /// @param shares Shares to burn
    /// @return tokens Token addresses
    /// @return amounts Token amounts
    /// @return valueUsd USD value
    function quoteWithdraw(
        uint256 shares
    )
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory amounts,
            uint256 valueUsd
        );

    /// @notice Get shares this spoke holds in the hub
    /// @return Number of hub shares owned by this spoke
    function getHubShares() external view returns (uint256);

    /// @notice Get list of supported tokens (alias for getSupportedAssets)
    /// @return Array of supported token addresses
    function getSupportedTokens() external view returns (address[] memory);
}
