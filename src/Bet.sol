// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ParimutuelSportsBetting
 * @dev A pool-based sports betting contract where winners split the pot.
 */
contract ParimutuelSportsBetting is Ownable, ReentrancyGuard {
    
    struct Match {
        // Human Data -> references for admins to settled
        string team1;
        string team2;
        string description;      // e.g., "Real Madrid vs Barcelona - la liga"
        // Bet data
        uint256 startTime;       // When betting closes -> match starts
        uint256 totalPool;       // Total ETH in the pool
        uint8 winningOutcome;    // 1: Team A, 2: Team B, 3: Draw
        // @dev 1 + 2 + 3 should be equal to totalPool
        mapping(uint8 => uint256) outcomePools; // Logic: 1 => Team A Pool, 2 => Team B Pool, etc. -> tracks  how much money on each outcome
        bool settled;            // Has the result been announced?
        bool cancelled;          // Has the match been cancelled?
        bool noWinners;          // True when noone bets on the outcome 
        uint256 rakeAmount; // After match, now much was for the protocol from the total 
    }

    // MatchID => Match Data
    mapping(uint256 => Match) public matches;
    // MatchID => UserAddress => Outcome => Amount
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public bets; // @INVARIANT Outcome can only be 1,2,3 -? otherwise funds get locked -> so should be impossible to set a diff value diff than 1 2 or 3
    // MatchID => UserAddress => Has Claimed
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    uint256 public nextMatchId; // Id used when admin creates a new match
    uint256 public constant RAKE_PERCENT = 300; // 3% Platform Fee
    uint256 public constant BPS = 10000;


    event MatchCreated(uint256 indexed matchId, string description, uint256 startTime);
    event BetPlaced(uint256 indexed matchId, address indexed bettor, uint8 outcome, uint256 amount);
    event MatchSettled(uint256 indexed matchId, uint8 winningOutcome);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event MatchCancelled(uint256 indexed matchId);

    constructor() Ownable(msg.sender) {
        // # @dev TODO -> Deploy 1 of this for token (and receive here in parms)
        // OOORRR save the used token (or tokens) on the match data, so user can choose in what to pay (We need a withlisted address and an oracle if multiple tokens are allowed per match, if not, only add the addreess to the match and continue to the next one) 
    }

    /**
     * @dev Create a new match. 
     * @param _description Match title.
     * @param _startTime Unix timestamp when betting should be locked.
     */
    function createMatch(string memory _team1, string memory _team2, string memory _description, uint256 _startTime) external onlyOwner {
        require(_startTime > block.timestamp, "Start time must be in future");
        
        Match storage newMatch = matches[nextMatchId];
        newMatch.team1 = _team1;
        newMatch.team2 = _team2;
        newMatch.description = _description;
        newMatch.startTime = _startTime;
        
        emit MatchCreated(nextMatchId, _description, _startTime);
        nextMatchId++;
    }

    /**
     * @dev Place a bet on an outcome.
     * @param _matchId The ID of the match.
     * @param _outcome 1: Team A, 2: Team B, 3: Draw.
     */
    function placeBet(uint256 _matchId, uint8 _outcome) external payable nonReentrant {
        Match storage m = matches[_matchId];
        require(block.timestamp < m.startTime, "Betting closed");
        require(!m.settled && !m.cancelled, "Match not active");
        require(_outcome >= 1 && _outcome <= 3, "Invalid outcome");
        require(msg.value > 0, "Bet must be > 0");

        // Update state (Effects)
        m.totalPool += msg.value;
        m.outcomePools[_outcome] += msg.value;
        bets[_matchId][msg.sender][_outcome] += msg.value;

        emit BetPlaced(_matchId, msg.sender, _outcome, msg.value);
    }

    /**
     * @dev Settle the match result. Usually called by an Oracle or Owner.
     */
    function settleMatch(uint256 _matchId, uint8 _winningOutcome) external onlyOwner {
        Match storage m = matches[_matchId];

        require(m.totalPool>0, "No bets in pool");
        require(m.startTime>0, "Invalid match startTime"); // i.e match not exists
        require(block.timestamp >= m.startTime, "Match not started yet"); 
        require(!m.settled, "Already settled");
        require(!m.cancelled, "Match was cancelled"); // can not settle if cancelled
        require(_winningOutcome >= 1 && _winningOutcome <= 3, "Invalid outcome");

        // set outcome
        m.winningOutcome = _winningOutcome;
        m.settled = true;

        // If no one bets on the winning outcome, then we enter into refund mode and protocol does not take fees here
        if (m.outcomePools[_winningOutcome] == 0) {         
            m.noWinners = true;
        }
        else {
            uint256 rake = (m.totalPool * RAKE_PERCENT) / BPS; // Dust remainders are acceptable @todo implement a sweep function or take them during withdrawFees
            m.rakeAmount = rake;
        }

        emit MatchSettled(_matchId, _winningOutcome);
    }

    /**
     * @dev Users claim their winnings using the CEI pattern.
     */
     // @TODO make claimWinningWithSignature function or implement some delegation logic 
    function claimWinnings(uint256 _matchId) external nonReentrant {
        Match storage m = matches[_matchId];
        require(m.settled, "Not settled");
        require(!m.noWinners, "No winners for the bet"); // early return to avoid division by 0 in payout calculation
        require(m.winningOutcome>=1 && m.winningOutcome<=3, "Invalid outcome"); // RARE_EDGE_CASE when match is not setted winning outcome is 0, so we check is a valid value -> This should be not possible because of when settled this value is setted. But NEVER ASSUME ANYTHING! 
        
        uint256 userBet = bets[_matchId][msg.sender][m.winningOutcome]; 
        require(userBet > 0, "No winning bet");

        uint256 totalWinningPool = m.outcomePools[m.winningOutcome];
        uint256 netPool = m.totalPool - m.rakeAmount;

        uint256 payout = (userBet * netPool) / totalWinningPool;

        // Update state before transfer (CEI Pattern)
        hasClaimed[_matchId][msg.sender] = true;

        // Interaction -> CEI + Reentrancy check = Gorgeous security :)
        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "Transfer failed");

        emit WinningsClaimed(_matchId, msg.sender, payout);
    }

    /**
     * @dev Owner withdraws the collected fees.
     */
    function withdrawFees(uint256 _matchId) external onlyOwner nonReentrant {
        Match storage m = matches[_matchId];
        require(m.settled, "Match must be settled");
        uint256 amount = m.rakeAmount;
        m.rakeAmount = 0; // Reset rake to prevent double withdrawal -> So even if owner is compromised, attacker can not withdraw fees from users' portion

        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Fee withdrawal failed");
    }

    // Optional: Emergency refund logic if match is cancelled
    function cancelMatch(uint256 _matchId) external onlyOwner {
        require(!matches[_matchId].settled, "already settled"); // Very low probable edge case, but could happen -> What if cancel after settle? and after protocol withdraw fees? could lead to insolvency on some users when try to withdraw -> so, if it was settled, that's the final state of the match. 
        matches[_matchId].cancelled = true;
        emit MatchCancelled(_matchId);
    }

    /**
    * @dev Allows users to reclaim their stakes if a match is cancelled or no winners after set
    * @param _matchId The ID of the cancelled match.
    */
    function claimRefund(uint256 _matchId) external nonReentrant {
        Match storage m = matches[_matchId];
        
        // Checks
        require(
            (!m.settled && m.cancelled) || (m.settled && m.noWinners),
            "Refunds are not active for this match" 
        );
        require(!hasClaimed[_matchId][msg.sender], "Already refunded/claimed");

        // Calculate total amount user put into this match across all outcomes
        uint256 refundAmount = 0;
        // @audit@IMPORTANT -> allow the user to only select one option -> can bet on all and (almost) secure wins -> also, he can just create another wallet so this measure could be stupid
        // @^ but this will make the bet not interesting? like I and 10 on 1,2,3 so I will get 30 back -> If all makes that, it does not incentive -> but still incenvise put it one? analize this  -> but is sec stragegy if not all makes this, so suffer the ones which put all in one -> but this ones has mor % if winsss... aaaaaaaa
        for (uint8 i = 1; i <= 3; i++) {
            refundAmount += bets[_matchId][msg.sender][i];
            // Reset the bet record for each outcome to prevent double-dipping -> USEFUL for example if, in future we implment a uncancel logic -> becaue in that case if wins can takes the refund and then claim the win -> hasclaimed is setted to false, so it is not possible, but hey, NEVER ASSUME NOTHING! bugs are on assumptions 
            // if logic ever changes to allow multiple claims
            bets[_matchId][msg.sender][i] = 0;
        }

        require(refundAmount > 0, "No funds to refund");

        // Effects
        hasClaimed[_matchId][msg.sender] = true;

        // Interactions
        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "Refund transfer failed");

        emit WinningsClaimed(_matchId, msg.sender, refundAmount);
        // @TODO instead of winningClaimed, create a refund event 
    }
}