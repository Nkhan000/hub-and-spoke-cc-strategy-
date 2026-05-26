// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library VaultErrors {
    // ERRORS
    error MainVault__ProviderAlreadyExists();
    error MainVault__InvalidChainSelector();
    error MainVault__InvalidAddress();
    error MainVault__NotAllowedPeriphery();
    error MainVault__SlippageExceeded(
        uint256 sharesMinted,
        uint256 minSharesOut
    );

    // ERROR
    error Vault__InvalidAddress();
    error Vault__NoValidDeposits();
    error Vault__DepositValueMismatch(
        uint256 totalDepositValueUsd,
        uint256 actualIncrease
    );
    error Vault__lengthMismatch();
    error Vault__AssetNotSupported(address asset);
    error Vault__AssetNotActive(address asset);
}
