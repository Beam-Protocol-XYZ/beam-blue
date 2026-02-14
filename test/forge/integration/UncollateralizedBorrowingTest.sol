// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {Id, MarketParams, IMorpho} from "../../../src/interfaces/IMorpho.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../../../src/libraries/periphery/MorphoLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

contract UncollateralizedBorrowingTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    MarketParams internal uncollateralizedMarketParams;
    Id internal uncollateralizedId;
    address internal WHITELISTED_BORROWER;

    function setUp() public override {
        super.setUp();

        WHITELISTED_BORROWER = makeAddr("WhitelistedBorrower");

        // Create an uncollateralized market: collateral=0, oracle=0, lltv=0, irm!=0
        uncollateralizedMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        uncollateralizedId = uncollateralizedMarketParams.id();

        vm.prank(OWNER);
        morpho.createMarket(uncollateralizedMarketParams);

        // Whitelist the borrower
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(
            uncollateralizedId,
            WHITELISTED_BORROWER,
            true
        );

        // Approve tokens for whitelisted borrower
        vm.startPrank(WHITELISTED_BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    function testWhitelistedBorrowerCanBorrow(
        uint256 amountSupplied,
        uint256 amountBorrowed
    ) public {
        amountSupplied = bound(
            amountSupplied,
            MIN_TEST_AMOUNT,
            MAX_TEST_AMOUNT
        );
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, amountSupplied);

        // Supply liquidity
        loanToken.setBalance(SUPPLIER, amountSupplied);
        vm.prank(SUPPLIER);
        morpho.supply(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            hex""
        );

        // Whitelisted borrower borrows without collateral
        vm.prank(WHITELISTED_BORROWER);
        (uint256 assetsBorrowed, ) = morpho.borrow(
            uncollateralizedMarketParams,
            amountBorrowed,
            0,
            WHITELISTED_BORROWER,
            WHITELISTED_BORROWER
        );

        assertEq(assetsBorrowed, amountBorrowed, "borrowed amount");
        assertEq(
            loanToken.balanceOf(WHITELISTED_BORROWER),
            amountBorrowed,
            "borrower balance"
        );
    }

    function testNonWhitelistedBorrowerCannotBorrow(
        uint256 amountSupplied,
        uint256 amountBorrowed
    ) public {
        amountSupplied = bound(
            amountSupplied,
            MIN_TEST_AMOUNT,
            MAX_TEST_AMOUNT
        );
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, amountSupplied);

        // Supply liquidity
        loanToken.setBalance(SUPPLIER, amountSupplied);
        vm.prank(SUPPLIER);
        morpho.supply(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            hex""
        );

        // Non-whitelisted borrower cannot borrow
        vm.prank(BORROWER);
        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        morpho.borrow(
            uncollateralizedMarketParams,
            amountBorrowed,
            0,
            BORROWER,
            BORROWER
        );
    }

    function testWhitelistedBorrowerCanRepay(
        uint256 amountSupplied,
        uint256 amountBorrowed
    ) public {
        amountSupplied = bound(
            amountSupplied,
            MIN_TEST_AMOUNT,
            MAX_TEST_AMOUNT
        );
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, amountSupplied);

        // Supply liquidity
        loanToken.setBalance(SUPPLIER, amountSupplied);
        vm.prank(SUPPLIER);
        morpho.supply(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            hex""
        );

        // Borrow
        vm.prank(WHITELISTED_BORROWER);
        morpho.borrow(
            uncollateralizedMarketParams,
            amountBorrowed,
            0,
            WHITELISTED_BORROWER,
            WHITELISTED_BORROWER
        );

        // Repay
        loanToken.setBalance(WHITELISTED_BORROWER, amountBorrowed * 2); // Extra for interest
        vm.prank(WHITELISTED_BORROWER);
        uint256 borrowShares = morpho.borrowShares(
            uncollateralizedId,
            WHITELISTED_BORROWER
        );
        morpho.repay(
            uncollateralizedMarketParams,
            0,
            borrowShares,
            WHITELISTED_BORROWER,
            hex""
        );

        assertEq(
            morpho.borrowShares(uncollateralizedId, WHITELISTED_BORROWER),
            0,
            "borrow shares after repay"
        );
    }

    function testLiquidationRevertsForZeroCollateralMarket(
        uint256 amountSupplied,
        uint256 amountBorrowed
    ) public {
        amountSupplied = bound(
            amountSupplied,
            MIN_TEST_AMOUNT,
            MAX_TEST_AMOUNT
        );
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, amountSupplied);

        // Supply and borrow
        loanToken.setBalance(SUPPLIER, amountSupplied);
        vm.prank(SUPPLIER);
        morpho.supply(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            hex""
        );

        vm.prank(WHITELISTED_BORROWER);
        morpho.borrow(
            uncollateralizedMarketParams,
            amountBorrowed,
            0,
            WHITELISTED_BORROWER,
            WHITELISTED_BORROWER
        );

        // Liquidation should revert
        vm.prank(LIQUIDATOR);
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        morpho.liquidate(
            uncollateralizedMarketParams,
            WHITELISTED_BORROWER,
            0,
            1,
            hex""
        );
    }

    function testOwnerCanAddRemoveWhitelistedBorrower() public {
        address newBorrower = makeAddr("NewBorrower");

        // Add
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(
            uncollateralizedId,
            newBorrower,
            true
        );
        assertTrue(
            morpho.isUncollateralizedBorrower(uncollateralizedId, newBorrower),
            "should be whitelisted"
        );

        // Remove
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(
            uncollateralizedId,
            newBorrower,
            false
        );
        assertFalse(
            morpho.isUncollateralizedBorrower(uncollateralizedId, newBorrower),
            "should not be whitelisted"
        );
    }

    function testNonOwnerCannotSetWhitelist() public {
        vm.prank(BORROWER);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        morpho.setUncollateralizedBorrower(uncollateralizedId, BORROWER, true);
    }

    function testSupplyWithdrawWorksOnUncollateralizedMarket(
        uint256 amountSupplied
    ) public {
        amountSupplied = bound(
            amountSupplied,
            MIN_TEST_AMOUNT,
            MAX_TEST_AMOUNT
        );

        // Supply
        loanToken.setBalance(SUPPLIER, amountSupplied);
        vm.prank(SUPPLIER);
        morpho.supply(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            hex""
        );

        assertEq(
            morpho.totalSupplyAssets(uncollateralizedId),
            amountSupplied,
            "total supply"
        );

        // Withdraw
        vm.prank(SUPPLIER);
        morpho.withdraw(
            uncollateralizedMarketParams,
            amountSupplied,
            0,
            SUPPLIER,
            SUPPLIER
        );

        assertEq(
            morpho.totalSupplyAssets(uncollateralizedId),
            0,
            "total supply after withdraw"
        );
        assertEq(
            loanToken.balanceOf(SUPPLIER),
            amountSupplied,
            "supplier balance"
        );
    }

    function testIdleMarketDoesNotAllowBorrowing() public {
        // Create an idle market (irm = 0)
        MarketParams memory idleMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });

        vm.prank(OWNER);
        morpho.createMarket(idleMarketParams);

        Id idleId = idleMarketParams.id();

        // Even if we whitelist someone on this market, borrowing should fail
        // because _isUncollateralizedMarket returns false (irm == 0)
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(idleId, WHITELISTED_BORROWER, true);

        // Supply liquidity
        loanToken.setBalance(SUPPLIER, 1000e18);
        vm.prank(SUPPLIER);
        morpho.supply(idleMarketParams, 1000e18, 0, SUPPLIER, hex"");

        // Borrowing should fail because idle markets don't pass _isUncollateralizedMarket check
        vm.prank(WHITELISTED_BORROWER);
        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        morpho.borrow(
            idleMarketParams,
            100e18,
            0,
            WHITELISTED_BORROWER,
            WHITELISTED_BORROWER
        );
    }
}
