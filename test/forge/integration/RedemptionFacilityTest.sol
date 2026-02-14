// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {RedemptionFacility} from "../../../src/dex/RedemptionFacility.sol";
import {IRedemptionAdapter} from "../../../src/dex/interfaces/IRedemptionAdapter.sol";
import {Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {MockRWAToken, MockRedemptionAdapter} from "../mocks/MockRedemptionAdapter.sol";

contract RedemptionFacilityTest is BaseTest {
    using MarketParamsLib for MarketParams;

    RedemptionFacility public facility;
    MockRedemptionAdapter public mockAdapter;
    MockRWAToken public rwaToken;

    MarketParams public usdcMarket;
    Id public usdcMarketId;

    ERC20Mock public usdc;

    address public USER;

    function setUp() public override {
        super.setUp();

        USER = makeAddr("User");

        // Create mock tokens
        usdc = new ERC20Mock();
        vm.label(address(usdc), "USDC");

        rwaToken = new MockRWAToken();
        vm.label(address(rwaToken), "RWA");

        // Setup Morpho market for USDC
        usdcMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        morpho.createMarket(usdcMarket);
        usdcMarketId = usdcMarket.id();

        // Whitelist facility as uncollateralized borrower
        morpho.setUncollateralizedBorrower(usdcMarketId, address(0), true); // Will set real address after deploy

        // Deploy facility
        facility = new RedemptionFacility(address(morpho), OWNER);

        // Whitelist facility as uncollateralized borrower
        morpho.setUncollateralizedBorrower(
            usdcMarketId,
            address(facility),
            true
        );

        // Setup mock adapter
        mockAdapter = new MockRedemptionAdapter();
        mockAdapter.configureToken(address(rwaToken), address(usdc), 1 days);

        // Configure RWA in facility
        vm.prank(OWNER);
        facility.configureRWA(
            address(rwaToken),
            IRedemptionAdapter(address(mockAdapter)),
            usdcMarketId,
            address(oracle),
            1 days,
            0.9e18, // 90% LTV
            address(usdc)
        );

        // Whitelist market in facility for borrowing
        vm.prank(OWNER);
        facility.whitelistMarket(usdcMarketId);

        // Supply USDC to Morpho so facility can borrow
        usdc.setBalance(SUPPLIER, 1_000_000e18);
        vm.startPrank(SUPPLIER);
        usdc.approve(address(morpho), type(uint256).max);
        morpho.supply(usdcMarket, 1_000_000e18, 0, SUPPLIER, "");
        vm.stopPrank();

        // Setup user
        rwaToken.setBalance(USER, 10_000e18);
        vm.prank(USER);
        rwaToken.approve(address(facility), type(uint256).max);
    }

    function testInstantRedeemBasic() public {
        uint256 redeemAmount = 1000e18;

        vm.prank(USER);
        (bytes32 redemptionId, uint256 outputAmount) = facility.instantRedeem(
            address(rwaToken),
            redeemAmount,
            0 // No minimum
        );

        assertGt(outputAmount, 0, "Should receive output");
        assertLt(
            outputAmount,
            redeemAmount,
            "Output should be less due to fees"
        );
        assertEq(
            usdc.balanceOf(USER),
            outputAmount,
            "User should receive USDC"
        );
    }

    function testInstantRedeemSettlementFees() public {
        // Test that longer settlement periods result in higher fees
        uint256 baseAmount = 10000e18;

        // Configure 1-hour settlement
        mockAdapter.configureToken(
            address(rwaToken),
            address(usdc),
            30 minutes
        );
        vm.prank(OWNER);
        facility.configureRWA(
            address(rwaToken),
            IRedemptionAdapter(address(mockAdapter)),
            usdcMarketId,
            address(oracle),
            30 minutes, // Under 1 hour - lowest tier
            0.9e18,
            address(usdc)
        );

        uint256 feeShort = facility.calculateRedemptionFee(
            address(rwaToken),
            baseAmount
        );

        // Configure 7-day settlement
        vm.prank(OWNER);
        facility.configureRWA(
            address(rwaToken),
            IRedemptionAdapter(address(mockAdapter)),
            usdcMarketId,
            address(oracle),
            7 days,
            0.9e18,
            address(usdc)
        );

        uint256 feeLong = facility.calculateRedemptionFee(
            address(rwaToken),
            baseAmount
        );

        assertGt(
            feeLong,
            feeShort,
            "Longer settlement should have higher fees"
        );
    }

    function testSettleRedemption() public {
        uint256 redeemAmount = 1000e18;

        vm.prank(USER);
        (bytes32 redemptionId, ) = facility.instantRedeem(
            address(rwaToken),
            redeemAmount,
            0
        );

        // Mark redemption complete in mock adapter
        mockAdapter.completeRedemption(
            keccak256(
                abi.encodePacked(address(rwaToken), redeemAmount, uint256(0))
            )
        );

        // Mint USDC to adapter (simulating RWA protocol returning USDC)
        usdc.setBalance(address(mockAdapter), redeemAmount);

        // Settle
        facility.settleRedemption(redemptionId);

        // Check redemption is settled
        (, , , , , , , bool settled) = facility.redemptions(redemptionId);
        assertTrue(settled, "Redemption should be settled");
    }

    function testSettleRedemptionBeforeCompleteFails() public {
        uint256 redeemAmount = 1000e18;

        vm.prank(USER);
        (bytes32 redemptionId, ) = facility.instantRedeem(
            address(rwaToken),
            redeemAmount,
            0
        );

        // Try to settle before adapter marks complete
        vm.expectRevert(RedemptionFacility.RedemptionNotComplete.selector);
        facility.settleRedemption(redemptionId);
    }

    function testRedeemUnwhitelistedRWAFails() public {
        ERC20Mock badToken = new ERC20Mock();
        badToken.setBalance(USER, 1000e18);

        vm.startPrank(USER);
        badToken.approve(address(facility), type(uint256).max);

        vm.expectRevert(RedemptionFacility.RWANotEnabled.selector);
        facility.instantRedeem(address(badToken), 1000e18, 0);
        vm.stopPrank();
    }

    function testQuoteInstantRedeem() public {
        uint256 redeemAmount = 1000e18;

        (uint256 outputAmount, uint256 fee) = facility.quoteInstantRedeem(
            address(rwaToken),
            redeemAmount
        );

        assertGt(outputAmount, 0, "Quote should return output");
        assertGt(fee, 0, "Fee should be positive");
        assertEq(
            outputAmount + fee,
            redeemAmount,
            "Output + fee should equal input"
        );
    }
}
