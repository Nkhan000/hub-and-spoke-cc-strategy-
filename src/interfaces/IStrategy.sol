// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategy {
    // -------------------------------
    function assets() external view returns (address[] memory); //underlying token(s)

    function vault() external view returns (address); // vault address;

    function name() external view returns (string memory); // "Aave V3 USDC" ? do we need this ??

    // -------------------------------

    // -------------------------------
    function deposit(
        uint256[] memory amount,
        address[] memory tokens
    )
        external
        returns (
            uint256[] memory totalAmountDeposited,
            address[] memory totalTokensDeposited
        );

    function withdraw(
        uint256[] memory amount,
        address[] memory tokens
    )
        external
        returns (
            address[] memory totalAmountWithdrawn,
            address[] memory totalTokensWithdrawn
        );

    function withdrawAll(
        address[] memory tokens
    ) external returns (address[] memory totalTokensWithdrawn);

    // -------------------------------

    function totalAssets() external view returns (uint256); // current value held

    function estimatedAPR() external view returns (uint256); // basis points e.g. 450 = 4.5%

    function isHealthy() external view returns (bool); // circuit breaker check

    // ====================================== //
    function harvest() external returns (uint256 profit, uint256 loss); // sends profit/loss reports to the manager

    function tend() external; // reinvest without harvesting

    // ─── Emergency ───────────────────────────────────────────────
    function emergencyExit() external;

    function isEmergencyMode() external view returns (bool);
}
