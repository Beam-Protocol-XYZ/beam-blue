// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id} from "../interfaces/IMorpho.sol";
import {CrossPlatformLending} from "./CrossPlatformLending.sol";

/// @title CrossPlatformFactory
/// @notice Factory that deploys per-partner CrossPlatformLending contracts
/// @dev Each deployed contract must be separately whitelisted as an uncollateralized borrower on Morpho
contract CrossPlatformFactory {
    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public immutable morpho;
    address public owner;

    /// @notice Partner address → deployed contract
    mapping(address partner => address) public partnerContracts;

    /// @notice All deployed contracts
    address[] public allContracts;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event PartnerContractDeployed(
        address indexed partner,
        address indexed contractAddress,
        Id indexed morphoMarketId,
        uint256 seizureDelay
    );

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error ZeroAddress();
    error PartnerAlreadyDeployed();

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _morpho, address _owner) {
        if (_morpho == address(0) || _owner == address(0)) revert ZeroAddress();
        morpho = _morpho;
        owner = _owner;
    }

    /* ═══════════════════════════════════════════ FACTORY ═══════════════════════════════════════════ */

    /// @notice Deploy a new CrossPlatformLending contract for a partner
    /// @param partner The authorized partner (bank/loan provider) address
    /// @param morphoMarketId The uncollateralized Morpho market to borrow from
    /// @param seizureDelay Grace period for collateral seizure (24-48 hours)
    /// @return deployed The address of the newly deployed contract
    /// @dev After deployment, the Morpho owner must call:
    ///      morpho.setUncollateralizedBorrower(morphoMarketId, deployed, true)
    function deployPartnerContract(
        address partner,
        Id morphoMarketId,
        uint256 seizureDelay
    ) external onlyOwner returns (address deployed) {
        if (partner == address(0)) revert ZeroAddress();
        if (partnerContracts[partner] != address(0))
            revert PartnerAlreadyDeployed();

        CrossPlatformLending newContract = new CrossPlatformLending(
            morpho,
            partner,
            owner, // Protocol owner manages the deployed contract
            morphoMarketId,
            seizureDelay
        );

        deployed = address(newContract);
        partnerContracts[partner] = deployed;
        allContracts.push(deployed);

        emit PartnerContractDeployed(
            partner,
            deployed,
            morphoMarketId,
            seizureDelay
        );
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /// @notice Get the number of deployed partner contracts
    function contractCount() external view returns (uint256) {
        return allContracts.length;
    }
}
