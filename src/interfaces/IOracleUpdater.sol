// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IMellowSourceCore} from "./IMellowSourceCore.sol";

interface IOracleUpdater {
    /// @dev An initialization address is zero
    error OracleUpdaterZeroAddress();

    /// @dev The source core address has no code
    error OracleUpdaterNotAContract(address account);

    /// @dev The new value is below the value the oracle currently holds
    error OracleUpdaterValueDecrease(uint256 current, uint256 value);

    /// @dev The new value is above the share price the vault's on-chain assets can back
    error OracleUpdaterValueAboveNav(uint256 maxValue, uint256 value);

    /// @dev The vault has no shares outstanding, so it has no share price
    error OracleUpdaterZeroSupply();

    /**
     * @dev Writes `value` to the vault's oracle, provided it lies within
     *      `[oracle.value(), maxValue()]`
     * @param value New share price, 18 decimals
     */
    function setValue(
        uint256 value
    ) external;

    /**
     * @dev The highest share price the vault's assets on this chain can back: the W0G held by the
     *      SourceCore plus the W0G locked in its OFT adapter, per share
     */
    function maxValue() external view returns (uint256);

    /// @dev The aOG vault whose oracle this contract writes
    function sourceCore() external view returns (IMellowSourceCore);
}
