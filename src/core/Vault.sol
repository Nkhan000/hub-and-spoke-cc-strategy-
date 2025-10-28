// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

/// @title A multi token vault
/// @author Nazir Khan
/// @notice Handles multiple tokens (2-3) tokens sent by a liquidity provider.
/// @dev

// interface AggregatorV3Interface {
//     function latestRoundData()
//         external
//         view
//         returns (
//             uint80 roundId,
//             int256 answer,
//             uint256 startedAt,
//             uint256 updatedAt,
//             uint80 answeredInRound
//         );

//     function decimals() external view returns (uint8);
// }

abstract contract Vault is ERC20 {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;

    //   Chainlink WETH/USD
    //   Chainlink USDC/USD (often ~1)

    uint256 public constant MAX_ALLOWED_TOKENS = 4;
    mapping(address => TokenInfo) public tokens;

    EnumerableSet.AddressSet private supportedTokens;
    mapping(address => mapping(address => uint256)) public userTokens;

    struct TokenInfo {
        IERC20 token;
        AggregatorV3Interface priceFeed;
        bool supported;
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

    constructor(
        address[] memory _tokens,
        address[] memory _priceFeeds
    ) ERC20("Vault Share", "vSHARE") {
        require(_tokens.length == _priceFeeds.length, "Length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            address feed = _priceFeeds[i];
            require(token != address(0) && feed != address(0), "Zero address");
            tokens[token] = TokenInfo({
                token: IERC20(token),
                priceFeed: AggregatorV3Interface(feed),
                supported: true
            });
            supportedTokens.add(token);
        }
    }

    function totalVaultValueUsd() public view returns (uint256) {
        // uint256 wethBal = weth.balanceOf(address(this)); // e.g. 5 * 1e18
        // uint256 usdcBal = usdc.balanceOf(address(this)); // e.g. 10_000 * 1e6
        // return
        //     _tokenValueUsd(weth, wethUsdFeed, wethBal) +
        //     _tokenValueUsd(usdc, usdcUsdFeed, usdcBal);

        uint256 totalVaultVal;

        for (uint16 i = 0; i < supportedTokens.length(); i++) {
            address token = supportedTokens.at(i);
            TokenInfo storage info = tokens[token];
            uint256 tokenBalance = info.token.balanceOf(address(this));
            uint256 tokenUsdBalance = _tokenValueUsd(
                IERC20(token),
                info.priceFeed,
                tokenBalance
            );
            totalVaultVal += tokenUsdBalance;
        }

        return totalVaultVal;
    }

    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (totalVaultValueUsd() * (10 ** 18)) / supply; // returns USD-per-share scaled by 1e18
    }

    //===============================
    // EXTERNAL FUNCTIONS
    //===============================
    function deposit(
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    ) public virtual returns (uint256, uint256) {
        return _deposit(_tokensAddresses, _amounts);
    }

    function withdraw(
        uint256 _shares
    ) public virtual returns (uint256 withdrawValueInUsd) {
        withdrawValueInUsd = _withdraw(_shares);
    }

    function tokenValueUsd(
        IERC20 token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface feed = tokens[address(token)].priceFeed;
        return _tokenValueUsd(token, feed, amount);
    }

    //===============================
    // INTERNAL FUNCTIONS
    //===============================

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
        IERC20 token,
        AggregatorV3Interface feed,
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;

        (uint256 price, uint8 feedDecimals) = _latestPrice(feed); // price with feedDecimals
        uint8 tokenDecimals = ERC20(address(token)).decimals();

        // amount * price
        // normalize: (amount / 10**tokenDecimals) * (price / 10**feedDecimals)
        // to keep 18 decimals: amount * price * (10**18) / (10**tokenDecimals) / (10**feedDecimals)
        return
            (amount * price * (10 ** 18)) /
            (10 ** tokenDecimals) /
            (10 ** feedDecimals);

        // So:

        // 1 USDC (1e6) × $1 (1e8) →
        // (1e6 * 1e8 * 1e18)/(1e6*1e8)=1e18 → $1 * 1e18 units.

        // 1 WETH (1e18) × $2000 (2 000 000 000 00) →
        // (1e18 * 2e11 * 1e18)/(1e18 * 1e8)=2e21 → $2000 * 1e18 units.
    }

    // @ TODO : ADD REENTRANCY GUARD IS NEEDED OR NOT ?
    function _deposit(
        address[] memory _tokensAddresses,
        uint256[] memory _amounts
    ) internal returns (uint256, uint256) {
        require(_tokensAddresses.length == _amounts.length, "Length mismatch");
        require(
            _tokensAddresses.length < MAX_ALLOWED_TOKENS,
            "Exceeds Maximum numbers of tokens"
        );

        uint256 supply = totalSupply();
        uint256 vaultValueBeforeDeposit = totalVaultValueUsd();

        uint256 totalDepositValueUsd;

        for (uint256 i = 0; i < _tokensAddresses.length; i++) {
            address tokenAddr = _tokensAddresses[i];
            uint256 amount = _amounts[i];
            if (amount == 0) continue;

            // check if the token is supported or not
            require(isSupported(tokenAddr), "Token Not Supported");

            TokenInfo storage s = tokens[tokenAddr];
            // Transfer tokens to this vault from the sender
            s.token.safeTransferFrom(msg.sender, address(this), amount);

            // updating deposited tokens
            userTokens[msg.sender][tokenAddr] += amount;

            // compute deposit USD value (18-decimals)
            totalDepositValueUsd += _tokenValueUsd(
                s.token,
                s.priceFeed,
                amount
            );
        }

        uint256 vaultValueAfterDeposit = totalVaultValueUsd();

        uint256 sharesMinted;
        if (supply == 0) {
            // shares and depositValueUsd both are 18-decimal units -> mint equal number of shares
            sharesMinted = totalDepositValueUsd;
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
        _mint(msg.sender, sharesMinted);
        // emit
        return (sharesMinted, totalDepositValueUsd);
    }

    function _withdraw(uint256 _shares) internal returns (uint256) {
        require(
            _shares > 0 && _shares <= balanceOf(msg.sender),
            "Invalid shares"
        );

        uint256 supply = totalSupply();
        if (supply == 0) revert("No shares to burn");
        uint256 vaultValaueBeforeWithdraw = totalVaultValueUsd();

        _burn(msg.sender, _shares);

        uint256 withdrawUsdValue;

        for (uint16 i = 0; i < supportedTokens.length(); i++) {
            address tokenAddr = supportedTokens.at(i);
            TokenInfo storage info = tokens[tokenAddr];
            uint256 vaultBal = info.token.balanceOf(address(this));

            // proportional amount burning
            uint256 amountOut = (vaultBal * _shares) / supply;
            if (amountOut == 0) continue;

            uint256 userBalOfToken = userTokens[msg.sender][tokenAddr];

            if (userBalOfToken < amountOut) {
                amountOut = userBalOfToken; // Prevent over-withdraw
            }

            withdrawUsdValue += _tokenValueUsd(
                info.token,
                info.priceFeed,
                amountOut
            );

            userTokens[msg.sender][tokenAddr] -= amountOut;

            info.token.safeTransfer(msg.sender, amountOut);
        }

        require(
            totalVaultValueUsd() == vaultValaueBeforeWithdraw - withdrawUsdValue
        );

        return withdrawUsdValue;
        // return total
        // emit Withdraw(msg.sender, _shares, wethOut, usdcOut, valueUsd);
    }

    // ===========================
    // GETTERS
    // ===========================
    function isSupported(address _token) public view returns (bool) {
        return tokens[_token].supported;
    }
}

// function _mint(
//     address _to,
//     uint256 _amountWeth,
//     uint256 _amountUsdc
// ) private {
//     //In production, always read prices from oracles (e.g., Chainlink).
//     // combined USD value of both tokens
//     uint256 depositValueUSD = _amountWeth *
//         MOCK_USD_PRICE_WETH +
//         _amountUsdc;

//     // here 1 share = $1
//     uint256 sharesToMint;
//     if (totalShares == 0) {
//         sharesToMint = depositValueUSD;
//         pricePerShare = 1e18;
//     } else {
//         // In production, always read prices from oracles (e.g., Chainlink).
//         uint256 vaultValueUSD = totalWETH * MOCK_USD_PRICE_WETH + totalUSDC;
//         sharesToMint = (depositValueUSD * totalShares) / vaultValueUSD;
//         pricePerShare =
//             (totalWETH * MOCK_USD_PRICE_WETH + totalUSDC) /
//             totalShares;
//     }
//     sharePerUser[_to] += sharesToMint;
//     totalShares += sharesToMint;

//     // emit
// }

// share price=TVL/totalSupply

// function _burn(
//     address _from,
//     uint256 shares
// ) private returns (uint256, uint256) {
//     if (_from == address(0)) revert("Invalid address");
//     if (shares == 0 || shares > sharePerUser[_from])
//         revert("Invalid share amount");

//     uint256 wethAmt = (shares * totalWETH) / totalShares;
//     uint256 usdcAmt = (shares * totalUSDC) / totalShares;

//     // updates shares account
//     sharePerUser[_from] -= shares;
//     totalShares -= shares;

//     // emit
//     return (wethAmt, usdcAmt);
// }
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

// tokens are in proportion
