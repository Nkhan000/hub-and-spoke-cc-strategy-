// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../libraries/OracleLib.sol";

/// @title A multi token vault
/// @author Nazir Khan
/// @notice Handles multiple assets sent by a liquidity provider.

interface IVault is IERC20 {
    // EVENTS
    event AssetStatusUpdated(address asset, bool status);
    event Deposited(
        address indexed receiver,
        uint256 indexed sharesMinted,
        address[] assetsDeposited,
        uint256[] amountsDeposited,
        uint256 totalDepositValueUSD
    );
    event Withdraw(
        address indexed user,
        uint256 sharesBurned,
        uint256 wethOut,
        uint256 usdcOut,
        uint256 valueUsd
    );

    event NewAssetAdded(address newAsset, address priceFeed);
    event AssetRemoved(address asset);
    event PriceFeedUpdated(address asset, address newPriceFeed);
    event AssetEnabled(address asset);
    event AssetDisabled(address asset);

    // EVENTS
    event LiquidityProviderAdded();
    event RoleGranted(address _account, bytes32 _role);
    event RoleRevoked(address _account, bytes32 _role);

    event Deposit(
        address receiver,
        address[] tokensAddresses,
        uint256[] amounts,
        uint256 sharesMinted,
        uint256 totalUsdAmount
    );
    event PeripheryWithdraw(
        address owner,
        address[] tokensReceived,
        uint256[] amountReceived,
        uint256 sharesBurnt
    );
    event BasePeripheryUpdated(address newPeriphery);
    event BasePeripheryStatusUpdated(bool status);

    event SharesDebited(
        uint64 _chain,
        address _user,
        uint256 _shares,
        uint256 userShares
    );
    event SharesCredited(
        uint64 _chain,
        address _user,
        uint256 _shares,
        uint256 userShares
    );

    struct TokenInfo {
        IERC20 token;
        AggregatorV3Interface priceFeed;
        bool isActive;
    }
    struct DepositDetails {
        uint256 sharesMinted;
        uint256 totalUsdAmount;
    }

    struct WithdrawDetails {
        address[] tokensWithdrawn;
        uint256[] amountsWithdrawn;
        uint256 withdrawValueUsd;
        uint256 sharesBurnt;
    }

    struct BasePeripheryInfo {
        address periphery;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    //
    function shareValueUsd(uint256 shares) external view returns (uint256);

    function getIdleFundsUsd() external view returns (uint256);

    function tokenValueUsd(
        address asset,
        uint256 amount
    ) external view returns (uint256);

    function calculateSharesToMint(
        uint256 _depositValueUsd,
        uint256 _vaultValueBefore
    ) external view returns (uint256 shares);

    function calculateDeposit(
        address[] calldata _assets,
        uint256[] calldata _amounts
    ) external view returns (uint256 shares);

    function calculateWithdraw(
        uint256 _shares
    )
        external
        view
        returns (
            address[] memory assetsArr,
            uint256[] memory amountsArr,
            uint256 withdrawUsdValue
        );

    // function addAssets(
    //     address[] calldata _newAssets,
    //     address[] calldata _priceFeeds
    // ) external;

    // function removeAssets(address[] calldata _assets) external;

    // function updatePriceFeed(address _asset, address _newPriceFeed) external;

    // function setAssetStatus(address _asset, bool _isActive) external;
}
