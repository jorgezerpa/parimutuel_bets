// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ParimutuelSportsBetting.sol";
import "../script/DeployParimutuelSportsBetting.s.sol";

contract ParimutuelTest is Test {
    ParimutuelSportsBetting public parimutuel;
    DeployParimutuel public deployer;

    // Actors
    address public owner = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266); // Public Key corresponding to the private key on the deploy script 
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public {
        // 1. Initialize the deployer script
        deployer = new DeployParimutuel();
        
        // 3. Deploy the contract using the script's logic
        parimutuel = deployer.run();

        // 4. Fund our test actors with some ETH
        vm.deal(alice, type(uint96).max);
        vm.deal(bob, type(uint96).max);
        vm.deal(charlie, type(uint96).max);
    }

    // Analize how the protocol behaves with different user's inputs, for example, some inputs may cause some dust to stay in the contract
    // But in any case, the protocol must always being able to stay solvent to user claims (should never revert out of funds when a legitime user tries to claim) 
    // Also, we check for a maximun amount of allowed dust. More of 1 wei per claim, is considered a leak. 
    // @TODO YES! MAKE ANOTHER TEST AND BOUND RANDOM AMOUNTS TO >0 SO AVOID "NoWinnersForOutcome"... make it more random, make the winning pool random too -> this should test so much more scenarios -> thats good or bad? better to write another separated test?
    function testFuzz_PayoutPrecision_And_Solvency(
        uint256 _aliceBet,
        uint256 _bobBet,
        uint256 _charlieBet
    ) public {
        // vm.assume(amount > 0);
        uint256 aliceBet = bound(_aliceBet, 1, type(uint96).max);
        uint256 bobBet = bound(_bobBet, 1, type(uint96).max);
        uint256 charlieBet = bound(_charlieBet, 1, type(uint96).max);

        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Dust Test", startTime);
        uint256 matchId = 0;


        // 1. Setup bets
        // Winning Outcome (1) total: 13.33 ETH
        vm.prank(alice);
        if(aliceBet==0) { 
            vm.expectRevert(ParimutuelSportsBetting.BetAmountZero.selector);
        }
        parimutuel.placeBet{value: aliceBet}(matchId, 1);

        vm.prank(bob);
        if(bobBet==0) { 
            vm.expectRevert(ParimutuelSportsBetting.BetAmountZero.selector);
        }
        parimutuel.placeBet{value: bobBet}(matchId, 1);
        
        // Losing Outcome (2) total: 20 ETH
        vm.prank(charlie);
        if(charlieBet==0) { 
            vm.expectRevert(ParimutuelSportsBetting.BetAmountZero.selector);
        }
        parimutuel.placeBet{value: charlieBet}(matchId, 2);

        // 2. Settle
        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1);

        // 3. Calculate expected values
        uint256 totalPool = aliceBet + bobBet + charlieBet;
        uint256 winningPool = aliceBet + bobBet;
        uint256 rake = (totalPool * parimutuel.RAKE_PERCENT()) / parimutuel.BPS();
        uint256 netPool = totalPool - rake;

        uint256 expectedAlice = (aliceBet * netPool) / winningPool;
        uint256 expectedBob = (bobBet * netPool) / winningPool;
       
        // 4. Execution
        uint256 alicePre = alice.balance;
        vm.prank(alice);
        if(aliceBet==0) { 
            vm.expectRevert(ParimutuelSportsBetting.NoWinningBet.selector);
        }
        parimutuel.claimWinnings(matchId);
        
        uint256 bobPre = bob.balance;
        vm.prank(bob);
        if(bobBet==0) { 
            vm.expectRevert(ParimutuelSportsBetting.NoWinningBet.selector);
        }
        parimutuel.claimWinnings(matchId);

        uint256 ownerPre = owner.balance;
        vm.prank(owner);
        parimutuel.withdrawFees(matchId);

        // 5. Assertions
        assertEq(alice.balance - alicePre, expectedAlice, "Alice payout mismatch");
        assertEq(bob.balance - bobPre, expectedBob, "Bob payout mismatch");
        assertEq(owner.balance - ownerPre, rake, "Owner rake mismatch");

        // 6. Dust Check
        // The contract should have a tiny amount of wei left over due to rounding down
        uint256 remainingDust = address(parimutuel).balance;
    
        // Lower than the number of winners (since each claimWinnings can leave at most 1 wei as dust)
        assertTrue(remainingDust < 2, "Dust is higher than expected for these values - possible precision leak");
        
        // Final sanity check: Alice + Bob + Owner + Dust == Total Initial Pool
        assertEq(expectedAlice + expectedBob + rake + remainingDust, totalPool, "Accounting error");
    }

}

 