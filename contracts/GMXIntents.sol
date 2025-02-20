// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

library CrossChainPerpTypes {
    enum OrderStatus { None, Active, Fulfilled, Settled, RequestedCancel, Cancelled }
    enum MessageType { ORDER, SETTLEMENT, ABORT, ABORT_RESPONSE }
    
    struct PerpOrderRequest {
        address token;
        uint256 amount;
        address gmxRouter;
        bytes gmxOrderData;
        uint256 minOutAmount;
        uint256 deadline;
        uint64 protocolChainId;
    }
    
    struct PerpOrderFulfillment {
        bytes32 orderId;
        uint256 amountUsed;
        bytes32 gmxPositionKey;
        uint256 executedAt;
        uint64 userChainId;
        uint64 fillChainId;
    }
    
    struct PerpOrder {
        bytes32 id;
        address user;
        PerpOrderRequest request;
        OrderStatus status;
        address solver;
        PerpOrderFulfillment fulfillment;
        bytes32 settlementBatchId;
        uint256 createdAt;
    }
    
    struct SettlementBatch {
        bytes32 id;
        address solver;
        bytes32[] orderIds;
        uint256 totalSettlementAmount;
        bool isSettled;
        uint256 createdAt;
        uint64 userChainId;
        uint64 protocolChainId;
    }
    
    struct CCIPMessage {
        MessageType msgType;
        bytes payload;
    }
    
    // Protocol Chain Errors
    error AmountTooLow();
    error AmountTooHigh();
    error GMXExecutionFailed();
    error InvalidRouter();

    // Settlement Errors
    error SettlementBatchNotFound();
    error OrderAlreadyInSettlementBatch();
    error SettlementBatchTooOld();
    error OrderTooOld();
    error InvalidSettlement();
    error SettlementFailed();

    // Access/Auth Errors
    error UnauthorizedSolver();
    error InvalidSourceChain();
    error InvalidCCIPMessage();
}

interface IGMXRouter {
    function executeOrder(bytes memory orderData) external returns (bytes32);
}

interface ICCIPSender {
    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    ) external returns (bytes32);
}

contract CCIPSettledIntentEngine is Ownable {
    using CrossChainPerpTypes for CrossChainPerpTypes.OrderStatus;
    
    mapping(bytes32 => CrossChainPerpTypes.PerpOrder) public orders;
    mapping(address => bool) public solvers;
    bytes32[] private orderHistory;
    
    event OrderCreated(bytes32 indexed orderId, address indexed user, address token, uint256 amount);
    event OrderFulfilled(bytes32 indexed orderId);
    event OrderSettled(bytes32 indexed orderId);
    event OrderAborted(bytes32 indexed orderId);
    event SolverRegistered(address indexed solver, bool approved);
    event OrderRemoved(bytes32 indexed orderId);
    
    modifier onlySolver() {
        if (!solvers[msg.sender]) revert CrossChainPerpTypes.UnauthorizedSolver();
        _;
    }
    
    function registerSolver(address solver, bool approved) external onlyOwner {
        solvers[solver] = approved;
        emit SolverRegistered(solver, approved);
    }
    
    function executeGMXOrder(address gmxRouter, bytes memory orderData) external onlySolver returns (bytes32) {
        if (gmxRouter == address(0)) revert CrossChainPerpTypes.InvalidRouter();
        bytes32 positionKey = IGMXRouter(gmxRouter).executeOrder(orderData);
        if (positionKey == bytes32(0)) revert CrossChainPerpTypes.GMXExecutionFailed();
        return positionKey;
    }
    
    function sendCCIPMessage(address ccipSender, uint64 destinationChain, Client.EVM2AnyMessage calldata message) 
        external 
        onlySolver 
        returns (bytes32) 
    {
        if (ccipSender == address(0)) revert CrossChainPerpTypes.InvalidCCIPMessage();
        return ICCIPSender(ccipSender).ccipSend(destinationChain, message);
    }
}
