// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ParimutuelSportsBetting.sol";
import "../script/DeployParimutuelSportsBetting.s.sol";

// full flow 
// - Owner creates bets 
// - Users bets on games 
// - user claims winnings 
// - owner claim fees 
// - all edge cases and reverts 

contract ParimutuelStatefulTest is Test {
    DeployParimutuel public deployer;
    ParimutuelSportsBetting public parimutuel;
    ParimutuelHandler public handler;

    // Actors
    address public owner = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266); // Public Key corresponding to the private key on the deploy script 
    address[] public actors;

    function setUp() public {
        // 0. Setup 100 actors
        actors.push(owner); /////////
        for (uint160 i = 1; i <= 100; i++) {
            address actor = address(i);
            // @audit let some actors without funds 
            vm.deal(actor, 1000000 ether); 
            actors.push(actor);
        }        
        // 1. Deploy contracts
        deployer = new DeployParimutuel();
        parimutuel = deployer.run();
        handler = new ParimutuelHandler(parimutuel, actors);

        targetContract(address(handler));

        // targetSelector(FuzzSelector({
        //     addr: address(handler),
        //     selectors: selectors
        // }));
    }

    /// @dev Invariant: Contract balance must always match our ghost accounting
    function invariant_solvency() public view {
        uint256 expectedBalance = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        assertEq(address(parimutuel).balance, expectedBalance, "Solvency Mismatch");
    }

    /// @dev Invariant: The sum of outcome pools must equal total pool
    function invariant_poolConsistency() public view {
        for(uint256 i = 0; i<handler.ghost_matchesCount(); i++) {
            uint256 outcome1 = parimutuel.getOutcomePool(i, 1);
            uint256 outcome2 = parimutuel.getOutcomePool(i, 2);
            uint256 outcome3 = parimutuel.getOutcomePool(i, 3);
            uint256 outcomeTotal = outcome1 + outcome2 + outcome3;

            assertEq(outcome1, handler.betAmountsPerOutcome(i, 1));
            assertEq(outcome2, handler.betAmountsPerOutcome(i, 2));
            assertEq(outcome3, handler.betAmountsPerOutcome(i, 3));
            assertEq(outcomeTotal, handler.betAmounts(i));
            assertEq(outcomeTotal, parimutuel.getTotalPool(i));
        }
    }

    /// @dev Invariant: Rake cannot exceed the defined 3% BPS
    function invariant_rakeLimit() public view {
        for (uint256 i = 0; i < handler.ghost_matchesCount(); i++) {
            (,,,,uint256 totalPool,,,,,uint256 rakeAmount) = parimutuel.matches(i);
            uint256 maxRake = (totalPool * parimutuel.RAKE_PERCENT()) / parimutuel.BPS();
            assertLe(rakeAmount, maxRake, "Rake exceeded 3%");
        }
    }
}

// @notice on the catch of each function, we assert if the revert was for an unexpected error for the input we are handling. i.e place
contract ParimutuelHandler is Test {
    ParimutuelSportsBetting parimutuel;
    address[] actors; 
    address owner; // actors' index 0 is the owner

    // GHOSTS
    uint256 public ghost_matchesCount = 0;
    uint256 public ghost_totalDeposited = 0;
    uint256 public ghost_totalWithdrawn = 0;

    mapping(uint256 matchId => mapping(uint8 outcome => uint256 totalAmount)) public betAmountsPerOutcome;
    mapping(uint256 matchId => uint256 totalAmount) public betAmounts;
    mapping(uint256 => bool) public matchIsSettled;


    constructor(ParimutuelSportsBetting _target, address[] memory _actors) {
        parimutuel = _target;
        actors = _actors;
        owner = _actors[0];
    }

    function createMatch(string memory t1, string memory t2, string memory desc, uint256 startTime) public {
        uint256 start = bound(startTime, block.timestamp + 1, block.timestamp + 30 days);
        vm.prank(owner);
        parimutuel.createMatch(t1, t2, desc, start);
        ghost_matchesCount++;
    }

    function placeBet(uint256 _value, uint256 _matchId, uint8 _outcome, uint256 _actorIdx) public {
        if(ghost_matchesCount == 0) return;
        
        uint256 matchId = bound(_matchId, 0, ghost_matchesCount - 1);
        uint8 outcome = uint8(bound(_outcome, 1, 3));
        address actor = actors[bound(_actorIdx, 1, actors.length - 1)];
        uint256 amount = bound(_value, 1, address(actor).balance);

        vm.prank(actor);
        parimutuel.placeBet{ value: amount }(matchId, outcome);
        betAmounts[matchId] += amount;
        betAmountsPerOutcome[matchId][outcome] += amount;
        ghost_totalDeposited += amount;
    }

    function settleMatch(uint256 _matchId, uint8 _winningOutcome) public {
        if(ghost_matchesCount == 0) return;
        uint256 matchId = bound(_matchId, 0, ghost_matchesCount - 1);
        uint8 winOutcome = uint8(bound(_winningOutcome, 1, 3));

        vm.prank(owner);
        parimutuel.settleMatch(matchId, winOutcome);
        matchIsSettled[matchId] = true;
    }

    function claimWinnings(uint256 _matchId, uint256 _actorIdx) public {
        if(ghost_matchesCount == 0) return;
        uint256 matchId = bound(_matchId, 0, ghost_matchesCount - 1);
        address actor = actors[bound(_actorIdx, 1, actors.length - 1)];

        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        parimutuel.claimWinnings(matchId);
        uint256 balanceAfter = actor.balance;
        ghost_totalWithdrawn += (balanceAfter - balanceBefore);
    }

    function withdrawFees(uint256 _matchId) public {
        if(ghost_matchesCount == 0) return;
        uint256 matchId = bound(_matchId, 0, ghost_matchesCount - 1);

        uint256 balanceBefore = owner.balance;
        vm.prank(owner);
        parimutuel.withdrawFees(matchId);
        uint256 balanceAfter = owner.balance;
        ghost_totalWithdrawn += (balanceAfter - balanceBefore);
    }

    // utils 
    function fastForward(uint256 _amount) public {
        // Bound the jump so the fuzzer doesn't skip 100 years at once
        uint256 amount = bound(_amount, 1 minutes, 1 weeks);
        vm.warp(amount);
        vm.roll(block.number + (amount / 12)); 
    }

}


 