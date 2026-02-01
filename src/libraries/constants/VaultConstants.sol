// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library VaultConstants {
    // CONSTANT AND IMMUTABLES
    uint256 public constant MAX_ALLOWED_TOKENS = 4;
    uint256 public constant INITIAL_SUPPLY = 100e18;
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 hours;

    /// @notice Minimum deposit to prevent share inflation attacks
    uint256 public constant MIN_DEPOSIT_USD = 10e18; // $10.00

    /// @notice Precision for share calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Tolerance for deposit value verification (99% = 1% tolerance)
    uint256 public constant DEPOSIT_TOLERANCE_BPS = 9900;

    // /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint64 public constant HUB_CHAIN = 0;

    // ROLES
    bytes32 public constant ALLOCATOR_ROLE = keccak256("SPOKE_ALLOCATOR");
    bytes32 public constant PERIPHERY_ROLE = keccak256("BASE_PERIPHERY");
}
