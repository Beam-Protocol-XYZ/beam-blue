// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

/// @title ICrossChainAdapter
/// @notice Abstract interface for cross-chain messaging protocols
interface ICrossChainAdapter {
    /// @notice Send a cross-chain message
    /// @param destChainId Destination chain identifier
    /// @param receiver Address of receiver contract on destination
    /// @param payload Encoded message data
    /// @param options Protocol-specific options (gas limit, etc.)
    function sendMessage(
        uint32 destChainId,
        address receiver,
        bytes calldata payload,
        bytes calldata options
    ) external payable returns (bytes32 messageId);

    /// @notice Quote the fee for sending a message
    /// @param destChainId Destination chain identifier
    /// @param payload Encoded message data
    /// @param options Protocol-specific options
    function quoteFee(
        uint32 destChainId,
        bytes calldata payload,
        bytes calldata options
    ) external view returns (uint256 nativeFee);

    /// @notice Get the local chain ID
    function getChainId() external view returns (uint32);
}
