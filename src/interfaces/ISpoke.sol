// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

interface ISpoke {
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256);

    function addLiquidityProvider(address _lp) external;

    function removeLiquidityProvider(address _lp) external;

    function sendDepositsToHub() external;

    function receiveWithdrawalFromHub() external;
}
