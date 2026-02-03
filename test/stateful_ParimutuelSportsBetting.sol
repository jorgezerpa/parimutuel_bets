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

    function invariant_quick() public view {
        uint256 nextMatchId = parimutuel.nextMatchId();
        assertEq(handler.ghost_matchesCount(), nextMatchId);

        for(uint256 i = 0; i<nextMatchId; i++) {
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
}

// @notice on the catch of each function, we assert if the revert was for an unexpected error for the input we are handling. i.e place
contract ParimutuelHandler is Test {
    ParimutuelSportsBetting parimutuel;
    address[] actors; 
    address owner; // actors' index 0 is the owner

    // GHOSTS
    uint256 public ghost_matchesCount = 0;
    mapping(uint256 matchId => mapping(uint8 outcome => uint256 totalAmount)) public betAmountsPerOutcome;
    mapping(uint256 matchId => uint256 totalAmount) public betAmounts;


    constructor(ParimutuelSportsBetting _target, address[] memory _actors) {
        parimutuel = _target;
        actors = _actors;
        owner = _actors[0];
    }

    function createMatch(string memory team1Name, string memory team2Name, string memory description, uint256 startTime) public {
        vm.startPrank(owner); // Trivial, already tested 
        
        try parimutuel.createMatch(team1Name, team2Name, description, bound(startTime, 60 minutes, 30 days)) {
            ghost_matchesCount++;
        } catch (bytes memory lowLevelData) {
            bytes4 selector = bytes4(lowLevelData);
            if (selector != ParimutuelSportsBetting.InvalidStartTime.selector) {
                console.log("UNKNOWN ERROR in createMatch");
                console.logBytes(lowLevelData);
                console.log("params");
                console.log(team1Name);
                console.log(team2Name);
                console.log(description);
                console.log(startTime);
            }
        }
        vm.stopPrank();
    }

    function placeBet(
        uint256 _value, uint256 _matchId, uint8 _outcome, uint256 _actor
    ) public {
        if(ghost_matchesCount==0) return; // still not creates nothing
        
        _value = bound(_value, 1, 10 ether);

        uint256 matchId = bound(_matchId, 0, ghost_matchesCount-1); 
        uint8 outcome = uint8(bound(_outcome, 1, 3)); 

        vm.startPrank(actors[bound(_actor, 1, 100)]);        

        try parimutuel.placeBet{ value: _value }(matchId, outcome) {
            betAmounts[matchId] += _value;
            betAmountsPerOutcome[matchId][outcome] += _value;
        } catch (bytes memory lowLevelData) {
            bytes4 selector = bytes4(lowLevelData);
            if (selector != ParimutuelSportsBetting.BettingClosed.selector) {
                console.log("UNKNOWN ERROR in placeBet");
                console.logBytes(lowLevelData);
                console.log("params");
                console.log(matchId);
                console.log(outcome);
            }
        }

        vm.stopPrank();
    }

    // utils 
    function fastForward(uint256 _amount) public {
        // Bound the jump so the fuzzer doesn't skip 100 years at once
        uint256 amount = bound(_amount, 1 minutes, 1 weeks);
        vm.warp(amount);
        vm.roll(block.number + (amount / 12)); 
    }
}


 