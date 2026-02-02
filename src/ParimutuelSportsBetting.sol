// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ParimutuelSportsBetting
 * @dev A pool-based sports betting contract where winners split the pot.
 */
contract ParimutuelSportsBetting is Ownable, ReentrancyGuard {
    
    // --- Custom Errors ---
    error InvalidStartTime();
    error BettingClosed();
    error MatchNotActive();
    error InvalidOutcome();
    error BetAmountZero();
    error NoBetsInPool();
    error MatchNotExists();
    error MatchNotStarted();
    error AlreadySettled();
    error MatchWasCancelled();
    error NotSettled();
    error NoWinnersForOutcome();
    error AlreadyClaimed();
    error NoWinningBet();
    error TransferFailed();
    error RefundsNotActive();
    error NoFundsToRefund();
    error MatchAlreadySettled();

    struct Match {
        string team1;
        string team2;
        string description;
        uint256 startTime;
        uint256 totalPool;
        uint8 winningOutcome;
        mapping(uint8 => uint256) outcomePools;
        bool settled;
        bool cancelled;
        bool noWinners;
        uint256 rakeAmount;
    }

    uint256 public constant RAKE_PERCENT = 300; // 3% Platform Fee
    uint256 public constant BPS = 10000;

    mapping(uint256 => Match) public matches;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public bets;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    uint256 public nextMatchId;

    event MatchCreated(uint256 indexed matchId, string description, uint256 startTime);
    event BetPlaced(uint256 indexed matchId, address indexed bettor, uint8 outcome, uint256 amount);
    event MatchSettled(uint256 indexed matchId, uint8 winningOutcome);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event RefundClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event MatchCancelled(uint256 indexed matchId);
    event NoWinners(uint256 indexed matchId);

    constructor() Ownable(msg.sender) {}

    /**
    * @dev Read the pool size for a specific outcome of a specific match
    * @param _matchId The ID of the match you want to check
    * @param _outcome The outcome ID (e.g., 1 for Team A, 2 for Team B)
    */
    function getOutcomePool(uint256 _matchId, uint8 _outcome) public view returns (uint256) {
        return matches[_matchId].outcomePools[_outcome];
    }

    function createMatch(string memory _team1, string memory _team2, string memory _description, uint256 _startTime) external onlyOwner {
        if (_startTime <= block.timestamp) revert InvalidStartTime();
        
        Match storage newMatch = matches[nextMatchId];
        newMatch.team1 = _team1;
        newMatch.team2 = _team2;
        newMatch.description = _description;
        newMatch.startTime = _startTime;
        
        emit MatchCreated(nextMatchId, _description, _startTime);
        nextMatchId++;
    }

    function placeBet(uint256 _matchId, uint8 _outcome) external payable nonReentrant {
        Match storage m = matches[_matchId];
        if (block.timestamp >= m.startTime) revert BettingClosed();
        if (m.cancelled) revert MatchNotActive();
        if (_outcome < 1 || _outcome > 3) revert InvalidOutcome();
        if (msg.value == 0) revert BetAmountZero();

        m.totalPool += msg.value;
        m.outcomePools[_outcome] += msg.value;
        bets[_matchId][msg.sender][_outcome] += msg.value;

        emit BetPlaced(_matchId, msg.sender, _outcome, msg.value);
    }

    function settleMatch(uint256 _matchId, uint8 _winningOutcome) external onlyOwner {
        Match storage m = matches[_matchId];

        if (m.startTime == 0) revert MatchNotExists();
        if (block.timestamp < m.startTime) revert MatchNotStarted();
        if (m.settled) revert AlreadySettled();
        if (m.cancelled) revert MatchWasCancelled();
        if (_winningOutcome < 1 || _winningOutcome > 3) revert InvalidOutcome();

        m.winningOutcome = _winningOutcome;
        m.settled = true;

        if (m.outcomePools[_winningOutcome] == 0) {      
            m.noWinners = true; 
            emit NoWinners(_matchId);
        } else {
            // @notice the only way this rounds to 0 is when total pool is less than 34 (precisely 33.333) because 300*34>10000 
            // For tokens with low decimals (like usdc/usdt) this could reduce the amount of fees for the protocol.
            // But, this is unsuitable due to high gas fees (for usdt, attacker must make 10000 TXs to bet 1 dollar free of fees)
            // Also, this still could accumulate dust on the contract, so may set a constraint for this is ok. @audit 
            uint256 rake = (m.totalPool * RAKE_PERCENT) / BPS; 
            m.rakeAmount = rake;
        }

        emit MatchSettled(_matchId, _winningOutcome);
    }

    function claimWinnings(uint256 _matchId) external nonReentrant {
        Match storage m = matches[_matchId];
        if (!m.settled) revert NotSettled();
        if (m.noWinners) revert NoWinnersForOutcome(); // Early revert to save gas -> it still is handled bellow when checks for user bet amount
        if (hasClaimed[_matchId][msg.sender]) revert AlreadyClaimed();
        
        uint256 userBet = bets[_matchId][msg.sender][m.winningOutcome]; 
        if (userBet == 0) revert NoWinningBet(); 

        uint256 totalWinningPool = m.outcomePools[m.winningOutcome];
        uint256 netPool = m.totalPool - m.rakeAmount;

        uint256 payout = (userBet * netPool) / totalWinningPool;

        hasClaimed[_matchId][msg.sender] = true;

        (bool success, ) = payable(msg.sender).call{value: payout}("");
        if (!success) revert TransferFailed();

        emit WinningsClaimed(_matchId, msg.sender, payout);
    }

    function withdrawFees(uint256 _matchId) external onlyOwner nonReentrant {
        Match storage m = matches[_matchId];
        if (!m.settled) revert NotSettled();
        // @audit if settled but no winners, should I add an early revert? -> because if so, it will make a 0 transfer expending gas -> low 
        uint256 amount = m.rakeAmount;

        m.rakeAmount = 0;

        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function cancelMatch(uint256 _matchId) external onlyOwner {
        if (matches[_matchId].settled) revert MatchAlreadySettled();
        matches[_matchId].cancelled = true;
        emit MatchCancelled(_matchId);
    }

    function claimRefund(uint256 _matchId) external nonReentrant {
        Match storage m = matches[_matchId];
        
        bool canRefund = (!m.settled && m.cancelled) || (m.settled && m.noWinners);
        if (!canRefund) revert RefundsNotActive();
        if (hasClaimed[_matchId][msg.sender]) revert AlreadyClaimed();

        uint256 refundAmount = 0;
        for (uint8 i = 1; i <= 3; i++) {
            refundAmount += bets[_matchId][msg.sender][i];
            bets[_matchId][msg.sender][i] = 0;
        }

        if (refundAmount == 0) revert NoFundsToRefund();

        hasClaimed[_matchId][msg.sender] = true;

        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        if (!success) revert TransferFailed();

        emit RefundClaimed(_matchId, msg.sender, refundAmount);
    }
}