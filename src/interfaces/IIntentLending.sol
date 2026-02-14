// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

/// @title IIntentLending
/// @notice Interface for intent-based lending protocol
/// @dev Enables institutional lenders and borrowers to declare intents matched on-chain
interface IIntentLending {
    /* ═══════════════════════════════════════════ STRUCTS ═══════════════════════════════════════════ */

    struct LendIntent {
        address lender;
        address loanToken;
        uint256 amount; // Max amount willing to lend
        uint256 filledAmount; // Amount already matched
        uint256 minAmount; // Minimum partial fill
        uint256 minRate; // Minimum interest rate (WAD per second)
        uint256 maxDuration; // Maximum loan duration in seconds
        address[] acceptedCollaterals; // Whitelist of collateral tokens
        uint256 requiredLTV; // Required loan-to-value (WAD scale)
        uint256 expiry; // Intent expiration timestamp
        bytes32 salt; // For unique intent IDs
        bool active;
    }

    struct BorrowIntent {
        address borrower;
        address loanToken;
        uint256 amount; // Desired borrow amount
        uint256 maxRate; // Maximum acceptable rate (WAD per second)
        uint256 duration; // Desired loan duration in seconds
        address collateralToken; // Collateral offered
        uint256 collateralAmount; // Collateral amount
        uint256 expiry; // Intent expiration timestamp
        bytes32 salt;
        bool active;
    }

    struct MatchedLoan {
        bytes32 lendIntentId;
        bytes32 borrowIntentId;
        address lender;
        address borrower;
        address loanToken;
        address collateralToken;
        uint256 principal;
        uint256 collateralAmount;
        uint256 rate; // Agreed interest rate
        uint256 startTime;
        uint256 endTime;
        uint256 repaidAmount;
        bool active;
    }

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event LendIntentCreated(
        bytes32 indexed intentId,
        address indexed lender,
        address indexed loanToken,
        uint256 amount,
        uint256 minRate,
        uint256 expiry
    );

    event BorrowIntentCreated(
        bytes32 indexed intentId,
        address indexed borrower,
        address indexed loanToken,
        uint256 amount,
        uint256 maxRate,
        uint256 expiry
    );

    event IntentCancelled(bytes32 indexed intentId, address indexed user);

    event IntentsMatched(
        bytes32 indexed loanId,
        bytes32 indexed lendIntentId,
        bytes32 indexed borrowIntentId,
        uint256 principal,
        uint256 rate
    );

    event LoanRepaid(
        bytes32 indexed loanId,
        address indexed repayer,
        uint256 amount,
        uint256 remaining
    );

    event LoanLiquidated(
        bytes32 indexed loanId,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    event CollateralClaimed(
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 amount
    );

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRate();
    error InvalidDuration();
    error InvalidExpiry();
    error IntentNotActive();
    error IntentExpired();
    error InsufficientCollateral();
    error RateMismatch();
    error CollateralNotAccepted();
    error AmountTooSmall();
    error LoanNotActive();
    error LoanNotExpired();
    error LoanHealthy();
    error UnauthorizedCaller();
    error Paused();

    /* ═══════════════════════════════════════════ LENDER FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Create a lending intent
    /// @param loanToken Token to lend
    /// @param amount Maximum amount to lend
    /// @param minAmount Minimum partial fill amount
    /// @param minRate Minimum acceptable interest rate (WAD per second)
    /// @param maxDuration Maximum loan duration
    /// @param acceptedCollaterals Array of accepted collateral tokens
    /// @param requiredLTV Required loan-to-value ratio
    /// @param expiry Intent expiration timestamp
    /// @param salt Unique salt for intent ID
    /// @return intentId Unique identifier for the intent
    function createLendIntent(
        address loanToken,
        uint256 amount,
        uint256 minAmount,
        uint256 minRate,
        uint256 maxDuration,
        address[] calldata acceptedCollaterals,
        uint256 requiredLTV,
        uint256 expiry,
        bytes32 salt
    ) external returns (bytes32 intentId);

    /// @notice Cancel an active lend intent
    /// @param intentId The intent to cancel
    function cancelLendIntent(bytes32 intentId) external;

    /* ═══════════════════════════════════════════ BORROWER FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Create a borrowing intent
    /// @param loanToken Token to borrow
    /// @param amount Amount to borrow
    /// @param maxRate Maximum acceptable interest rate
    /// @param duration Desired loan duration
    /// @param collateralToken Collateral token offered
    /// @param collateralAmount Amount of collateral
    /// @param expiry Intent expiration timestamp
    /// @param salt Unique salt for intent ID
    /// @return intentId Unique identifier for the intent
    function createBorrowIntent(
        address loanToken,
        uint256 amount,
        uint256 maxRate,
        uint256 duration,
        address collateralToken,
        uint256 collateralAmount,
        uint256 expiry,
        bytes32 salt
    ) external returns (bytes32 intentId);

    /// @notice Cancel an active borrow intent
    /// @param intentId The intent to cancel
    function cancelBorrowIntent(bytes32 intentId) external;

    /* ═══════════════════════════════════════════ MATCHING ═══════════════════════════════════════════ */

    /// @notice Match a lend intent with a borrow intent (permissionless)
    /// @param lendIntentId The lending intent
    /// @param borrowIntentId The borrowing intent
    /// @param agreedRate The agreed interest rate (must be within both intents' bounds)
    /// @param loanAmount The amount to match (partial fill supported)
    /// @return loanId Unique identifier for the matched loan
    function matchIntents(
        bytes32 lendIntentId,
        bytes32 borrowIntentId,
        uint256 agreedRate,
        uint256 loanAmount
    ) external returns (bytes32 loanId);

    /// @notice Check if two intents can be matched
    /// @param lendIntentId The lending intent
    /// @param borrowIntentId The borrowing intent
    /// @return valid True if intents can be matched
    /// @return reason Reason if not matchable
    function canMatch(
        bytes32 lendIntentId,
        bytes32 borrowIntentId
    ) external view returns (bool valid, string memory reason);

    /* ═══════════════════════════════════════════ LOAN MANAGEMENT ═══════════════════════════════════════════ */

    /// @notice Repay a loan (partial or full)
    /// @param loanId The loan to repay
    /// @param amount Amount to repay
    function repay(bytes32 loanId, uint256 amount) external;

    /// @notice Liquidate an unhealthy or expired loan
    /// @param loanId The loan to liquidate
    function liquidate(bytes32 loanId) external;

    /// @notice Borrower claims collateral after full repayment
    /// @param loanId The fully repaid loan
    function claimCollateral(bytes32 loanId) external;

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Get loan health factor (1e18 = healthy threshold)
    /// @param loanId The loan to check
    /// @return health Health factor (>1e18 is healthy)
    function getLoanHealth(
        bytes32 loanId
    ) external view returns (uint256 health);

    /// @notice Get outstanding debt including accrued interest
    /// @param loanId The loan to check
    /// @return debt Total outstanding debt
    function getOutstandingDebt(
        bytes32 loanId
    ) external view returns (uint256 debt);

    /// @notice Check if lend intent is fillable
    /// @param intentId The intent to check
    /// @return fillable True if intent can be matched
    function isLendIntentFillable(
        bytes32 intentId
    ) external view returns (bool fillable);

    /// @notice Check if borrow intent is fillable
    /// @param intentId The intent to check
    /// @return fillable True if intent can be matched
    function isBorrowIntentFillable(
        bytes32 intentId
    ) external view returns (bool fillable);
}
