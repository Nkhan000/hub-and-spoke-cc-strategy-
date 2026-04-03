// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

contract Keeper {
    /** Following condition must be true for the checkUpKeep to return true
     * 1. Max Batch Size
     * 2. Amount of tokens available.
     */
    function checkUpKeep(
        bytes calldata /*calldata */
    ) public view returns (bool upkeepNeeded, bytes memory /*performData*/) {
        //
    }

    function performUpkeep() external view {}
}
