// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @dev The parts of mellow-interop's `Oracle` that OracleUpdater uses. The oracle authorizes
///      `setValue` against its SourceCore's access control (`ORACLE:SET_VALUE_ROLE`).
interface IMellowOracle {
    function value() external view returns (uint256);

    function lastUpdated() external view returns (uint256);

    function setValue(
        uint256 value_
    ) external;
}

/// @dev The parts of mellow-interop's `SourceCore` (the aOG vault) that OracleUpdater uses.
interface IMellowSourceCore {
    function oracle() external view returns (IMellowOracle);

    function asset() external view returns (address);

    function oftAdapter() external view returns (address);

    function totalSupply() external view returns (uint256);
}
