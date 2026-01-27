// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * @title Web3SportsBettingAutomated
 * @dev Full MVP: Crypto wallet integration, Pool-based logic, and Chainlink Oracle settlement.
 */
contract Web3SportsBettingAutomated is FunctionsClient, Ownable, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    struct Match {
        string description;      // e.g., "Real Madrid vs Barcelona"
        uint256 startTime;       // When betting closes (Unix timestamp)
        uint256 totalPool;       // Total ETH in the pool
        uint256 rakeAmount;      // Amount reserved for the platform (3%)
        uint8 winningOutcome;    // 1: Team A, 2: Team B, 3: Draw
        bool settled;            // Has the result been written?
        bool cancelled;          // Has the match been cancelled?
        mapping(uint8 => uint256) outcomePools; // Tracks individual pools for A, B, and Draw
    }

    // State Variables
    mapping(uint256 => Match) public matches;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public bets;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(bytes32 => uint256) public requestIdToMatchId;

    uint256 public nextMatchId;
    uint256 public constant RAKE_PERCENT = 3; 

    // Chainlink Configuration (Update these based on your specific network, e.g., Base or Arbitrum)
    address public constant ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D; 
    bytes32 public constant DON_ID = 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000;

    // Events
    event MatchCreated(uint256 indexed matchId, string description, uint256 startTime);
    event BetPlaced(uint256 indexed matchId, address indexed bettor, uint8 outcome, uint256 amount);
    event ResultRequested(bytes32 indexed requestId, uint256 matchId);
    event MatchSettled(uint256 indexed matchId, uint8 winningOutcome);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event MatchCancelled(uint256 indexed matchId);

    constructor() FunctionsClient(ROUTER) Ownable(msg.sender) {}

    /**
     * @notice Create a match and set the cutoff time for bets.
     */
    function createMatch(string memory _description, uint256 _startTime) external onlyOwner {
        require(_startTime > block.timestamp, "Start time must be future");
        
        Match storage newMatch = matches[nextMatchId];
        newMatch.description = _description;
        newMatch.startTime = _startTime;
        
        emit MatchCreated(nextMatchId, _description, _startTime);
        nextMatchId++;
    }

    /**
     * @notice Users place bets on outcome 1, 2, or 3.
     */
    function placeBet(uint256 _matchId, uint8 _outcome) external payable nonReentrant {
        Match storage m = matches[_matchId];
        require(block.timestamp < m.startTime, "Betting has closed");
        require(!m.settled && !m.cancelled, "Match is not active");
        require(_outcome >= 1 && _outcome <= 3, "Outcome must be 1, 2, or 3");
        require(msg.value > 0, "Must bet more than 0");

        m.totalPool += msg.value;
        m.outcomePools[_outcome] += msg.value;
        bets[_matchId][msg.sender][_outcome] += msg.value;

        emit BetPlaced(_matchId, msg.sender, _outcome, msg.value);
    }

    /**
     * @notice Trigger the Oracle request to get the final score from an API.
     */
    function requestMatchResult(
        uint256 _matchId,
        string calldata source,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) external onlyOwner returns (bytes32 requestId) {
        Match storage m = matches[_matchId];
        require(block.timestamp >= m.startTime, "Match has not started");
        require(!m.settled, "Already settled");

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, DON_ID);
        requestIdToMatchId[requestId] = _matchId;

        emit ResultRequested(requestId, _matchId);
    }

    /**
     * @notice Internal callback for Chainlink Oracle.
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory /* err */
    ) internal override {
        uint256 matchId = requestIdToMatchId[requestId];
        Match storage m = matches[matchId];

        if (m.settled || m.cancelled) return;

        // Convert the bytes response back to a uint8 (1, 2, or 3)
        uint8 outcome = uint8(uint256(bytes32(response)));
        require(outcome >= 1 && outcome <= 3, "Oracle returned invalid outcome");

        m.winningOutcome = outcome;
        m.rakeAmount = (m.totalPool * RAKE_PERCENT) / 100;
        m.settled = true;

        emit MatchSettled(matchId, outcome);
    }

    /**
     * @notice Winners claim their share of the pool.
     */
    function claimWinnings(uint256 _matchId) external nonReentrant {
        Match storage m = matches[_matchId];
        
        // 1. Checks
        require(m.settled, "Match is not settled yet");
        require(!hasClaimed[_matchId][msg.sender], "Winnings already claimed");
        
        uint256 userBet = bets[_matchId][msg.sender][m.winningOutcome];
        require(userBet > 0, "You did not bet on the winning outcome");

        uint256 totalWinningPool = m.outcomePools[m.winningOutcome];
        uint256 netPool = m.totalPool - m.rakeAmount;

        // Math: (Your Stake / All Winning Stakes) * Total Pot after fees
        uint256 payout = (userBet * netPool) / totalWinningPool;

        // 2. Effects (State changes before transfer)
        hasClaimed[_matchId][msg.sender] = true;

        // 3. Interactions (Sending the ETH)
        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "Transfer failed");

        emit WinningsClaimed(_matchId, msg.sender, payout);
    }

    /**
     * @notice Owner pulls the 3% rake after the match is over.
     */
    function withdrawFees(uint256 _matchId) external onlyOwner nonReentrant {
        Match storage m = matches[_matchId];
        require(m.settled, "Match must be settled");
        
        uint256 amount = m.rakeAmount;
        require(amount > 0, "No fees to withdraw");
        
        m.rakeAmount = 0; 
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Fee withdrawal failed");
    }

    /**
     * @notice In case of game cancellation, users can be refunded (Manual implementation suggested).
     */
    function cancelMatch(uint256 _matchId) external onlyOwner {
        matches[_matchId].cancelled = true;
        emit MatchCancelled(_matchId);
    }
}