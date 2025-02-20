// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/**
 * @title GMXIntents
 * @notice An intent engine for bridging assets across chains for GMX perpetual vaults.
 * It supports deposit, withdrawal and abort flows with deterministic state transitions.
 */
contract GMXIntents is Ownable {
    // State definitions:
    // None: No intent created.
    // Active: Intent created and awaiting work.
    // RequestedAbort: User has initiated an abort request.
    // Aborted: Abort confirmed (funds returned to user).
    // Fulfilled: Solver has executed the required off–chain action.
    // Settled: Final settlement completed (fee processed, funds transferred).
    // Deleted: Terminal intents that have been garbage–collected.
    enum State { None, Active, RequestedAbort, Aborted, Fulfilled, Settled, Deleted }
    
    // Two intent types: Deposit (user deposits funds) and Withdraw (withdraw requests from GMX).
    enum IntentType { Deposit, Withdraw }

    struct Intent {
        address user;       // For deposit: originating user; for withdraw: beneficiary.
        address token;
        uint256 amount;
        State state;
        IntentType intentType;
        uint256 fee;        // Fee in basis points, e.g. 50 = 0.5%.
    }

    mapping(uint256 => Intent) public intents;
    uint256 public intentCount;
    mapping(address => bool) public approvedSolvers;
    uint256 public globalFee;       // Global fee in basis points.
    address public vaultAddress;    // For deposits: the GMX vault address (set by the owner).

    /* ========== EVENTS ========== */
    event IntentCreated(
        uint256 indexed intentId,
        address indexed user,
        address indexed token,
        uint256 amount,
        IntentType intentType
    );
    event IntentFulfilled(uint256 indexed intentId, IntentType intentType);
    event IntentSettled(uint256 indexed intentId, IntentType intentType);
    event IntentAborted(uint256 indexed intentId);
    event IntentDeleted(uint256 indexed intentId);
    event AbortRejected(uint256 indexed intentId);
    event SolverApproved(address indexed solver, bool approved);
    event VaultAddressUpdated(address vaultAddress);

    /* ========== MODIFIERS ========== */
    modifier onlySolver() {
        require(approvedSolvers[msg.sender], "Not an approved solver");
        _;
    }

    /* ========== ADMIN FUNCTIONS ========== */
    /// @notice Set the GMX vault address (only used for deposit flows).
    function setVaultAddress(address _vaultAddress) external onlyOwner {
        require(_vaultAddress != address(0), "Invalid vault address");
        vaultAddress = _vaultAddress;
        emit VaultAddressUpdated(_vaultAddress);
    }

    constructor(uint256 _globalFee) {
        globalFee = _globalFee;
    }

    /* ========== DEPOSIT FLOW ========== */
    /**
     * @notice Create a deposit intent.
     * @dev This function uses the ERC20Permit interface to allow a gasless token transfer.
     * @param token The token address to deposit.
     * @param amount The amount to deposit.
     * @param deadline The permit deadline.
     * @param v Permit signature parameter.
     * @param r Permit signature parameter.
     * @param s Permit signature parameter.
     */
    function createDepositIntent(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // Allow gasless approval via permit.
        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
        // Transfer tokens from the user to this contract.
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        // Create an intent of type Deposit in Active state.
        intents[intentCount] = Intent({
            user: msg.sender,
            token: token,
            amount: amount,
            state: State.Active,
            intentType: IntentType.Deposit,
            fee: globalFee
        });
        emit IntentCreated(intentCount, msg.sender, token, amount, IntentType.Deposit);
        intentCount++;
    }

    /* ========== WITHDRAW FLOW ========== */
    /**
     * @notice Create a withdraw intent.
     * @dev In production, GMX (or a relayer using ERC2771) would call this function.
     * @param token The token to be withdrawn.
     * @param amount The amount to withdraw.
     * @param user The beneficiary address.
     */
    function createWithdrawIntent(
        address token,
        uint256 amount,
        address user
    ) external {
        // Transfer tokens from the initiator (e.g. GMX vault/relayer) to this contract.
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        // Create an intent of type Withdraw in Active state.
        intents[intentCount] = Intent({
            user: user,
            token: token,
            amount: amount,
            state: State.Active,
            intentType: IntentType.Withdraw,
            fee: globalFee
        });
        emit IntentCreated(intentCount, user, token, amount, IntentType.Withdraw);
        intentCount++;
    }

    /* ========== FULFILLMENT (Solver Action) ========== */
    /**
     * @notice Register that an intent has been fulfilled (i.e. off–chain action executed).
     * @dev For a deposit, this means the vault on the protocol chain has been funded.
     * For a withdrawal, this means funds have been sent to the user.
     * @param intentId The ID of the intent.
     */
    function registerIntent(uint256 intentId) external onlySolver {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Active, "Intent not active");
        intent.state = State.Fulfilled;
        emit IntentFulfilled(intentId, intent.intentType);
    }

    /* ========== SETTLEMENT (Solver Finalizes & Claims Fee) ========== */
    /**
     * @notice Settle an intent after remote batch processing or CCIP message handling.
     * @dev For deposits, fees are deducted and the net amount is forwarded to the vault.
     * For withdrawals, fees are deducted and the net amount is sent to the user.
     * @param intentId The ID of the intent.
     */
    function settleIntent(uint256 intentId) external onlySolver {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Fulfilled, "Intent not fulfilled");
        intent.state = State.Settled;
        emit IntentSettled(intentId, intent.intentType);

        uint256 solverFee = (intent.amount * intent.fee) / 10000;
        uint256 netAmount = intent.amount - solverFee;

        if (intent.intentType == IntentType.Deposit) {
            require(vaultAddress != address(0), "Vault address not set");
            // Transfer the solver's fee.
            IERC20(intent.token).transfer(msg.sender, solverFee);
            // Forward the remainder to the GMX vault.
            IERC20(intent.token).transfer(vaultAddress, netAmount);
        } else if (intent.intentType == IntentType.Withdraw) {
            // Transfer the solver fee.
            IERC20(intent.token).transfer(msg.sender, solverFee);
            // Deliver the net amount to the user.
            IERC20(intent.token).transfer(intent.user, netAmount);
        }
    }

    /* ========== ABORT FLOW ========== */
    /**
     * @notice Request an abort for an active intent.
     * @dev Can only be called by the originating user.
     * @param intentId The ID of the intent.
     */
    function requestAbort(uint256 intentId) external {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Active, "Intent not active");
        require(intent.user == msg.sender, "Not intent owner");
        intent.state = State.RequestedAbort;
    }

    /**
     * @notice Finalize the abort.
     * @dev Returns tokens to the user.
     * @param intentId The ID of the intent.
     */
    function abortIntent(uint256 intentId) external {
        Intent storage intent = intents[intentId];
        require(intent.state == State.RequestedAbort, "Abort not requested");
        intent.state = State.Aborted;
        IERC20(intent.token).transfer(intent.user, intent.amount);
        emit IntentAborted(intentId);
    }

    /**
     * @notice Reject an abort request.
     * @dev This function is intended for scenarios where an abort is rejected (e.g. extent already fulfilled).
     * @param intentId The ID of the intent.
     */
    function rejectAbort(uint256 intentId) external onlySolver {
        Intent storage intent = intents[intentId];
        require(intent.state == State.RequestedAbort, "Not in abort requested state");
        intent.state = State.Fulfilled;
        emit AbortRejected(intentId);
    }

    /* ========== GARBAGE COLLECTION ========== */
    /**
     * @notice Garbage collect finished intents (Settled or Aborted) by marking them as Deleted.
     * @param intentIds An array of intent IDs to be cleaned up.
     */
    function garbageCollect(uint256[] calldata intentIds) external onlyOwner {
        for (uint256 i = 0; i < intentIds.length; i++) {
            uint256 id = intentIds[i];
            Intent storage intent = intents[id];
            if (intent.state == State.Settled || intent.state == State.Aborted) {
                intent.state = State.Deleted;
                emit IntentDeleted(id);
            }
        }
    }

    /* ========== SOLVER MANAGEMENT ========== */
    /**
     * @notice Approve a solver.
     * @param solver The address to approve.
     */
    function approveSolver(address solver) external onlyOwner {
        approvedSolvers[solver] = true;
        emit SolverApproved(solver, true);
    }

    /**
     * @notice Revoke a solver.
     * @param solver The solver address to revoke.
     */
    function revokeSolver(address solver) external onlyOwner {
        approvedSolvers[solver] = false;
        emit SolverApproved(solver, false);
    }
}