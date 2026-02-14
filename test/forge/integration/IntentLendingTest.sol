// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {IntentLending} from "../../../src/intent/IntentLending.sol";
import {IIntentLending} from "../../../src/interfaces/IIntentLending.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {MockIntentOracle} from "../mocks/MockIntentOracle.sol";
import {Constants} from "../helpers/Constants.sol";

contract IntentLendingTest is BaseTest {
    IntentLending public intentLending;
    MockIntentOracle public mockOracle;

    ERC20Mock public usdc;
    ERC20Mock public weth;

    address public LENDER;
    address public SOLVER;

    function setUp() public override {
        super.setUp();

        LENDER = makeAddr("Lender");
        BORROWER = makeAddr("Borrower");
        SOLVER = makeAddr("Solver");

        // Create tokens
        usdc = new ERC20Mock();
        vm.label(address(usdc), "USDC");

        weth = new ERC20Mock();
        vm.label(address(weth), "WETH");

        // Deploy IntentLending
        intentLending = new IntentLending(OWNER);

        // Setup oracle
        mockOracle = new MockIntentOracle();
        mockOracle.setPrice(2000 * Constants.ORACLE_PRICE_SCALE); // $2000 per WETH
        vm.prank(OWNER);
        intentLending.setOracle(
            address(weth),
            address(usdc),
            address(mockOracle)
        );

        // Fund users
        usdc.setBalance(LENDER, 1_000_000e18);
        weth.setBalance(BORROWER, 100e18);

        // Approvals
        vm.prank(LENDER);
        usdc.approve(address(intentLending), type(uint256).max);

        vm.prank(BORROWER);
        weth.approve(address(intentLending), type(uint256).max);
    }

    function testCreateLendIntent() public {
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 intentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18, // amount
            10_000e18, // minAmount
            uint256(0.05e18) / 365 days, // ~5% APY per second
            30 days, // maxDuration
            collaterals,
            0.75e18, // 75% LTV
            block.timestamp + 7 days,
            keccak256("salt1")
        );

        assertTrue(
            intentLending.isLendIntentFillable(intentId),
            "Intent should be fillable"
        );
        assertEq(
            usdc.balanceOf(address(intentLending)),
            100_000e18,
            "Tokens should be escrowed"
        );
    }

    function testCreateBorrowIntent() public {
        vm.prank(BORROWER);
        bytes32 intentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18, // amount
            uint256(0.10e18) / 365 days, // ~10% APY max
            14 days, // duration
            address(weth),
            10e18, // collateral
            block.timestamp + 3 days,
            keccak256("salt2")
        );

        assertTrue(
            intentLending.isBorrowIntentFillable(intentId),
            "Intent should be fillable"
        );
        assertEq(
            weth.balanceOf(address(intentLending)),
            10e18,
            "Collateral should be escrowed"
        );
    }

    function testMatchIntents() public {
        // Create lend intent
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 lendIntentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(0.05e18) / 365 days,
            30 days,
            collaterals,
            0.75e18,
            block.timestamp + 7 days,
            keccak256("lend1")
        );

        // Create borrow intent
        vm.prank(BORROWER);
        bytes32 borrowIntentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(0.10e18) / 365 days,
            14 days,
            address(weth),
            20e18, // Enough collateral for 75% LTV
            block.timestamp + 3 days,
            keccak256("borrow1")
        );

        // Anyone can match (permissionless)
        vm.prank(SOLVER);
        bytes32 loanId = intentLending.matchIntents(
            lendIntentId,
            borrowIntentId,
            uint256(0.07e18) / 365 days, // Agreed rate in between
            10_000e18
        );

        // Verify loan created
        IIntentLending.MatchedLoan memory loan = intentLending.getLoan(loanId);
        assertTrue(loan.active, "Loan should be active");
        assertEq(loan.principal, 10_000e18, "Principal should match");
        assertEq(loan.lender, LENDER, "Lender should match");
        assertEq(loan.borrower, BORROWER, "Borrower should match");

        // Borrower should have received loan tokens
        assertEq(
            usdc.balanceOf(BORROWER),
            10_000e18,
            "Borrower should receive loan"
        );
    }

    function testCanMatchValidation() public {
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 lendIntentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(0.15e18) / 365 days, // 15% min rate
            30 days,
            collaterals,
            0.75e18,
            block.timestamp + 7 days,
            keccak256("lend2")
        );

        vm.prank(BORROWER);
        bytes32 borrowIntentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(0.05e18) / 365 days, // 5% max rate - lower than lender minimum!
            14 days,
            address(weth),
            20e18,
            block.timestamp + 3 days,
            keccak256("borrow2")
        );

        (bool valid, string memory reason) = intentLending.canMatch(
            lendIntentId,
            borrowIntentId
        );
        assertFalse(valid, "Should not be matchable");
        assertEq(reason, "Rate mismatch", "Reason should be rate mismatch");
    }

    function testRepayLoan() public {
        // Setup and match intents
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 lendIntentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(0.05e18) / 365 days,
            30 days,
            collaterals,
            0.75e18,
            block.timestamp + 7 days,
            keccak256("lend3")
        );

        vm.prank(BORROWER);
        bytes32 borrowIntentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(0.10e18) / 365 days,
            14 days,
            address(weth),
            20e18,
            block.timestamp + 3 days,
            keccak256("borrow3")
        );

        vm.prank(SOLVER);
        bytes32 loanId = intentLending.matchIntents(
            lendIntentId,
            borrowIntentId,
            uint256(0.07e18) / 365 days,
            10_000e18
        );

        // Time passes, interest accrues
        vm.warp(block.timestamp + 7 days);

        uint256 debt = intentLending.getOutstandingDebt(loanId);
        assertGt(debt, 10_000e18, "Debt should include interest");

        // Borrower repays
        usdc.setBalance(BORROWER, debt);
        vm.startPrank(BORROWER);
        usdc.approve(address(intentLending), debt);
        intentLending.repay(loanId, debt);
        vm.stopPrank();

        // Loan should be inactive
        IIntentLending.MatchedLoan memory loan = intentLending.getLoan(loanId);
        assertFalse(loan.active, "Loan should be inactive after full repay");
    }

    function testLiquidateLoan() public {
        // Setup loan with low collateral
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 lendIntentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(0.05e18) / 365 days,
            30 days,
            collaterals,
            0.90e18, // 90% LTV - tight
            block.timestamp + 7 days,
            keccak256("lend4")
        );

        vm.prank(BORROWER);
        bytes32 borrowIntentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(0.10e18) / 365 days,
            14 days,
            address(weth),
            12e18, // Just enough for 90% LTV
            block.timestamp + 3 days,
            keccak256("borrow4")
        );

        vm.prank(SOLVER);
        bytes32 loanId = intentLending.matchIntents(
            lendIntentId,
            borrowIntentId,
            uint256(0.07e18) / 365 days,
            10_000e18
        );

        // Collateral price drops
        mockOracle.setPrice(0.5e36); // 50% price drop

        uint256 health = intentLending.getLoanHealth(loanId);
        assertLt(health, 1e18, "Loan should be unhealthy");

        // Liquidate
        address LIQUIDATOR = makeAddr("Liquidator");
        uint256 debt = intentLending.getOutstandingDebt(loanId);
        usdc.setBalance(LIQUIDATOR, debt);

        vm.startPrank(LIQUIDATOR);
        usdc.approve(address(intentLending), debt);
        intentLending.liquidate(loanId);
        vm.stopPrank();

        // Liquidator should have collateral
        assertEq(
            weth.balanceOf(LIQUIDATOR),
            12e18,
            "Liquidator should receive collateral"
        );
    }

    function testCancelLendIntent() public {
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        uint256 balanceBefore = usdc.balanceOf(LENDER);

        vm.prank(LENDER);
        bytes32 intentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(0.05e18) / 365 days,
            30 days,
            collaterals,
            0.75e18,
            block.timestamp + 7 days,
            keccak256("cancel1")
        );

        assertEq(
            usdc.balanceOf(LENDER),
            balanceBefore - 100_000e18,
            "Tokens should be escrowed"
        );

        vm.prank(LENDER);
        intentLending.cancelLendIntent(intentId);

        assertEq(
            usdc.balanceOf(LENDER),
            balanceBefore,
            "Tokens should be returned"
        );
        assertFalse(
            intentLending.isLendIntentFillable(intentId),
            "Intent should not be fillable"
        );
    }

    function testCancelBorrowIntent() public {
        uint256 balanceBefore = weth.balanceOf(BORROWER);

        vm.prank(BORROWER);
        bytes32 intentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(0.10e18) / 365 days,
            14 days,
            address(weth),
            10e18,
            block.timestamp + 3 days,
            keccak256("cancel2")
        );

        assertEq(
            weth.balanceOf(BORROWER),
            balanceBefore - 10e18,
            "Collateral should be escrowed"
        );

        vm.prank(BORROWER);
        intentLending.cancelBorrowIntent(intentId);

        assertEq(
            weth.balanceOf(BORROWER),
            balanceBefore,
            "Collateral should be returned"
        );
        assertFalse(
            intentLending.isBorrowIntentFillable(intentId),
            "Intent should not be fillable"
        );
    }

    function testExpiredIntentCannotBeMatched() public {
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(weth);

        vm.prank(LENDER);
        bytes32 lendIntentId = intentLending.createLendIntent(
            address(usdc),
            100_000e18,
            10_000e18,
            uint256(5e16) / 365 days,
            30 days,
            collaterals,
            0.75e18,
            block.timestamp + 1 days, // Expires in 1 day
            keccak256("expire1")
        );

        vm.prank(BORROWER);
        bytes32 borrowIntentId = intentLending.createBorrowIntent(
            address(usdc),
            10_000e18,
            uint256(1e17) / 365 days,
            14 days,
            address(weth),
            20e18,
            block.timestamp + 3 days,
            keccak256("expire2")
        );

        // Fast forward past expiry
        vm.warp(block.timestamp + 2 days);

        vm.prank(SOLVER);
        vm.expectRevert(IIntentLending.IntentExpired.selector);
        intentLending.matchIntents(
            lendIntentId,
            borrowIntentId,
            uint256(7e16) / 365 days,
            10_000e18
        );
    }
}
