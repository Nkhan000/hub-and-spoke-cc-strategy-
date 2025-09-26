// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

interface IStrategy {
    function deposit(uint256 amount) external returns (bool);
    function withdraw(uint256 amount) external returns (bool);
    function reportProfitAndLoss() external returns (uint256, uint256);
    function withdrawAll() external returns (bool);
    function collectAllProfits() external;
}
