// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title A multi token vault
/// @author Nazir Khan
/// @notice Handles multiple assets sent by a liquidity provider.

abstract contract Vault is ERC20 {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ERROR
    error Vault__InvalidAddress();
    error Vault__NoValidDeposits();

    uint256 public constant MAX_ALLOWED_TOKENS = 4;
    uint256 public constant INITIAL_SUPPLY = 100e18;
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 hours;
    mapping(address => TokenInfo) public assets;
    mapping(address => uint256) public lastWithdrawal;

    EnumerableSet.AddressSet private supportedAssets;

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
        address[] tokensReceived;
        uint256[] amountsReceived;
        uint256 withdrawValueInUsd;
    }

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

    // function mint(
    //         uint256 shares,
    //         address receiver
    //     )

    //       function withdraw(
    //         uint256 assets,
    //         address receiver,
    //         address owner
    //     )

    //     function redeem(
    //         uint256 shares,
    //         address receiver,
    //         address owner
    //     )

    // ===============================
    // EXTERNAL FUNCTIONS
    // ===============================
    function deposit(
        address receiver,
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    ) public virtual returns (DepositDetails memory) {
        return _deposit(receiver, _tokensAddresses, _amounts);
    }

    function withdraw(
        address owner,
        uint256 _shares
    ) public virtual returns (WithdrawDetails memory) {
        return _withdraw(owner, _shares, address(0));
    }

    function tokenValueUsd(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        return _tokenValueUsd(token, amount);
    }

    // ===============================
    // INTERNAL FUNCTIONS
    // ===============================

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

    function _filterSupportedTokens(
        address[] memory _assets,
        uint256[] memory _amounts
    ) internal view returns (address[] memory, uint256[] memory) {
        uint256 len = _assets.length;

        // if len is greater than maximum number of tokens allowed. Example if Max number of tokens allowed are five than only five different tokens can be sent, making length only be below or equal to MAX_ALLOWED_TOKENS
        uint256 maxTokens = supportedAssets.length(); // may be we can do something with the max length ...W
        if (len != _amounts.length || len > maxTokens || len == 0)
            revert("Invalid lenght");

        // intially setting the size of the filtered array to maximum tokens possible
        address[] memory filteredAssets = new address[](maxTokens);
        uint256[] memory filteredAmounts = new uint256[](maxTokens);

        uint256 uniqueCount; // 0 (for final length of array)

        for (uint256 i = 0; i < len; ) {
            address asset = _assets[i];
            uint256 amount = _amounts[i];

            // Revert if unsupported (should never happen if periphery is correct) - Maybe add it later !
            // if (!isActiveAsset(asset)) {
            //     revert Vault__TokenNotSupported(asset);
            // }

            // Skip zero amounts and validate support (defense in depth)
            if (amount != 0) {
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
            }
            // fixed here increamenting always
            unchecked {
                ++i;
            }
        }

        assembly {
            mstore(filteredAssets, uniqueCount)
            mstore(filteredAmounts, uniqueCount)
        }

        if (uniqueCount == 0) {
            revert Vault__NoValidDeposits();
        }
        return (filteredAssets, filteredAmounts);
    }

    function _deposit(
        address _receiver,
        address[] memory _assets,
        uint256[] memory _amounts
    ) internal returns (DepositDetails memory depositDetails) {
        if (_receiver == address(0)) revert Vault__InvalidAddress();

        uint256 vaultValueBeforeDeposit = totalVaultValueUsd();
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

        uint256 vaultValueAfterDeposit = totalVaultValueUsd();

        uint256 sharesMinted;
        uint256 supply = totalSupply();
        if (supply == 0) {
            // shares and depositValueUsd both are 18-decimal units -> mint equal number of shares
            sharesMinted = totalDepositValueUsd;
            // sharesMinted = INITIAL_SUPPLY; // or mint fixed amount of shares as in initial supply
        } else {
            // sharesToMint = totalDepositValueUsd * totalSupply / vaultValueBefore
            sharesMinted =
                (totalDepositValueUsd * supply) /
                vaultValueBeforeDeposit;
        }

        //  tolerance check
        uint256 actualIncrease = vaultValueAfterDeposit -
            vaultValueBeforeDeposit;
        // checks if the actual increase is not less than 1% from original deposit
        require(
            actualIncrease >= (totalDepositValueUsd * 99) / 100,
            "Value mismatch"
        );

        _mint(_receiver, sharesMinted);

        // ✅ Emit event
        emit Deposited(
            _receiver,
            sharesMinted,
            filteredAssets,
            filteredAmounts,
            totalDepositValueUsd
        );

        depositDetails = DepositDetails({
            sharesMinted: sharesMinted,
            totalUsdAmount: totalDepositValueUsd
        });
    }

    function _withdraw(
        address _owner,
        uint256 _shares,
        address _receiver
    ) internal returns (WithdrawDetails memory withdrawDetails) {
        address owner = _owner;
        if (_owner == address(0)) revert Vault__InvalidAddress();

        require(
            _shares > 0 && _shares <= balanceOf(owner),
            "Invalid/No shares"
        );
        require(
            block.timestamp >= lastWithdrawal[owner] + WITHDRAWAL_COOLDOWN,
            "Cooldown is active"
        );
        lastWithdrawal[owner] = block.timestamp;

        (
            ,
            uint256[] memory amounts,
            uint256 withdrawUsdValue
        ) = previewWithdraw(_shares);

        _burn(owner, _shares);

        // 3) external transfers (do them after internal changes and after all amounts computed)
        uint256 n = supportedAssets.length();
        for (uint256 i = 0; i < n; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            address asset = supportedAssets.at(i);
            TokenInfo storage info = assets[asset];

            // defensive check to avoid underflow in token mock implementations
            require(
                info.token.balanceOf(address(this)) >= amt,
                "Insufficient token balance"
            );
            address receiver = _receiver == address(0) ? owner : _receiver;
            info.token.safeTransfer(receiver, amt);
        }
        // emit

        withdrawDetails = WithdrawDetails({
            tokensReceived: supportedAssets.values(),
            amountsReceived: amounts,
            withdrawValueInUsd: withdrawUsdValue
        });
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
            supportedAssets.length() < MAX_ALLOWED_TOKENS,
            "MAX NUMBER OF TOKENS REACHED"
        );

        require(
            address(assets[_newAsset].token) == address(0),
            "Asset already exists"
        );

        assets[_newAsset] = TokenInfo({
            token: IERC20(_newAsset),
            priceFeed: AggregatorV3Interface(_priceFeed),
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

        require(assets[_asset].isActive, "Invalid Asset");
        assets[_asset].priceFeed = AggregatorV3Interface(_newPriceFeed);

        emit PriceFeedUpdated(_asset, _newPriceFeed);
    }

    function _disableAsset(address _asset) internal {
        TokenInfo storage asset = assets[_asset];
        require(address(asset.token) != address(0), "Invalid asset address");

        asset.isActive = false;
        emit AssetDisabled(address(asset.token));
    }

    function _enableAsset(address _asset) internal {
        TokenInfo storage asset = assets[_asset];
        require(address(asset.token) != address(0), "Invalid asset address"); // ?

        asset.isActive = true;
        emit AssetEnabled(address(asset.token));
    }

    // ===========================
    // GETTERS
    // ===========================

    function previewDeposit(
        address[] calldata _assets,
        uint256[] calldata _amounts
    ) public view returns (uint256 shares) {
        uint256 len = _assets.length;

        require(
            len != 0 && len == _amounts.length,
            "Invalid length of assets and ammount"
        );

        uint256 vaultValueBeforeDeposit = totalVaultValueUsd();
        uint256 totalDepositValueUsd;

        for (uint256 i = 0; i < len; i++) {
            address asset = _assets[i];
            // check if the token is supported or not
            if (!isActiveAsset(asset)) revert("asset Not Supported");

            uint256 amount = _amounts[i];
            if (amount == 0) continue;

            // compute deposit USD value (18-decimals)
            totalDepositValueUsd += _tokenValueUsd(asset, amount);
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            // shares and depositValueUsd both are 18-decimal units -> mint equal number of shares
            shares = totalDepositValueUsd;
            // shares = INITIAL_SUPPLY;
        } else {
            // sharesToMint = totalDepositValueUsd * totalSupply / vaultValueBefore
            shares = (totalDepositValueUsd * supply) / vaultValueBeforeDeposit;
        }
    }

    /**
     * @notice Getter for getting assets and price for amount of shares to be burnt
     * @param _shares Amount of shares to be burnt
     * @return tokensArr An array of assets that will sent based current balance of assets of the vault
     * @return amounts Amount array for each assets
     * @return withdrawUsdValue Total USD amount of the assets
     */
    function previewWithdraw(
        uint256 _shares
    ) public view returns (address[] memory, uint256[] memory, uint256) {
        uint256 totalSharesBefore = totalSupply();
        uint256 n = supportedAssets.length();
        uint256[] memory amounts = new uint256[](n);
        uint256 withdrawUsdValue;

        for (uint256 i = 0; i < n; i++) {
            uint256 amountOut;
            address asset = supportedAssets.at(i);

            uint256 vaultBal = IERC20(asset).balanceOf(address(this));

            if (_shares == totalSharesBefore) {
                amountOut = vaultBal; // last user gets all (remaining dust)
            } else {
                amountOut = Math.mulDiv(vaultBal, _shares, totalSharesBefore);
            }
            amounts[i] = amountOut;
            withdrawUsdValue += _tokenValueUsd(asset, amountOut);
        }

        address[] memory tokensArr = supportedAssets.values();

        return (tokensArr, amounts, withdrawUsdValue);
    }

    /**
     * @notice Returns true if supported/active else returns false. As if it is either not supported or not active `.isActive` will return false
     * @param _asset Address of asset
     */
    function isActiveAsset(address _asset) public view returns (bool) {
        return assets[_asset].isActive;
    }

    /**
     * @notice returns an array of all the supported assets
     */
    function getSupportedAssets()
        public
        view
        returns (address[] memory tokensAddresses)
    {
        tokensAddresses = supportedAssets.values();
    }

    /**
     *
     * @param account Accepts user's address to check it's shares holding
     * @return Total amount of shares of that user (ERC20 Balance)
     */
    function getAllShares(address account) public view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @notice Total vault value in USD
     */
    function totalVaultValueUsd() public view returns (uint256) {
        uint256 totalVaultVal;
        for (uint16 i = 0; i < supportedAssets.length(); i++) {
            address token = supportedAssets.at(i);
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            uint256 tokenUsdBalance = _tokenValueUsd(token, tokenBalance);
            totalVaultVal += tokenUsdBalance;
        }
        return totalVaultVal;
    }

    /**
     * @notice returns value of price per share
     */
    function pricePerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (totalVaultValueUsd() * (10 ** 18)) / supply; // returns USD-per-share scaled by 1e18
    }

    /**
     *
     * @param _user Accepts user's address to check it's shares holding
     * @return totalAmtUsd Total amount of shares in USD of that user
     */
    function getAllUserSharesValueUsd(
        address _user
    ) public view returns (uint256 totalAmtUsd) {
        uint256 sharesOfUser = getAllShares(_user);
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
}

// uint256 wethBal = weth.balanceOf(address(this)); // e.g. 5 * 1e18
// uint256 usdcBal = usdc.balanceOf(address(this)); // e.g. 10_000 * 1e6
// return
//     _tokenValueUsd(weth, wethUsdFeed, wethBal) +
//     _tokenValueUsd(usdc, usdcUsdFeed, usdcBal);

// function _deposit(uint256 _amount) internal {
//     /**
//      * a = amount to deposit
//      * B = Balance of Token Before Deposit
//      * T = Total Supply
//      * s = shares to mint
//      *
//      *
//      * (T+S) / T  = (a + B) / B
//      *
//      * s = aT/B
//      */

//     uint256 shares;
//     if (totalSupply == 0) {
//         shares = _amount;
//     } else {
//         shares = (_amount * totalSupply) / weth.balanceOf(address(this));
//     }

//     _mint(msg.sender, shares);
//     weth.transferFrom(msg.sender, address(this), _amount);
// }

// function withdraw(uint256 _shares) external {
//     /**
//      * a = amount to deposit
//      * B = Balance of Token Before Withdraw
//      * T = Total Supply
//      * s = shares to burn
//      *
//      *
//      * (T-s) / T  = (B-a) / B
//      *
//      * a = sB/T
//      */

//     uint256 amount = ((_shares * weth.balanceOf(address(this))) /
//         totalSupply);

//     _burn(msg.sender, _shares);
// }

// assets are in proportion
// copied/adapted from Uniswap V3 FullMath (returns floor(a*b/denominator)).
// Keeps intermediate 512-bit product so no overflow.
/* function _mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // least significant 256 bits
            uint256 prod1; // most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return prod0 / denominator;
            }

            require(denominator > prod1, "mulDiv overflow");

            // Make division exact by subtracting remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            // Compute modular inverse of denominator
            uint256 inv = (3 * denominator) ^ 2;
            inv = inv * (2 - denominator * inv);
            inv = inv * (2 - denominator * inv);
            inv = inv * (2 - denominator * inv);
            inv = inv * (2 - denominator * inv);
            inv = inv * (2 - denominator * inv);
            inv = inv * (2 - denominator * inv);

            result = prod0 * inv;
            return result;
        }
    }

    // --- safe token -> USD valuation using mulDiv to avoid overflow ---
    function _tokenValueUsd(
        IERC20 token,
        AggregatorV3Interface feed,
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;

        (uint256 price, uint8 feedDecimals) = _latestPrice(feed);
        uint8 tokenDecimals = ERC20(address(token)).decimals();

        // value = amount * price / (10**feedDecimals)
        uint256 interim = _mulDiv(amount, price, 10 ** feedDecimals);

        // scale to 1e18 units: (interim * 1e18) / (10**tokenDecimals)
        return _mulDiv(interim, 1e18, 10 ** tokenDecimals);
    }*/
