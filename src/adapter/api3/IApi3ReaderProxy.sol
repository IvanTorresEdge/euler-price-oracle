// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title IApi3ReaderProxy
/// @notice API3 Api3ReaderProxyV1 proxy interface for reading price data
interface IApi3ReaderProxy {
    /// @notice Read the latest value and timestamp from the Api3ReaderProxyV1
    /// @return value The latest price value with 18 decimals
    /// @return timestamp The timestamp when the value was last updated
    function read() external view returns (int224 value, uint256 timestamp);
}