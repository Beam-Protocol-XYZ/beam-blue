// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {IRedemptionAdapter} from "../../../src/dex/interfaces/IRedemptionAdapter.sol";

/// @notice Mock RWA token for testing
contract MockRWAToken is ERC20Mock {
    uint256 public price = 1e18; // 1:1 with output token

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}

/// @notice Mock adapter for testing
contract MockRedemptionAdapter is IRedemptionAdapter {
    mapping(bytes32 => bool) public completedRedemptions;
    mapping(bytes32 => uint256) public redemptionAmounts;
    mapping(address => uint256) public settlementPeriods;
    mapping(address => address) public outputTokens;
    mapping(address => bool) public supported;

    uint256 private _nonce;
    mapping(bytes32 => address) private _requestOutputToken;

    function configureToken(
        address rwaToken,
        address outputToken,
        uint256 period
    ) external {
        supported[rwaToken] = true;
        outputTokens[rwaToken] = outputToken;
        settlementPeriods[rwaToken] = period;
    }

    function initiateRedemption(
        address rwaToken,
        uint256 amount,
        address /* receiver */
    ) external override returns (bytes32 requestId) {
        requestId = keccak256(abi.encodePacked(rwaToken, amount, _nonce++));
        redemptionAmounts[requestId] = amount;
        _requestOutputToken[requestId] = outputTokens[rwaToken];
    }

    function completeRedemption(bytes32 requestId) external {
        completedRedemptions[requestId] = true;
    }

    function isRedemptionComplete(
        bytes32 requestId
    ) external view override returns (bool) {
        return completedRedemptions[requestId];
    }

    function claimRedemption(
        bytes32 requestId
    ) external override returns (uint256) {
        uint256 amount = redemptionAmounts[requestId];
        // Transfer output tokens to caller (the facility)
        // The test must set the adapter's balance beforehand
        if (amount > 0) {
            // Iterate to find which rwaToken this maps to - simplified: just transfer any USDC we hold
            // The test sets our balance before calling settle
            address outputToken = _requestOutputToken[requestId];
            if (outputToken != address(0)) {
                ERC20Mock(outputToken).transfer(msg.sender, amount);
            }
        }
        return amount;
    }

    function getRedemptionQuote(
        address rwaToken,
        uint256 amount
    )
        external
        view
        override
        returns (address outputToken, uint256 expectedOutput)
    {
        outputToken = outputTokens[rwaToken];
        expectedOutput = amount; // 1:1 for simplicity
    }

    function getSettlementPeriod(
        address rwaToken
    ) external view override returns (uint256) {
        return settlementPeriods[rwaToken];
    }

    function protocolName() external pure override returns (string memory) {
        return "Mock Adapter";
    }

    function supportsToken(
        address rwaToken
    ) external view override returns (bool) {
        return supported[rwaToken];
    }
}
