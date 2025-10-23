// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title A multi token vault
/// @author Nazir Khan
/// @notice Handles multiple tokens (2-3) tokens sent by a liquidity provider from native and cross chain transfers
/// @dev

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

contract Vault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;

    AggregatorV3Interface public immutable wethUsdFeed; // e.g., Chainlink WETH/USD
    AggregatorV3Interface public immutable usdcUsdFeed; // e.g., Chainlink USDC/USD (often ~1)

    mapping(address => uint256) public wethBalanceOf;
    mapping(address => uint256) public usdcBalanceOf;

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
        address _weth,
        address _usdc,
        address _wethUsdFeed,
        address _usdcUsdFeed
    ) ERC20("Vault Share", "vSHARE") {
        require(_weth != address(0) && _usdc != address(0), "zero addr");
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        wethUsdFeed = AggregatorV3Interface(_wethUsdFeed);
        usdcUsdFeed = AggregatorV3Interface(_usdcUsdFeed);
    }

    function totalVaultValueUsd() public view returns (uint256) {
        uint256 wethBal = weth.balanceOf(address(this)); // e.g. 5 * 1e18
        uint256 usdcBal = usdc.balanceOf(address(this)); // e.g. 10_000 * 1e6
        return
            _tokenValueUsd(weth, wethUsdFeed, wethBal) +
            _tokenValueUsd(usdc, usdcUsdFeed, usdcBal);
    }

    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (totalVaultValueUsd() * (10 ** 18)) / supply; // returns USD-per-share scaled by 1e18
    }

    //===============================
    // EXTERNAL FUNCTIONS
    //===============================
    function deposit(uint256 _amountWeth, uint256 _amountUsdc) public virtual {
        _deposit(_amountWeth, _amountUsdc);
    }

    function withdraw(
        uint256 _shares
    ) public virtual returns (uint256 wethOut, uint256 usdcOut) {
        (wethOut, usdcOut) = _withdraw(_shares);
    }

    function tokenValueUsd(IERC20 token, uint256 amount) external view {
        AggregatorV3Interface feed;
        if (token == weth) {
            feed = wethUsdFeed;
        } else if (token == usdc) {
            feed = usdcUsdFeed;
        }
        _tokenValueUsd(token, feed, amount);
    }

    //===============================
    // INTERNAL FUNCTIONS
    //===============================

    function _latestPrice(
        AggregatorV3Interface feed
    ) internal view returns (uint256 price, uint8 feedDecimals) {
        (, int256 answer, , , ) = feed.latestRoundData();
        require(answer > 0, "Invalid price");
        feedDecimals = feed.decimals();
        price = uint256(answer);
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

    function _deposit(uint256 _amountWeth, uint256 _amountUsdc) internal {
        require(_amountWeth > 0 || _amountUsdc > 0, "Nothing to deposit");
        //
        uint256 supply = totalSupply();
        uint256 vaultValueBeforeDeposit = totalVaultValueUsd();

        // transfer tokens in first (prevents griefing)
        if (_amountWeth > 0)
            weth.safeTransferFrom(msg.sender, address(this), _amountWeth);
        if (_amountUsdc > 0)
            usdc.safeTransferFrom(msg.sender, address(this), _amountUsdc);

        // compute deposit USD value (18-decimals)
        uint256 totalDepositValueUsd = _tokenValueUsd(
            weth,
            wethUsdFeed,
            _amountWeth
        ) + _tokenValueUsd(usdc, usdcUsdFeed, _amountUsdc);

        require(totalDepositValueUsd > 0, "zero deposit value");

        uint256 vaultValueAfterDeposit = totalVaultValueUsd();

        require(
            vaultValueBeforeDeposit + totalDepositValueUsd >=
                vaultValueAfterDeposit
        );

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

        require(sharesMinted > 0, "Zero shares minted");
        _mint(msg.sender, sharesMinted);

        emit Deposit(
            msg.sender,
            sharesMinted,
            _amountWeth,
            _amountUsdc,
            totalDepositValueUsd
        );
    }

    function _withdraw(
        uint256 _shares
    ) internal returns (uint256 wethOut, uint256 usdcOut) {
        require(
            _shares > 0 && _shares <= balanceOf(msg.sender),
            "Invalid shares"
        );

        uint256 supply = totalSupply();
        if (supply == 0) revert("No shares to burn");

        uint256 wethAmt = weth.balanceOf(address(this));
        uint256 usdcAmt = usdc.balanceOf(address(this));

        // proportional amounts to send
        wethOut = (wethAmt * _shares) / supply;
        usdcOut = (usdcAmt * _shares) / supply;

        uint256 vaultValaueBeforeWithdraw = totalVaultValueUsd();

        // burn shares first to avoid reentrancy edgecases in accounting
        _burn(msg.sender, _shares);

        // transfers
        if (wethOut > 0) weth.safeTransfer(msg.sender, wethOut);
        if (usdcOut > 0) usdc.safeTransfer(msg.sender, usdcOut);

        uint256 valueUsd = _tokenValueUsd(weth, wethUsdFeed, wethOut) +
            _tokenValueUsd(usdc, usdcUsdFeed, usdcOut);

        require(totalVaultValueUsd() == vaultValaueBeforeWithdraw - valueUsd);

        emit Withdraw(msg.sender, _shares, wethOut, usdcOut, valueUsd);
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
