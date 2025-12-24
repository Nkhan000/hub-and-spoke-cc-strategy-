// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVault
/// @author Nazir Khan
/// @notice Base interface for multi-asset vault operations
/// @dev Defines core structs, errors, events, and view functions shared by all vault types
interface IVault {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    /// @notice Details returned after a deposit operation
    /// @param sharesMinted Number of vault shares minted to receiver
    /// @param totalUsdAmount Total USD value of deposited assets (18 decimals)
    struct DepositDetails {
        uint256 sharesMinted;
        uint256 totalUsdAmount;
    }

    /// @notice Details returned after a withdrawal operation
    /// @param tokensReceived Array of token addresses withdrawn
    /// @param amountsReceived Array of amounts for each token
    /// @param withdrawValueInUsd Total USD value withdrawn (18 decimals)
    struct WithdrawDetails {
        address[] tokensReceived;
        uint256[] amountsReceived;
        uint256 withdrawValueInUsd;
    }

    /// @notice Information about a supported token
    /// @param token Token contract address
    /// @param priceFeed Chainlink price feed address
    /// @param isActive Whether deposits are accepted for this token
    struct TokenInfo {
        address token;
        address priceFeed;
        bool isActive;
    }

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @notice Thrown when a zero address is provided where not allowed
    error Vault__ZeroAddress();

    /// @notice Thrown when an invalid amount is provided
    error Vault__InvalidAmount();

    /// @notice Thrown when array lengths don't match
    error Vault__LengthMismatch();

    /// @notice Thrown when deposit exceeds maximum allowed tokens
    /// @param provided Number of tokens provided
    /// @param max Maximum allowed tokens
    error Vault__ExceedsMaxTokens(uint256 provided, uint256 max);

    /// @notice Thrown when an unsupported token is used
    /// @param token The unsupported token address
    error Vault__TokenNotSupported(address token);

    /// @notice Thrown when a token is not active for deposits
    /// @param token The inactive token address
    error Vault__TokenNotActive(address token);

    /// @notice Thrown when user has insufficient shares
    /// @param requested Shares requested to burn
    /// @param available Shares actually available
    error Vault__InsufficientShares(uint256 requested, uint256 available);

    /// @notice Thrown when withdrawal cooldown is still active
    /// @param timeRemaining Seconds until cooldown expires
    error Vault__CooldownActive(uint256 timeRemaining);

    /// @notice Thrown when price feed returns invalid data
    /// @param token Token with invalid price
    error Vault__InvalidPrice(address token);

    /// @notice Thrown when operation would mint zero shares
    error Vault__ZeroShares();

    /// @notice Thrown when deposit has zero value
    error Vault__ZeroDeposit();

    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when tokens are deposited into the vault
    /// @param depositor Address that initiated the deposit
    /// @param receiver Address that received the minted shares
    /// @param tokens Array of deposited token addresses
    /// @param amounts Array of deposited amounts
    /// @param sharesMinted Number of shares minted
    /// @param totalValueUsd Total USD value of deposit (18 decimals)
    event Deposited(
        address indexed depositor,
        address indexed receiver,
        address[] tokens,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalValueUsd
    );

    /// @notice Emitted when shares are burned for token withdrawal
    /// @param owner Address that owned the burned shares
    /// @param receiver Address that received the withdrawn tokens
    /// @param sharesBurned Number of shares burned
    /// @param tokens Array of withdrawn token addresses
    /// @param amounts Array of withdrawn amounts
    /// @param totalValueUsd Total USD value withdrawn (18 decimals)
    event Withdrawn(
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        address[] tokens,
        uint256[] amounts,
        uint256 totalValueUsd
    );

    /// @notice Emitted when a new asset is added to the vault
    /// @param asset Token address added
    /// @param priceFeed Chainlink price feed for the asset
    event AssetAdded(address indexed asset, address indexed priceFeed);

    /// @notice Emitted when an asset is removed from the vault
    /// @param asset Token address removed
    event AssetRemoved(address indexed asset);

    /// @notice Emitted when a price feed is updated
    /// @param asset Token address
    /// @param oldFeed Previous price feed address
    /// @param newFeed New price feed address
    event PriceFeedUpdated(
        address indexed asset,
        address indexed oldFeed,
        address indexed newFeed
    );

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Returns the maximum number of tokens allowed per deposit
    /// @return Maximum token count
    function MAX_ALLOWED_TOKENS() external view returns (uint256);

    /// @notice Returns all supported asset addresses
    /// @return Array of supported token addresses
    function getSupportedAssets() external view returns (address[] memory);

    /// @notice Checks if an asset is currently active for deposits
    /// @param asset The asset address to check
    /// @return True if asset is active
    function isActiveAsset(address asset) external view returns (bool);

    /// @notice Returns the total vault value in USD
    /// @return Total value with 18 decimals
    function totalVaultValueUsd() external view returns (uint256);

    /// @notice Returns the current price per share in USD
    /// @return Price per share with 18 decimals
    function pricePerShare() external view returns (uint256);

    /// @notice Calculates USD value for a given token amount
    /// @param token The token address
    /// @param amount The amount of tokens
    /// @return valueUsd The USD value with 18 decimals
    function tokenValueUsd(
        address token,
        uint256 amount
    ) external view returns (uint256 valueUsd);

    /// @notice Returns the share balance of an account
    /// @param account The account to query
    /// @return Total shares held by account
    function getAllShares(address account) external view returns (uint256);

    /// @notice Returns the USD value of an account's shares
    /// @param account The account to query
    /// @return Total USD value of account's shares (18 decimals)
    function getAllUserSharesValueUsd(
        address account
    ) external view returns (uint256);

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
    /// @return tokens Array of token addresses to receive
    /// @return amounts Array of token amounts to receive
    /// @return valueUsd Total USD value of withdrawal
    function previewWithdraw(
        uint256 shares
    )
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory amounts,
            uint256 valueUsd
        );
}
