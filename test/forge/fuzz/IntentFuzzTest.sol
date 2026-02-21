// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {IntentLending} from "../../../src/intent/IntentLending.sol";
import {IIntentLending} from "../../../src/interfaces/IIntentLending.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {MockIntentOracle} from "../mocks/MockIntentOracle.sol";
import {Constants} from "../helpers/Constants.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

contract IntentFuzzTest is BaseTest {
    using MathLib for uint256;

    IntentLending public intentLending;
    MockIntentOracle public mockOracle;

    ERC20Mock public usdc;
    ERC20Mock public weth;

    address public LENDER = makeAddr("Lender");

    function setUp() public override {
        super.setUp();

        // Create tokens
        usdc = new ERC20Mock();
        vm.label(address(usdc), "USDC");

        weth = new ERC20Mock();
        vm.label(address(weth), "WETH");

        // Deploy IntentLending
        intentLending = new IntentLending(OWNER);

        // Setup oracle
        mockOracle = new MockIntentOracle();
        vm.prank(OWNER);
        intentLending.setOracle(
            address(weth),
            address(usdc),
            address(mockOracle)
        );

        // Fund users
        usdc.setBalance(LENDER, type(uint128).max);
        weth.setBalance(BORROWER, type(uint128).max);

        // Approvals
        vm.prank(LENDER);
        usdc.approve(address(intentLending), type(uint256).max);

        vm.prank(BORROWER);
        weth.approve(address(intentLending), type(uint256).max);
    }

    /**
     * @notice Fuzz matching intents with random amounts, rates, and LTVs.
     * @param amount The total amount of USDC provided by the lender.
     * @param loanAmount The amount of USDC being borrowed in this match.
     * @param requiredLTV The required LTV by the lender (scaled by 1e18).
     * @param collateralPrice The price of WETH in USDC (scaled by 1e36).
     */
    function testFuzz_MatchIntents(
        uint256 amount,
        uint256 loanAmount,
        uint256 requiredLTV,
        uint256 collateralPrice
    ) public {
        // Bound inputs to realistic and safe values
        amount = bound(amount, 1e6, 1_000_000e18);
        loanAmount = bound(loanAmount, 1e6, amount);
        requiredLTV = bound(requiredLTV, 0.1e18, 0.95e18);
        collateralPrice = bound(collateralPrice, 100e36, 100_000e36); // $100 to $100,000

        mockOracle.setPrice(collateralPrice);

        // Calculate required collateral based on LTV and price
        // requiredCollateral = (loanAmount * 1e18 / requiredLTV) / price * SCALER
        // val = (collateralAmount * price) / ORACLE_PRICE_SCALE
        // required: val >= (loanAmount * 1e18) / requiredLTV
        // (collateralAmount * price) / 1e36 >= (loanAmount * 1e18) / requiredLTV
        // collateralAmount >= (loanAmount * 1e18 * 1e36) / (requiredLTV * price)

        uint256 collateralAmount = loanAmount
            .mulDivUp(1e36, collateralPrice)
            .mulDivUp(1e18, requiredLTV);
        if (collateralAmount == 0) collateralAmount = 1;

        // Create Lend Intent
        vm.prank(LENDER);
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);
        bytes32 lendId = intentLending.createLendIntent(
            address(usdc),
            amount,
            1e6, // minAmount
            0.05e18, // minRate 5%
            30 days, // maxDuration
            collaterals,
            requiredLTV,
            block.timestamp + 1 days,
            bytes32(uint256(1))
        );

        // Create Borrow Intent
        vm.prank(BORROWER);
        bytes32 borrowId = intentLending.createBorrowIntent(
            address(usdc),
            loanAmount,
            0.1e18, // maxRate 10%
            7 days, // duration
            address(weth),
            collateralAmount,
            block.timestamp + 1 days,
            bytes32(uint256(2))
        );

        // Match
        intentLending.matchIntents(lendId, borrowId, 0.07e18, loanAmount);

        // Post-match checks
        IIntentLending.MatchedLoan memory loan = intentLending.getLoan(
            keccak256(
                abi.encodePacked(lendId, borrowId, loanAmount, uint256(0))
            )
        );

        assertTrue(loan.active, "Loan should be active");
        assertEq(loan.principal, loanAmount, "Principal mismatch");
        assertEq(loan.lender, LENDER, "Lender mismatch");
        assertEq(loan.borrower, BORROWER, "Borrower mismatch");

        uint256 health = intentLending.getLoanHealth(
            keccak256(
                abi.encodePacked(lendId, borrowId, loanAmount, uint256(0))
            )
        );
        assertGe(health, 1e18, "Loan should be healthy");
    }

    /**
     * @notice Fuzz liquidation triggers.
     */
    function testFuzz_Liquidation(
        uint256 loanAmount,
        uint256 requiredLTV,
        uint256 collateralPrice,
        uint256 priceDropPercent
    ) public {
        loanAmount = bound(loanAmount, 1e6, 10_000e18);
        requiredLTV = bound(requiredLTV, 0.5e18, 0.9e18);
        collateralPrice = bound(collateralPrice, 1000e36, 5000e36);
        priceDropPercent = bound(priceDropPercent, 1, 99);

        mockOracle.setPrice(collateralPrice);

        uint256 collateralAmount = loanAmount
            .mulDivUp(1e36, collateralPrice)
            .mulDivUp(1e18, requiredLTV);

        vm.prank(LENDER);
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);
        bytes32 lendId = intentLending.createLendIntent(
            address(usdc),
            loanAmount,
            loanAmount,
            0.05e18,
            30 days,
            collaterals,
            requiredLTV,
            block.timestamp + 1 days,
            bytes32(uint256(1))
        );

        vm.prank(BORROWER);
        bytes32 borrowId = intentLending.createBorrowIntent(
            address(usdc),
            loanAmount,
            0.1e18,
            7 days,
            address(weth),
            collateralAmount,
            block.timestamp + 1 days,
            bytes32(uint256(2))
        );

        bytes32 loanId = intentLending.matchIntents(
            lendId,
            borrowId,
            0.07e18,
            loanAmount
        );

        // Drop price to trigger liquidation
        // If requiredLTV is 0.8, health factor is ~1.0.
        // Dropping price by enough should make health < 1.0.
        uint256 newPrice = (collateralPrice * (100 - priceDropPercent)) / 100;
        mockOracle.setPrice(newPrice);

        uint256 health = intentLending.getLoanHealth(loanId);

        if (health < 1e18) {
            // Should be liquidatable
            address liquidator = makeAddr("Liquidator");
            usdc.setBalance(liquidator, loanAmount * 2);
            vm.startPrank(liquidator);
            usdc.approve(address(intentLending), type(uint256).max);
            intentLending.liquidate(loanId);
            vm.stopPrank();

            assertFalse(
                intentLending.getLoan(loanId).active,
                "Loan should be inactive after liquidation"
            );
        } else {
            // Should revert if healthy and not expired
            vm.expectRevert();
            intentLending.liquidate(loanId);
        }
    }

    /**
     * @notice Fuzz cancellation of lend and borrow intents.
     */
    function testFuzz_CancelIntents(
        uint256 amount,
        uint256 borrowAmount,
        uint256 collateralPrice
    ) public {
        amount = bound(amount, 1e6, 1_000_000e18);
        borrowAmount = bound(borrowAmount, 1e6, 1_000_000e18);
        collateralPrice = bound(collateralPrice, 100e36, 100_000e36);

        mockOracle.setPrice(collateralPrice);

        uint256 lenderBalBefore = usdc.balanceOf(LENDER);

        // Create and cancel lend intent
        vm.prank(LENDER);
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);
        bytes32 lendId = intentLending.createLendIntent(
            address(usdc),
            amount,
            1e6,
            0.05e18,
            30 days,
            collaterals,
            0.8e18,
            block.timestamp + 1 days,
            bytes32(uint256(1))
        );

        // Lender balance should have decreased
        assertEq(usdc.balanceOf(LENDER), lenderBalBefore - amount);

        vm.prank(LENDER);
        intentLending.cancelLendIntent(lendId);

        // Balance refunded
        assertEq(usdc.balanceOf(LENDER), lenderBalBefore);

        // Create and cancel borrow intent
        uint256 collateralAmount = borrowAmount
            .mulDivUp(1e36, collateralPrice)
            .mulDivUp(1e18, 0.8e18);
        if (collateralAmount == 0) collateralAmount = 1;

        uint256 borrowerBalBefore = weth.balanceOf(BORROWER);

        vm.prank(BORROWER);
        bytes32 borrowId = intentLending.createBorrowIntent(
            address(usdc),
            borrowAmount,
            0.1e18,
            7 days,
            address(weth),
            collateralAmount,
            block.timestamp + 1 days,
            bytes32(uint256(2))
        );

        assertEq(
            weth.balanceOf(BORROWER),
            borrowerBalBefore - collateralAmount
        );

        vm.prank(BORROWER);
        intentLending.cancelBorrowIntent(borrowId);

        assertEq(weth.balanceOf(BORROWER), borrowerBalBefore);
    }

    /**
     * @notice Fuzz loan repayment by borrower.
     */
    function testFuzz_Repay(
        uint256 loanAmount,
        uint256 repayPercent,
        uint256 collateralPrice
    ) public {
        loanAmount = bound(loanAmount, 1e6, 100_000e18);
        repayPercent = bound(repayPercent, 1, 100);
        collateralPrice = bound(collateralPrice, 1000e36, 10_000e36);

        mockOracle.setPrice(collateralPrice);

        uint256 requiredLTV = 0.8e18;
        uint256 collateralAmount = loanAmount
            .mulDivUp(1e36, collateralPrice)
            .mulDivUp(1e18, requiredLTV);
        if (collateralAmount == 0) collateralAmount = 1;

        // Create and match
        vm.prank(LENDER);
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);
        bytes32 lendId = intentLending.createLendIntent(
            address(usdc),
            loanAmount,
            loanAmount,
            0.05e18,
            30 days,
            collaterals,
            requiredLTV,
            block.timestamp + 1 days,
            bytes32(uint256(1))
        );

        vm.prank(BORROWER);
        bytes32 borrowId = intentLending.createBorrowIntent(
            address(usdc),
            loanAmount,
            0.1e18,
            7 days,
            address(weth),
            collateralAmount,
            block.timestamp + 1 days,
            bytes32(uint256(2))
        );

        bytes32 loanId = intentLending.matchIntents(
            lendId,
            borrowId,
            0.07e18,
            loanAmount
        );

        // Borrower repays
        uint256 repayAmount = (loanAmount * repayPercent) / 100;
        if (repayAmount == 0) repayAmount = 1;

        usdc.setBalance(BORROWER, repayAmount);
        vm.startPrank(BORROWER);
        usdc.approve(address(intentLending), type(uint256).max);
        intentLending.repay(loanId, repayAmount);
        vm.stopPrank();

        IIntentLending.MatchedLoan memory loan = intentLending.getLoan(loanId);
        assertEq(loan.repaidAmount, repayAmount);
    }
}
