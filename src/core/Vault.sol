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
/// @notice Handles multiple assets (2-3) assets sent by a liquidity provider.

abstract contract Vault is ERC20 {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ERROR
    error Vault__InvalidAddress();

    //   Chainlink WETH/USD
    //   Chainlink USDC/USD (often ~1)

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

    event Deposit(
        address indexed user,
        uint256 sharesMinted,
        uint256 wethIn,
        uint256 usdcIn,
        uint256 valueUsd
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
    function _deposit(
        address _receiver,
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    ) internal returns (DepositDetails memory depositDetails) {
        uint256 len = _tokensAddresses.length;

        // check for zero length
        if (len == 0) revert("Empty assets");

        // check for amounts array length being equal to tokenAddresses length
        if (len != _amounts.length) revert("Length mismatch");

        // check whether the assets are more than allowed numbers
        if (len > supportedAssets.length())
            revert("Exceeds Maximum numbers of assets");

        if (_receiver == address(0)) revert Vault__InvalidAddress();

        uint256 vaultValueBeforeDeposit = totalVaultValueUsd();
        uint256 totalDepositValueUsd;

        for (uint256 i = 0; i < len; i++) {
            address asset = _tokensAddresses[i];
            // check if the token is supported or not
            if (!isActiveAsset(asset)) revert("Token Not Supported");

            uint256 amount = _amounts[i];
            if (amount == 0) continue;

            // compute deposit USD value (18-decimals)
            totalDepositValueUsd += _tokenValueUsd(asset, amount);

            // Transfer assets to this vault from the sender
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 vaultValueAfterDeposit = totalVaultValueUsd();

        uint256 sharesMinted;
        uint256 supply = totalSupply();
        if (supply == 0) {
            // shares and depositValueUsd both are 18-decimal units -> mint equal number of shares
            sharesMinted = totalDepositValueUsd;
            // sharesMinted = INITIAL_SUPPLY;
        } else {
            // sharesToMint = totalDepositValueUsd * totalSupply / vaultValueBefore
            sharesMinted =
                (totalDepositValueUsd * supply) /
                vaultValueBeforeDeposit;
        }
        require(
            (vaultValueAfterDeposit - vaultValueBeforeDeposit) ==
                totalDepositValueUsd
        );
        _mint(_receiver, sharesMinted);

        // emit

        depositDetails = DepositDetails({
            sharesMinted: sharesMinted,
            totalUsdAmount: totalDepositValueUsd
        });
    }

    // function _withdrawFor(address owner, uint256 _shares)   {}

    // if owner is not passed meaning called by a native user making msg.sender share holder else owner is specified through trusted periphery

    function _withdraw(
        address _owner,
        uint256 _shares,
        address _receiver
    ) internal returns (WithdrawDetails memory withdrawDetails) {
        address owner = _owner;

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
            if (_receiver != address(0)) {
                info.token.safeTransfer(_receiver, amt);
            } else {
                info.token.safeTransfer(owner, amt);
            }
        }
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
        //
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
            len != 0 && len != _amounts.length,
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
    )
        public
        view
        returns (
            address[] memory tokensArr,
            uint256[] memory amounts,
            uint256 withdrawUsdValue
        )
    {
        uint256 totalSharesBefore = totalSupply();
        uint256 n = supportedAssets.length();
        amounts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address token = supportedAssets.at(i);
            // TokenInfo storage info = assets[token];

            uint256 vaultBal = IERC20(token).balanceOf(address(this));
            uint256 amountOut = (vaultBal * _shares) / totalSharesBefore;
            if (_shares == totalSharesBefore) {
                amountOut = vaultBal; // last user gets all (remaining dust)
            } else {
                amountOut = Math.mulDiv(vaultBal, _shares, totalSharesBefore);
            }
            amounts[i] = amountOut;

            if (amountOut == 0) continue;

            withdrawUsdValue += _tokenValueUsd(token, amountOut);
        }

        tokensArr = supportedAssets.values();
    }

    /**
     * @notice Returns true if supported else returns false
     * @param _asset Address of tasset
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
     * @param _user Accepts user's address to check it's shares holding
     * @return _totalShares Total amount of shares of that user (ERC20 Balance)
     */
    function getAllShares(
        address _user
    ) public view returns (uint256 _totalShares) {
        _totalShares = balanceOf(_user);
    }

    /**
     * @notice returns total vault value in USD
     */
    function totalVaultValueUsd() public view returns (uint256 totalVaultVal) {
        for (uint16 i = 0; i < supportedAssets.length(); i++) {
            address token = supportedAssets.at(i);
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            uint256 tokenUsdBalance = _tokenValueUsd(token, tokenBalance);
            totalVaultVal += tokenUsdBalance;
        }
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
