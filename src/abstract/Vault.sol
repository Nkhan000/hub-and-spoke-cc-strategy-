// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IVault} from "../interfaces/IVault.sol";
import {VaultErrors} from "../libraries/errors/VaultErrors.sol";
import {VaultConstants} from "../libraries/constants/VaultConstants.sol";

/// @title A multi token vault
/// @author Nazir Khan
/// @notice Handles multiple assets sent by a liquidity provider.

abstract contract Vault is ERC20, IVault {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using Math for uint256;

    // STATE VARIABLES
    EnumerableSet.AddressSet private supportedAssets;
    mapping(address => TokenInfo) public assets;
    mapping(address => uint256) public lastWithdrawal;

    /// @notice Locked shares in pending withdrawals
    /// @dev lockedShares[chainSelector][userAddress] = lockedAmount
    mapping(uint64 => mapping(address => uint256)) public lockedShares;

    /// @notice Total shares in pending withdrawals
    uint256 public totalPendingShares;

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds
    ) ERC20("Vault Share", "vSHARE") {
        require(_tokens.length == _priceFeeds.length, "Length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            address feed = _priceFeeds[i];
            require(token != address(0) && feed != address(0), "Zero address");
            assets[token] = TokenInfo({
                token: IERC20(token),
                priceFeed: AggregatorV3Interface(feed),
                isActive: true
            });
            supportedAssets.add(token);
        }
    }

    function _latestPrice(
        AggregatorV3Interface feed
    ) internal view returns (uint256, uint8) {
        (, int256 answer, , , ) = feed.staleCheckLatestRoundData();
        if (answer == 0) revert("Vault__InvalidPrice");

        uint8 feedDecimals = feed.decimals();
        uint256 price = uint256(answer);
        return (price, feedDecimals);
    }

    function _tokenValueUsd(
        address asset,
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;
        TokenInfo memory info = assets[asset];
        (uint256 price, uint8 feedDecimals) = _latestPrice(info.priceFeed); // price with feedDecimals
        uint8 tokenDecimals = ERC20(address(asset)).decimals();

        // amount * price
        // normalize: (amount / 10**tokenDecimals) * (price / 10**feedDecimals)
        // to keep 18 decimals: amount * price * (10**18) / (10**tokenDecimals) / (10**feedDecimals)
        // return (amount * price * 1e18) / (10 ** (tokenDecimals + feedDecimals));

        uint256 value = (amount * price) / (10 ** feedDecimals);
        return (value * 1e18) / (10 ** tokenDecimals);

        // So:

        // 1 USDC (1e6) × $1 (1e8) →
        // (1e6 * 1e8 * 1e18)/(1e6*1e8)=1e18 → $1 * 1e18 units.

        // 1 WETH (1e18) × $2000 (2 000 000 000 00) →
        // (1e18 * 2e11 * 1e18)/(1e18 * 1e8)=2e21 → $2000 * 1e18 units.
    }

    // @ TODO : ADD REENTRANCY GUARD IS NEEDED OR NOT ?

    function _deposit(
        address _receiver,
        address[] memory _assets,
        uint256[] memory _amounts
    ) internal returns (DepositDetails memory depositDetails) {
        if (_receiver == address(0)) revert VaultErrors.Vault__InvalidAddress();
        if (_assets.length != _amounts.length) revert("Length Mismatched");

        uint256 vaultValueBefore = _totalVaultValueUsd();
        uint256 totalDepositValueUsd;
        (
            address[] memory filteredAssets,
            uint256[] memory filteredAmounts
        ) = _filterSupportedTokens(_assets, _amounts);

        uint256 len = filteredAssets.length;

        for (uint256 i = 0; i < len; ) {
            address asset = filteredAssets[i];
            uint256 amount = filteredAmounts[i];

            // compute deposit USD value (18-decimals)
            totalDepositValueUsd += _tokenValueUsd(asset, amount);

            // Transfer assets to this vault from the sender
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

            unchecked {
                ++i;
            }
        }

        uint256 vaultValueAfter = _totalVaultValueUsd();
        uint256 actualIncrease = vaultValueAfter - vaultValueBefore;

        // checks if the actual increase is not less than 1% from original deposit
        // 10 (actual increase) > (10 (deposit) * 9900) / 10000
        if (
            actualIncrease <
            (totalDepositValueUsd * VaultConstants.DEPOSIT_TOLERANCE_BPS) /
                10000
        ) {
            revert VaultErrors.Vault__DepositValueMismatch(
                totalDepositValueUsd,
                actualIncrease
            );
        }

        if (totalDepositValueUsd < VaultConstants.MIN_DEPOSIT_USD)
            revert("Minimum deposit should be provided");

        uint256 shares = _calculateSharesToMint(
            totalDepositValueUsd,
            vaultValueBefore
        );
        _mint(_receiver, shares);

        depositDetails = DepositDetails({
            sharesMinted: shares,
            totalUsdAmount: totalDepositValueUsd
        });

        // ✅ Emit event
        emit Deposited(
            _receiver,
            shares,
            filteredAssets,
            filteredAmounts,
            totalDepositValueUsd
        );
    }

    function _withdraw(
        address _owner,
        uint256 _shares,
        address _receiver
    ) internal returns (WithdrawDetails memory withdrawDetails) {
        address owner = _owner;
        if (_owner == address(0)) revert VaultErrors.Vault__InvalidAddress();

        require(
            _shares > 0 && _shares <= balanceOf(owner),
            "Invalid/No shares"
        );
        require(
            block.timestamp >=
                lastWithdrawal[owner] + VaultConstants.WITHDRAWAL_COOLDOWN,
            "Cooldown is active"
        );
        // @audit
        address receiver = _receiver == address(0) ? msg.sender : _receiver;

        lastWithdrawal[owner] = block.timestamp;
        (
            address[] memory tokens,
            uint256[] memory amounts,
            uint256 withdrawValueUsd
        ) = _calculateWithdraw(_shares);

        _burn(owner, _shares);

        // 3) ex ternal transfers (do them after internal changes and after all amounts computed)
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ) {
            uint256 amt = amounts[i];
            if (amt > 0) {
                address token = tokens[i];
                TokenInfo storage info = assets[token];

                // defensive check to avoid underflow in token mock implementations
                require(
                    info.token.balanceOf(address(this)) >= amt,
                    "Insufficient token balance"
                );

                info.token.safeTransfer(receiver, amt);
            }

            unchecked {
                ++i;
            }
        }

        withdrawDetails = WithdrawDetails({
            tokensWithdrawn: tokens,
            amountsWithdrawn: amounts,
            withdrawValueUsd: withdrawValueUsd,
            sharesBurnt: _shares
        });
        // emit
    }

    function _filterSupportedTokens(
        address[] memory _assets,
        uint256[] memory _amounts
    ) internal view returns (address[] memory, uint256[] memory) {
        uint256 len = _assets.length;

        // if len is greater than maximum number of tokens allowed. Example if Max number of tokens allowed are five than only five different tokens can be sent, making length only be below or equal to MAX_ALLOWED_TOKENS
        uint256 maxTokens = supportedAssets.length(); // may be we can do something with the max length ...W
        if (len > maxTokens) revert("Invalid lenght");

        // intially setting the size of the filtered array to maximum tokens possible
        address[] memory filteredAssets = new address[](maxTokens);
        uint256[] memory filteredAmounts = new uint256[](maxTokens);

        uint256 uniqueCount; // 0 (for final length of array)

        for (uint256 i = 0; i < len; ) {
            address asset = _assets[i];
            uint256 amount = _amounts[i];
            // Skip zero amounts and validate support (defense in depth)
            if (amount == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            TokenInfo memory info = assets[asset];
            if (address(info.token) == address(0)) {
                revert("Vault__AssetNotSupported(asset)");
            }
            if (!info.isActive) {
                revert("Vault__AssetNotActive(token)");
            }
            bool found;
            for (uint256 j = 0; j < uniqueCount; ) {
                if (filteredAssets[j] == asset) {
                    filteredAmounts[j] += amount;
                    found = true;
                    break;
                }

                unchecked {
                    ++j;
                }
            }
            if (!found) {
                filteredAssets[uniqueCount] = asset;
                filteredAmounts[uniqueCount] = amount;
                unchecked {
                    ++uniqueCount;
                }
            }

            // fixed here increamenting always
            unchecked {
                ++i;
            }
        }

        if (uniqueCount == 0) {
            revert VaultErrors.Vault__NoValidDeposits();
        }
        assembly {
            mstore(filteredAssets, uniqueCount) // RESIZE ARRAY
            mstore(filteredAmounts, uniqueCount) // RESIZE ARRAY
        }

        return (filteredAssets, filteredAmounts);
    }

    // =================================================
    // ASSETS MANAGEMENT
    // =================================================

    function _addAssets(
        address[] calldata _newAssets,
        address[] calldata _priceFeeds
    ) internal {
        require(_newAssets.length == _priceFeeds.length, "Length Mismatched");

        for (uint256 i = 0; i < _newAssets.length; i++) {
            address asset = _newAssets[i];
            address feed = _priceFeeds[i];
            _addAsset(asset, feed);
        }
    }

    function _removeAssets(address[] calldata _assets) internal {
        require(_assets.length > 0, "Invalid Length");

        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            _removeAsset(asset);
        }
    }

    /// @notice Add a whitelisted asset.
    function _addAsset(address _newAsset, address _priceFeed) internal {
        require(
            _newAsset != address(0) && _priceFeed != address(0),
            "Invalid Address for new asset or Price Feed address"
        );
        require(
            supportedAssets.length() < VaultConstants.MAX_ALLOWED_TOKENS,
            "MAX NUMBER OF TOKENS REACHED"
        );

        require(
            address(assets[_newAsset].token) == address(0),
            "Asset already exists"
        );

        // verify pricefeed works
        isValidPriceFeed(_priceFeed);

        assets[_newAsset] = TokenInfo({
            token: IERC20(_newAsset),
            priceFeed: AggregatorV3Interface(_priceFeed),
            // add a decimal as well ??
            isActive: true
        });
        supportedAssets.add(_newAsset);

        emit NewAssetAdded(_newAsset, _priceFeed);
    }

    /// @notice Remove a whitelisted asset.
    function _removeAsset(address _asset) internal {
        // checks if the given asset is a valid address
        require(
            address(assets[_asset].token) != address(0),
            "Asset Does not exist"
        );

        // checks if the given asset has some amount before removing
        require(
            IERC20(_asset).balanceOf(address(this)) < 1e6,
            "Funds are still in the vault"
        );

        delete assets[_asset];
        bool success = supportedAssets.remove(_asset);
        require(success, "Address not found in the set");

        emit AssetRemoved(_asset);
    }

    function _updatePriceFeed(address _asset, address _newPriceFeed) internal {
        // checks if the given asset is a valid address
        require(
            address(assets[_asset].token) != address(0),
            "Invalid asset address"
        );
        // verify pricefeed works
        AggregatorV3Interface feed = AggregatorV3Interface(_newPriceFeed);
        (, int256 price, , , ) = OracleLib.staleCheckLatestRoundData(feed);
        if (price == 0) revert("Vault__InvalidPrice(_token)");
        assets[_asset].priceFeed = AggregatorV3Interface(_newPriceFeed);

        emit PriceFeedUpdated(_asset, _newPriceFeed);
    }

    function _setAssetStatus(address _asset, bool _isActive) internal {
        TokenInfo storage asset = assets[_asset];
        require(address(asset.token) != address(0), "Invalid Asset Address");

        asset.isActive = _isActive;
        emit AssetStatusUpdated(address(asset.token), _isActive);
    }

    function _calculateSharesToMint(
        uint256 _depositValueUsd,
        uint256 _vaultValueBefore
    ) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            // First deposit - mint 1:1 with USD value
            shares = _depositValueUsd;
        } else {
            // Proportional minting
            // shares = depositValue * totalSupply / vaultValue
            shares = _depositValueUsd.mulDiv(supply, _vaultValueBefore);
        }
    }

    function _calculateDeposit(
        address[] calldata _assets,
        uint256[] calldata _amounts
    ) internal view returns (uint256 shares) {
        uint256 len = _assets.length;

        require(
            len != 0 && len == _amounts.length,
            "Invalid length of assets and ammount"
        );

        uint256 vaultValueBefore = _totalVaultValueUsd();
        uint256 totalDepositValueUsd;

        for (uint256 i = 0; i < len; ) {
            address asset = _assets[i];
            // check if the token is supported or not
            if (!_isActiveAsset(asset)) revert("asset Not Supported");

            uint256 amount = _amounts[i];
            if (amount == 0) continue;

            // compute deposit USD value (18-decimals)
            totalDepositValueUsd += _tokenValueUsd(asset, amount);
            unchecked {
                ++i;
            }
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            // shares and depositValueUsd both are 18-decimal units -> mint equal number of shares
            shares = totalDepositValueUsd;
            // shares = INITIAL_SUPPLY;
        } else {
            // sharesToMint = totalDepositValueUsd * totalSupply / vaultValueBefore
            shares = (totalDepositValueUsd * supply) / vaultValueBefore;
        }
    }

    /**
     * @notice Getter for getting assets and price for amount of shares to be burnt
     * @param _shares Amount of shares to be burnt
     * @return assetsArr An array of assets that will sent based current balance of assets of the vault
     * @return amountsArr Amount array for each assets
     * @return withdrawUsdValue Total USD amount of the assets
     */
    function _calculateWithdraw(
        uint256 _shares
    )
        internal
        view
        returns (
            address[] memory assetsArr,
            uint256[] memory amountsArr,
            uint256 withdrawUsdValue
        )
    {
        uint256 totalSupply = totalSupply();
        uint256 n = supportedAssets.length();

        assetsArr = new address[](n);
        amountsArr = new uint256[](n);

        for (uint256 i = 0; i < n; ) {
            address asset = supportedAssets.at(i);
            uint256 vaultBal = IERC20(asset).balanceOf(address(this)); // vault balance of token

            uint256 amountOut;
            if (_shares == totalSupply) {
                amountOut = vaultBal; // last user gets all (remaining dust)
            } else {
                amountOut = Math.mulDiv(vaultBal, _shares, totalSupply);
            }
            assetsArr[i] = asset;
            amountsArr[i] = amountOut;
            if (amountOut > 0) {
                withdrawUsdValue += _tokenValueUsd(asset, amountOut);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _lockShares(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal {
        // lock shares
        lockedShares[_destChain][_owner] += _shares;
        totalPendingShares += _shares;
    }

    function _unlockShares(
        address _owner,
        uint256 _shares,
        uint64 _destChain
    ) internal {
        // unlock shares
        lockedShares[_destChain][_owner] -= _shares;
        totalPendingShares -= _shares;
    }

    /**
     * @notice Total vault value in USD (counts token in the protocol)
     */

    function _totalVaultValueUsd() internal view returns (uint256) {
        uint256 totalVaultVal = _getIdleFundsUsd() + getStrategyFunds();
        return totalVaultVal;
    }

    function _getIdleFundsUsd() internal view returns (uint256) {
        uint256 totalVaultVal;
        uint256 len = supportedAssets.length();
        for (uint16 i = 0; i < len; i++) {
            address token = supportedAssets.at(i);
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance > 0) {
                uint256 tokenUsdBalance = _tokenValueUsd(token, tokenBalance);
                totalVaultVal += tokenUsdBalance;
            }
        }
        return totalVaultVal;
    }

    function getStrategyFunds() public pure returns (uint256) {
        // for now lets return 0;
        return 0;
    }

    /**
     * @notice returns value of price per share
     */
    function _pricePerShare() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return Math.mulDiv(_totalVaultValueUsd(), 1e18, supply);
    }

    function _shareValueUsd(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        return Math.mulDiv(shares, _pricePerShare(), 1e18);

        /**
        pricePerShare = 1e18 (meaning $1.00 per share)
        shares = 100e18 (100 shares)
        sharePrice = 1e18 * 100e18 = 100e36  ← WRONG! Should be 100e18 ($100) that's divided by 1e18 to prevent the overflow
         */
    }

    /**
     *
     * @param _user Accepts user's address to check it's shares holding
     * @return totalAmtUsd Total amount of shares in USD of that user
     */
    function _getAllUserSharesValueUsd(
        address _user
    ) internal view returns (uint256 totalAmtUsd) {
        uint256 sharesOfUser = balanceOf(_user);
        uint256 totalSharesMinted = totalSupply();
        if (totalSharesMinted == 0 || sharesOfUser == 0) return 0;

        for (uint16 i = 0; i < supportedAssets.length(); i++) {
            address token = supportedAssets.at(i);
            uint256 totalTokenInVault = IERC20(token).balanceOf(address(this));

            // proportional amount burning
            uint256 amountOut = (totalTokenInVault * sharesOfUser) /
                totalSharesMinted;
            if (amountOut == 0) continue;

            totalAmtUsd += _tokenValueUsd(token, amountOut);
        }
    }

    function _isActiveAsset(address _asset) internal view returns (bool) {
        return assets[_asset].isActive;
    }

    function isValidPriceFeed(address priceFeed) public view returns (bool) {
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        (, int256 price, , , ) = OracleLib.staleCheckLatestRoundData(feed);
        return price == 0 ? false : true;
    }

    // EXTERNAL GETTERS

    function tokenValueUsd(
        address asset,
        uint256 amount
    ) external view returns (uint256) {
        return _tokenValueUsd(asset, amount);
    }

    function calculateSharesToMint(
        uint256 _depositValueUsd,
        uint256 _vaultValueBefore
    ) external view returns (uint256 shares) {
        return _calculateSharesToMint(_depositValueUsd, _vaultValueBefore);
    }

    function calculateDeposit(
        address[] calldata _assets,
        uint256[] calldata _amounts
    ) external view returns (uint256 shares) {
        return _calculateDeposit(_assets, _amounts);
    }

    function calculateWithdraw(
        uint256 _shares
    )
        external
        view
        returns (
            address[] memory assetsArr,
            uint256[] memory amountsArr,
            uint256 withdrawUsdValue
        )
    {
        return _calculateWithdraw(_shares);
    }

    /**
     * @notice returns an array of all the supported assets
     */
    function getSupportedAssets()
        external
        view
        returns (address[] memory tokensAddresses)
    {
        return supportedAssets.values();
    }

    function totalVaultValueUsd() external view returns (uint256) {
        return _totalVaultValueUsd();
    }

    function getIdleFundsUsd() external view override returns (uint256) {
        return _getIdleFundsUsd();
    }

    function pricePerShare() external view returns (uint256) {
        return _pricePerShare();
    }

    function shareValueUsd(
        uint256 shares
    ) external view override returns (uint256) {
        return _shareValueUsd(shares);
    }

    function isActiveAsset(address _asset) external view returns (bool) {
        return _isActiveAsset(_asset);
    }
}
