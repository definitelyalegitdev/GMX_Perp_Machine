// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract PerpEngine {
    // State definitions:
    // Indexes: 0: None, 1: Active, 2: RequestedAbort, 3: Aborted, 4: Fulfilled, 5: Settled, 6: Deleted
    enum State { None, Active, RequestedAbort, Aborted, Fulfilled, Settled, Deleted }

    struct Intent {
        address user;
        address token;
        uint256 amount;
        State state;
        uint256 fee; // fee in basis points (e.g. 50 = 0.5%)
    }

    mapping(uint256 => Intent) public intents;
    uint256 public intentCount;
    address public owner;
    mapping(address => bool) public approvedSolvers;
    uint256 public globalFee;

    event IntentCreated(uint256 intentId, address indexed user, address indexed token, uint256 amount);
    event IntentFulfilled(uint256 intentId);
    event IntentSettled(uint256 intentId);
    event IntentAborted(uint256 intentId);
    event IntentDeleted(uint256 intentId);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlySolver() {
        require(approvedSolvers[msg.sender], "Not an approved solver");
        _;
    }

    constructor(uint256 _globalFee) {
        owner = msg.sender;
        globalFee = _globalFee;
    }

    // -----------------------------------------------------------------------
    // Deposit Flow
    // 1. User sends tokens to engine source side via createIntent,
    //    using an ERC20 permit for gasless approval.
    // 2. Solver transfers funds into the GMX vault and calls registerDeposit().
    // 3. Later the solver calls settle() to trigger the CCIP settlement.
    // -----------------------------------------------------------------------
    function createIntent(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        // Use ERC20Permit to get allowance
        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
        // Transfer tokens into the engine contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        intents[intentCount] = Intent(msg.sender, token, amount, State.Active, globalFee);
        emit IntentCreated(intentCount, msg.sender, token, amount);
        intentCount++;
    }

    // Called by an approved solver to register that funds have been deposited into GMX vault.
    function registerDeposit(uint256 intentId) public onlySolver {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Active, "Intent not active");
        // Additional logic to transfer funds to the GMX vault can be placed here.
        intent.state = State.Fulfilled;
        emit IntentFulfilled(intentId);
    }

    // Called by an approved solver to settle an intent:
    // Uses CCIP to settle (full details on CCIP message sending omitted) and repays solver fees.
    function settle(uint256 intentId) public onlySolver {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Fulfilled, "Intent not fulfilled");
        // Initiate CCIP settlement (details omitted)
        intent.state = State.Settled;
        emit IntentSettled(intentId);
        // Repay solver and send remainder to user.
        uint256 solverFee = (intent.amount * intent.fee) / 10000; // fee is in basis points
        IERC20(intent.token).transfer(msg.sender, solverFee);
        IERC20(intent.token).transfer(intent.user, intent.amount - solverFee);
    }

    // -----------------------------------------------------------------------
    // Withdraw Flow (Stub)
    // - GMX (using ERC-2771) sends tokens to PerpEngine and requests a withdrawal.
    // - Solver sees request and sends withdrawn funds to the user.
    // -----------------------------------------------------------------------
    function requestWithdraw(uint256 intentId) public {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Active, "Intent not active");
        // Withdrawal implementation logic would go here.
    }

    // -----------------------------------------------------------------------
    // Exception Flow (Abort)
    // 1. User sends an abort request to the engine.
    // 2. The engine sends an abort message to the counterpart chain.
    // 3. The remote chain confirms and an ACK is sent back.
    // 4. On receipt, the funds are returned to the user.
    // -----------------------------------------------------------------------
    function requestAbort(uint256 intentId) public {
        Intent storage intent = intents[intentId];
        require(intent.state == State.Active, "Intent not active");
        intent.state = State.RequestedAbort;
        // Additional abort logic can be added here.
    }

    function abortIntent(uint256 intentId) public {
        Intent storage intent = intents[intentId];
        require(intent.state == State.RequestedAbort, "Abort not requested");
        intent.state = State.Aborted;
        emit IntentAborted(intentId);
        // Return funds back to the user.
        IERC20(intent.token).transfer(intent.user, intent.amount);
    }

    // -----------------------------------------------------------------------
    // Solver Management
    // The owner manages the whitelist of approved solvers.
    // -----------------------------------------------------------------------
    function approveSolver(address solver) public onlyOwner {
        approvedSolvers[solver] = true;
    }

    function revokeSolver(address solver) public onlyOwner {
        approvedSolvers[solver] = false;
    }

    // -----------------------------------------------------------------------
    // Garbage Collection
    // Marks intents in terminal states (Settled or Aborted) as Deleted.
    // This avoids costly storage and keeps state transitions deterministic.
    // -----------------------------------------------------------------------
    function garbageCollect(uint256[] memory intentIds) public onlyOwner {
        for (uint256 i = 0; i < intentIds.length; i++) {
            uint256 intentId = intentIds[i];
            Intent storage intent = intents[intentId];
            if (intent.state == State.Settled || intent.state == State.Aborted) {
                intent.state = State.Deleted;
                emit IntentDeleted(intentId);
            }
        }
    }
} 