// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IRedemptionAdapter} from "../interfaces/IRedemptionAdapter.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @title BaseRedemptionAdapter
/// @notice Abstract base adapter with common functionality for RWA redemptions
/// @dev Concrete adapters (Ondo, Centrifuge, etc.) inherit and implement protocol specifics
abstract contract BaseRedemptionAdapter is IRedemptionAdapter {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    /// @notice The RedemptionFacility contract authorized to call this adapter
    address public immutable redemptionFacility;

    /// @notice Owner for configuration
    address public owner;

    /// @notice Supported RWA tokens for this adapter
    mapping(address => bool) public supportedTokens;

    /// @notice Output token for each RWA token
    mapping(address => address) public outputTokens;

    /// @notice Settlement period for each RWA token (in seconds)
    mapping(address => uint256) public settlementPeriods;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event TokenConfigured(
        address indexed rwaToken,
        address outputToken,
        uint256 settlementPeriod
    );
    event TokenRemoved(address indexed rwaToken);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error Unauthorized();
    error ZeroAddress();
    error TokenNotSupported();
    error InvalidSettlementPeriod();

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyFacility() {
        if (msg.sender != redemptionFacility) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _redemptionFacility, address _owner) {
        if (_redemptionFacility == address(0) || _owner == address(0))
            revert ZeroAddress();
        redemptionFacility = _redemptionFacility;
        owner = _owner;
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Configure a supported RWA token
    /// @param rwaToken The RWA token address
    /// @param outputToken The token received from redemption (e.g., USDC)
    /// @param settlementPeriod Expected settlement time in seconds
    function configureToken(
        address rwaToken,
        address outputToken,
        uint256 settlementPeriod
    ) external onlyOwner {
        if (rwaToken == address(0) || outputToken == address(0))
            revert ZeroAddress();
        if (settlementPeriod == 0) revert InvalidSettlementPeriod();

        supportedTokens[rwaToken] = true;
        outputTokens[rwaToken] = outputToken;
        settlementPeriods[rwaToken] = settlementPeriod;

        emit TokenConfigured(rwaToken, outputToken, settlementPeriod);
    }

    /// @notice Remove a supported token
    function removeToken(address rwaToken) external onlyOwner {
        supportedTokens[rwaToken] = false;
        delete outputTokens[rwaToken];
        delete settlementPeriods[rwaToken];
        emit TokenRemoved(rwaToken);
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @inheritdoc IRedemptionAdapter
    function supportsToken(
        address rwaToken
    ) external view override returns (bool) {
        return supportedTokens[rwaToken];
    }

    /// @inheritdoc IRedemptionAdapter
    function getSettlementPeriod(
        address rwaToken
    ) external view override returns (uint256) {
        return settlementPeriods[rwaToken];
    }

    /// @inheritdoc IRedemptionAdapter
    function getRedemptionQuote(
        address rwaToken,
        uint256 amount
    )
        external
        view
        virtual
        override
        returns (address outputToken, uint256 expectedOutput)
    {
        if (!supportedTokens[rwaToken]) revert TokenNotSupported();
        outputToken = outputTokens[rwaToken];
        expectedOutput = _calculateExpectedOutput(rwaToken, amount);
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Calculate expected output amount (protocol-specific)
    /// @param rwaToken The RWA token
    /// @param amount Input amount
    /// @return expectedOutput Expected output amount
    function _calculateExpectedOutput(
        address rwaToken,
        uint256 amount
    ) internal view virtual returns (uint256 expectedOutput);

    /// @dev Validate token before redemption
    function _validateToken(address rwaToken) internal view {
        if (!supportedTokens[rwaToken]) revert TokenNotSupported();
    }
}
