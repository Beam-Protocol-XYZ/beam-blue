// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

/// @title IRedemptionAdapter
/// @notice Interface for RWA protocol redemption adapters
/// @dev Each adapter handles protocol-specific redemption logic
interface IRedemptionAdapter {
    /// @notice Initiate redemption of RWA tokens
    /// @param rwaToken The RWA token being redeemed
    /// @param amount Amount of RWA tokens to redeem
    /// @param receiver Address to receive redeemed assets
    /// @return requestId Unique identifier for tracking redemption
    function initiateRedemption(
        address rwaToken,
        uint256 amount,
        address receiver
    ) external returns (bytes32 requestId);

    /// @notice Check if redemption is complete
    /// @param requestId The redemption request identifier
    /// @return complete True if redemption can be claimed
    function isRedemptionComplete(
        bytes32 requestId
    ) external view returns (bool complete);

    /// @notice Claim completed redemption
    /// @param requestId The redemption request identifier
    /// @return amount Amount of output token received
    function claimRedemption(
        bytes32 requestId
    ) external returns (uint256 amount);

    /// @notice Get expected redemption output
    /// @param rwaToken The RWA token to redeem
    /// @param amount Amount of RWA tokens
    /// @return outputToken Address of token received from redemption
    /// @return expectedOutput Expected amount of output token
    function getRedemptionQuote(
        address rwaToken,
        uint256 amount
    ) external view returns (address outputToken, uint256 expectedOutput);

    /// @notice Expected settlement delay in seconds
    /// @param rwaToken The RWA token
    /// @return delay Settlement period in seconds
    function getSettlementPeriod(
        address rwaToken
    ) external view returns (uint256 delay);

    /// @notice Protocol-specific identifier
    /// @return name Human-readable protocol name
    function protocolName() external view returns (string memory name);

    /// @notice Check if adapter supports a specific RWA token
    /// @param rwaToken The RWA token to check
    /// @return supported True if token is supported
    function supportsToken(
        address rwaToken
    ) external view returns (bool supported);
}
