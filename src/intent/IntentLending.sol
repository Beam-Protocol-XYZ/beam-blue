// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IIntentLending} from "../interfaces/IIntentLending.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";

/// @title IntentLending
/// @notice Intent-based lending for institutional lenders and borrowers
/// @dev On-chain permissionless matching - anyone can call matchIntents if conditions are met
contract IntentLending is IIntentLending {
    using SafeTransferLib for IERC20;
    using MathLib for uint256;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18; // Health factor = 1.0
    uint256 public constant LIQUIDATION_INCENTIVE = 1.05e18; // 5% bonus

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public owner;
    bool public paused;
    uint256 private _locked = 1;

    // Intent storage
    mapping(bytes32 => LendIntent) private _lendIntents;
    mapping(bytes32 => BorrowIntent) private _borrowIntents;
    mapping(bytes32 => MatchedLoan) private _loans;

    // User tracking
    mapping(address => bytes32[]) public userLendIntents;
    mapping(address => bytes32[]) public userBorrowIntents;
    mapping(address => bytes32[]) public userLoans;

    // Collateral oracles (collateralToken => loanToken => oracle)
    mapping(address => mapping(address => address)) public oracles;

    // Nonces for unique IDs
    uint256 private _intentNonce;
    uint256 private _loanNonce;

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 2) revert UnauthorizedCaller(); // Reusing error
        _locked = 2;
        _;
        _locked = 1;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @notice Set oracle for collateral/loan token pair
    function setOracle(
        address collateralToken,
        address loanToken,
        address oracle
    ) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        oracles[collateralToken][loanToken] = oracle;
    }

    /* ═══════════════════════════════════════════ LENDER FUNCTIONS ═══════════════════════════════════════════ */

    /// @inheritdoc IIntentLending
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
    ) external whenNotPaused returns (bytes32 intentId) {
        if (loanToken == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (minAmount > amount) revert AmountTooSmall();
        if (maxDuration < MIN_DURATION || maxDuration > MAX_DURATION)
            revert InvalidDuration();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (acceptedCollaterals.length == 0) revert InsufficientCollateral();

        // Transfer loan tokens to contract (escrow)
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);

        // Generate intent ID
        intentId = keccak256(
            abi.encodePacked(
                msg.sender,
                loanToken,
                amount,
                salt,
                _intentNonce++
            )
        );

        // Store intent
        LendIntent storage intent = _lendIntents[intentId];
        intent.lender = msg.sender;
        intent.loanToken = loanToken;
        intent.amount = amount;
        intent.filledAmount = 0;
        intent.minAmount = minAmount;
        intent.minRate = minRate;
        intent.maxDuration = maxDuration;
        intent.acceptedCollaterals = acceptedCollaterals;
        intent.requiredLTV = requiredLTV;
        intent.expiry = expiry;
        intent.salt = salt;
        intent.active = true;

        userLendIntents[msg.sender].push(intentId);

        emit LendIntentCreated(
            intentId,
            msg.sender,
            loanToken,
            amount,
            minRate,
            expiry
        );
    }

    /// @inheritdoc IIntentLending
    function cancelLendIntent(bytes32 intentId) external nonReentrant {
        LendIntent storage intent = _lendIntents[intentId];
        if (intent.lender != msg.sender) revert UnauthorizedCaller();
        if (!intent.active) revert IntentNotActive();

        intent.active = false;

        // Return unfilled amount
        uint256 remaining = intent.amount - intent.filledAmount;
        if (remaining > 0) {
            IERC20(intent.loanToken).safeTransfer(msg.sender, remaining);
        }

        emit IntentCancelled(intentId, msg.sender);
    }

    /* ═══════════════════════════════════════════ BORROWER FUNCTIONS ═══════════════════════════════════════════ */

    /// @inheritdoc IIntentLending
    function createBorrowIntent(
        address loanToken,
        uint256 amount,
        uint256 maxRate,
        uint256 duration,
        address collateralToken,
        uint256 collateralAmount,
        uint256 expiry,
        bytes32 salt
    ) external whenNotPaused returns (bytes32 intentId) {
        if (loanToken == address(0) || collateralToken == address(0))
            revert ZeroAddress();
        if (amount == 0 || collateralAmount == 0) revert ZeroAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION)
            revert InvalidDuration();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        // Transfer collateral to contract (escrow)
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        // Generate intent ID
        intentId = keccak256(
            abi.encodePacked(
                msg.sender,
                loanToken,
                collateralToken,
                amount,
                salt,
                _intentNonce++
            )
        );

        // Store intent
        BorrowIntent storage intent = _borrowIntents[intentId];
        intent.borrower = msg.sender;
        intent.loanToken = loanToken;
        intent.amount = amount;
        intent.maxRate = maxRate;
        intent.duration = duration;
        intent.collateralToken = collateralToken;
        intent.collateralAmount = collateralAmount;
        intent.expiry = expiry;
        intent.salt = salt;
        intent.active = true;

        userBorrowIntents[msg.sender].push(intentId);

        emit BorrowIntentCreated(
            intentId,
            msg.sender,
            loanToken,
            amount,
            maxRate,
            expiry
        );
    }

    /// @inheritdoc IIntentLending
    function cancelBorrowIntent(bytes32 intentId) external nonReentrant {
        BorrowIntent storage intent = _borrowIntents[intentId];
        if (intent.borrower != msg.sender) revert UnauthorizedCaller();
        if (!intent.active) revert IntentNotActive();

        intent.active = false;

        // Return collateral
        IERC20(intent.collateralToken).safeTransfer(
            msg.sender,
            intent.collateralAmount
        );

        emit IntentCancelled(intentId, msg.sender);
    }

    /* ═══════════════════════════════════════════ MATCHING ═══════════════════════════════════════════ */

    /// @inheritdoc IIntentLending
    function matchIntents(
        bytes32 lendIntentId,
        bytes32 borrowIntentId,
        uint256 agreedRate,
        uint256 loanAmount
    ) external whenNotPaused nonReentrant returns (bytes32 loanId) {
        LendIntent storage lendIntent = _lendIntents[lendIntentId];
        BorrowIntent storage borrowIntent = _borrowIntents[borrowIntentId];

        // Validate intents are active
        if (!lendIntent.active) revert IntentNotActive();
        if (!borrowIntent.active) revert IntentNotActive();

        // Validate not expired
        if (block.timestamp >= lendIntent.expiry) revert IntentExpired();
        if (block.timestamp >= borrowIntent.expiry) revert IntentExpired();

        // Validate same loan token
        if (lendIntent.loanToken != borrowIntent.loanToken)
            revert CollateralNotAccepted();

        // Validate rate is acceptable to both
        if (agreedRate < lendIntent.minRate) revert RateMismatch();
        if (agreedRate > borrowIntent.maxRate) revert RateMismatch();

        // Validate duration
        if (borrowIntent.duration > lendIntent.maxDuration)
            revert InvalidDuration();

        // Validate loan amount
        uint256 lenderRemaining = lendIntent.amount - lendIntent.filledAmount;
        if (loanAmount > lenderRemaining) revert AmountTooSmall();
        if (loanAmount != borrowIntent.amount) revert AmountMismatch();
        if (loanAmount < lendIntent.minAmount) revert AmountTooSmall();

        // Validate collateral is accepted
        bool collateralAccepted = false;
        for (uint256 i = 0; i < lendIntent.acceptedCollaterals.length; i++) {
            if (
                lendIntent.acceptedCollaterals[i] ==
                borrowIntent.collateralToken
            ) {
                collateralAccepted = true;
                break;
            }
        }
        if (!collateralAccepted) revert CollateralNotAccepted();

        // Validate LTV
        uint256 collateralValue = _getCollateralValue(
            borrowIntent.collateralToken,
            borrowIntent.loanToken,
            borrowIntent.collateralAmount
        );
        uint256 requiredCollateral = (loanAmount * 1e18) /
            lendIntent.requiredLTV;
        if (collateralValue < requiredCollateral)
            revert InsufficientCollateral();

        // Create loan
        loanId = keccak256(
            abi.encodePacked(
                lendIntentId,
                borrowIntentId,
                loanAmount,
                _loanNonce++
            )
        );

        MatchedLoan storage loan = _loans[loanId];
        loan.lendIntentId = lendIntentId;
        loan.borrowIntentId = borrowIntentId;
        loan.lender = lendIntent.lender;
        loan.borrower = borrowIntent.borrower;
        loan.loanToken = lendIntent.loanToken;
        loan.collateralToken = borrowIntent.collateralToken;
        loan.principal = loanAmount;
        loan.collateralAmount = borrowIntent.collateralAmount;
        loan.rate = agreedRate;
        loan.startTime = block.timestamp;
        loan.endTime = block.timestamp + borrowIntent.duration;
        loan.repaidAmount = 0;
        loan.active = true;

        // Update intent fill amounts
        lendIntent.filledAmount += loanAmount;
        if (lendIntent.filledAmount >= lendIntent.amount) {
            lendIntent.active = false;
        }
        borrowIntent.active = false; // Borrow intent is fully consumed

        // Track loan for users
        userLoans[lendIntent.lender].push(loanId);
        userLoans[borrowIntent.borrower].push(loanId);

        // Transfer loan tokens to borrower
        IERC20(lendIntent.loanToken).safeTransfer(
            borrowIntent.borrower,
            loanAmount
        );

        emit IntentsMatched(
            loanId,
            lendIntentId,
            borrowIntentId,
            loanAmount,
            agreedRate
        );
    }

    /// @inheritdoc IIntentLending
    function canMatch(
        bytes32 lendIntentId,
        bytes32 borrowIntentId
    ) external view returns (bool valid, string memory reason) {
        LendIntent storage lendIntent = _lendIntents[lendIntentId];
        BorrowIntent storage borrowIntent = _borrowIntents[borrowIntentId];

        if (!lendIntent.active) return (false, "Lend intent not active");
        if (!borrowIntent.active) return (false, "Borrow intent not active");
        if (block.timestamp >= lendIntent.expiry)
            return (false, "Lend intent expired");
        if (block.timestamp >= borrowIntent.expiry)
            return (false, "Borrow intent expired");
        if (lendIntent.loanToken != borrowIntent.loanToken)
            return (false, "Token mismatch");
        if (lendIntent.minRate > borrowIntent.maxRate)
            return (false, "Rate mismatch");
        if (borrowIntent.duration > lendIntent.maxDuration)
            return (false, "Duration exceeds max");

        // Check collateral acceptance
        bool accepted = false;
        for (uint256 i = 0; i < lendIntent.acceptedCollaterals.length; i++) {
            if (
                lendIntent.acceptedCollaterals[i] ==
                borrowIntent.collateralToken
            ) {
                accepted = true;
                break;
            }
        }
        if (!accepted) return (false, "Collateral not accepted");

        return (true, "");
    }

    /* ═══════════════════════════════════════════ LOAN MANAGEMENT ═══════════════════════════════════════════ */

    /// @inheritdoc IIntentLending
    function repay(bytes32 loanId, uint256 amount) external nonReentrant {
        MatchedLoan storage loan = _loans[loanId];
        if (!loan.active) revert LoanNotActive();
        if (amount == 0) revert ZeroAmount();

        uint256 outstanding = getOutstandingDebt(loanId);
        uint256 repayAmount = amount > outstanding ? outstanding : amount;

        // Transfer repayment
        IERC20(loan.loanToken).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmount
        );

        loan.repaidAmount += repayAmount;

        // If fully repaid, transfer funds to lender
        if (loan.repaidAmount >= outstanding) {
            IERC20(loan.loanToken).safeTransfer(loan.lender, loan.repaidAmount);
            loan.active = false;
        }

        emit LoanRepaid(
            loanId,
            msg.sender,
            repayAmount,
            outstanding - repayAmount
        );
    }

    /// @inheritdoc IIntentLending
    function liquidate(bytes32 loanId) external nonReentrant {
        MatchedLoan storage loan = _loans[loanId];
        if (!loan.active) revert LoanNotActive();

        uint256 health = getLoanHealth(loanId);
        bool isExpired = block.timestamp > loan.endTime;

        if (health >= LIQUIDATION_THRESHOLD && !isExpired) revert LoanHealthy();

        uint256 debt = getOutstandingDebt(loanId);

        // Liquidator pays debt
        IERC20(loan.loanToken).safeTransferFrom(msg.sender, loan.lender, debt);

        // Liquidator receives collateral with bonus
        address oracle = oracles[loan.collateralToken][loan.loanToken];
        if (oracle == address(0)) revert ZeroAddress();

        uint256 price = IOracle(oracle).price();
        uint256 valueToSeize = (debt * LIQUIDATION_INCENTIVE) / 1e18;
        uint256 collateralToSeize = (valueToSeize * ORACLE_PRICE_SCALE) / price;

        if (collateralToSeize > loan.collateralAmount) {
            collateralToSeize = loan.collateralAmount;
        }

        loan.collateralAmount -= collateralToSeize;

        IERC20(loan.collateralToken).safeTransfer(
            msg.sender,
            collateralToSeize
        );

        loan.active = false;
        loan.repaidAmount = debt;

        emit LoanLiquidated(loanId, msg.sender, debt, collateralToSeize);
    }

    /// @inheritdoc IIntentLending
    function claimCollateral(bytes32 loanId) external nonReentrant {
        MatchedLoan storage loan = _loans[loanId];
        if (loan.borrower != msg.sender) revert UnauthorizedCaller();
        if (loan.active) revert LoanNotActive(); // Must be fully repaid

        uint256 outstanding = getOutstandingDebt(loanId);
        if (loan.repaidAmount < outstanding) revert LoanNotActive();

        uint256 amountToClaim = loan.collateralAmount;
        if (amountToClaim == 0) revert ZeroAmount();

        loan.collateralAmount = 0;

        // Return collateral to borrower
        IERC20(loan.collateralToken).safeTransfer(msg.sender, amountToClaim);

        emit CollateralClaimed(loanId, msg.sender, amountToClaim);
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @inheritdoc IIntentLending
    function getLoanHealth(
        bytes32 loanId
    ) public view returns (uint256 health) {
        MatchedLoan storage loan = _loans[loanId];
        if (!loan.active) return 0;

        uint256 collateralValue = _getCollateralValue(
            loan.collateralToken,
            loan.loanToken,
            loan.collateralAmount
        );
        uint256 debt = getOutstandingDebt(loanId);

        if (debt == 0) return type(uint256).max;
        health = (collateralValue * 1e18) / debt;
    }

    /// @inheritdoc IIntentLending
    function getOutstandingDebt(
        bytes32 loanId
    ) public view returns (uint256 debt) {
        MatchedLoan storage loan = _loans[loanId];
        if (!loan.active) return 0;

        // Calculate accrued interest
        uint256 elapsed = block.timestamp - loan.startTime;
        uint256 interest = loan.principal.wMulDown(loan.rate * elapsed);

        debt = loan.principal + interest - loan.repaidAmount;
    }

    /// @inheritdoc IIntentLending
    function isLendIntentFillable(
        bytes32 intentId
    ) external view returns (bool) {
        LendIntent storage intent = _lendIntents[intentId];
        return
            intent.active &&
            block.timestamp < intent.expiry &&
            intent.filledAmount < intent.amount;
    }

    /// @inheritdoc IIntentLending
    function isBorrowIntentFillable(
        bytes32 intentId
    ) external view returns (bool) {
        BorrowIntent storage intent = _borrowIntents[intentId];
        return intent.active && block.timestamp < intent.expiry;
    }

    /// @notice Get lend intent details
    function getLendIntent(
        bytes32 intentId
    ) external view returns (LendIntent memory) {
        return _lendIntents[intentId];
    }

    /// @notice Get borrow intent details
    function getBorrowIntent(
        bytes32 intentId
    ) external view returns (BorrowIntent memory) {
        return _borrowIntents[intentId];
    }

    /// @notice Get loan details
    function getLoan(
        bytes32 loanId
    ) external view returns (MatchedLoan memory) {
        return _loans[loanId];
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Get collateral value in loan token terms
    function _getCollateralValue(
        address collateralToken,
        address loanToken,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        address oracle = oracles[collateralToken][loanToken];
        if (oracle == address(0)) return 0;

        uint256 price = IOracle(oracle).price();
        return (collateralAmount * price) / ORACLE_PRICE_SCALE;
    }
}
