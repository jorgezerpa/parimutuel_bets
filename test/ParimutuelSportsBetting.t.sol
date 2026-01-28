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
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    // A simple sanity check to ensure setup worked
    function test_OwnerIsCorrect() public {
        assertEq(parimutuel.owner(), owner);
    }

    // 1. Match Creation & Authorization

    function test_CreateMatch_Success() public {
        // Generic Test Data
        string memory t1 = "Team 1";
        string memory t2 = "Team 2";
        string memory desc = "Match Description";
        uint256 startTime = block.timestamp + 1 hours;

        vm.prank(owner);
        parimutuel.createMatch(t1, t2, desc, startTime);

        // Verify nextMatchId incremented
        assertEq(parimutuel.nextMatchId(), 1);

        // Verify ALL fields in the Match struct (Match 0)
        (
            string memory team1,
            string memory team2,
            string memory description,
            uint256 start,
            uint256 totalPool,
            uint8 winningOutcome,
            bool settled,
            bool cancelled,
            bool noWinners,
            uint256 rakeAmount
        ) = parimutuel.matches(0);

        assertEq(team1, t1);
        assertEq(team2, t2);
        assertEq(description, desc);
        assertEq(start, startTime);
        assertEq(totalPool, 0);
        assertEq(winningOutcome, 0);
        assertEq(settled, false);
        assertEq(cancelled, false);
        assertEq(noWinners, false);
        assertEq(rakeAmount, 0);
    }

    function test_Revert_CreateMatch_NotOwner() public {
        // Attempting to create a match as Alice
        vm.prank(alice);
        
        // OpenZeppelin 5.x Ownable error format
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        parimutuel.createMatch("T1", "T2", "Desc", block.timestamp + 1 hours);
    }

    function test_Revert_CreateMatch_InvalidTime() public {
        uint256 pastTime = block.timestamp - 1;

        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.InvalidStartTime.selector);
        parimutuel.createMatch("T1", "T2", "Desc", pastTime);
    }

    // 2. Betting Logic & Timing
    // These tests check the core "money-in" phase of the contract.
    function test_PlaceBet_Success() public {
        // Setup: Create a match
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("T1", "T2", "Desc", startTime);

        uint256 betAmount = 10 ether;
        uint8 outcome = 1;

        // Action: Alice places a bet
        vm.prank(alice);
        parimutuel.placeBet{value: betAmount}(0, outcome);

        // Assertions
        assertEq(address(parimutuel).balance, betAmount);
        assertEq(parimutuel.totalLiability(), betAmount);
        
        // Verify storage updates
        (,,,,uint256 totalPool,,,,,) = parimutuel.matches(0);
        assertEq(totalPool, betAmount);
        assertEq(parimutuel.bets(0, alice, outcome), betAmount);
        assertEq(parimutuel.getOutcomePool(0, outcome), betAmount);

    }

    function test_Revert_PlaceBet_AfterStart() public {
        // Setup: Create a match
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("T1", "T2", "Desc", startTime);

        // Fast forward time to 1 second past startTime
        vm.warp(startTime + 1);

        // Action & Revert
        vm.prank(bob);
        vm.expectRevert(ParimutuelSportsBetting.BettingClosed.selector);
        parimutuel.placeBet{value: 1 ether}(0, 1);
    }

    // @audit@todo fuzz_testing -> multiple valid and invalid values
    function test_Revert_PlaceBet_InvalidOutcome() public {
        // Setup: Create a match
        vm.prank(owner);
        parimutuel.createMatch("T1", "T2", "Desc", block.timestamp + 1 hours);

        // Action & Revert for outcome <1
        vm.prank(charlie);
        vm.expectRevert(ParimutuelSportsBetting.InvalidOutcome.selector);
        parimutuel.placeBet{value: 1 ether}(0, 0);

        // Action & Revert for outcome >3
        vm.prank(charlie);
        vm.expectRevert(ParimutuelSportsBetting.InvalidOutcome.selector);
        parimutuel.placeBet{value: 1 ether}(0, 4);
    }

    function test_Revert_PlaceBet_Cancelled() public {
        // Setup: Create a match
        vm.prank(owner);
        parimutuel.createMatch("T1", "T2", "Desc", block.timestamp + 1 hours);
        vm.prank(owner);
        parimutuel.cancelMatch(0);

        // Action & Revert for outcome 0
        vm.prank(charlie);
        vm.expectRevert(ParimutuelSportsBetting.MatchNotActive.selector);
        parimutuel.placeBet{value: 1 ether}(0, 0);
    }

    // 3. Settlement & Payout Math
    // The "Happy Path" where we calculate winners and protocol fees.
    function test_FullFlow_WinnersClaim() public {
        // 1. Setup Match (Starts in 1 hour)
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Match description", startTime);
        uint256 matchId = 0;

        // 2. Place Bets
        // Alice bets 10 ETH on Outcome 1 (The eventually winner)
        vm.prank(alice);
        parimutuel.placeBet{value: 10 ether}(matchId, 1);

        // Bob bets 20 ETH on Outcome 2
        vm.prank(bob);
        parimutuel.placeBet{value: 20 ether}(matchId, 2);

        // Charlie bets 70 ETH on Outcome 3
        vm.prank(charlie);
        parimutuel.placeBet{value: 70 ether}(matchId, 3);

        // 3. Move time forward and Settle
        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1);

        // 4. Calculate Expected Payout
        // Total Pool = 100 ETH. Rake = 3% (3 ETH). Net Pool = 97 ETH.
        // Alice owns 100% of the winning pool (Outcome 1).
        uint256 expectedPayout = 97 ether;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        parimutuel.claimWinnings(matchId);

        uint256 balanceAfter = alice.balance;
        assertEq(balanceAfter - balanceBefore, expectedPayout, "Alice did not receive the correct proportional share");
    }

    // @TODO redo the logic to calculate dust 
    function test_PayoutPrecision_And_DustRecovery() public {
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Dust Test", startTime);
        uint256 matchId = 0;

        // Alice and Bob bet on the SAME outcome with "messy" numbers
        // Alice: 10 ETH, Bob: 3.33 ETH -> Total Winning Pool: 13.33 ETH
        vm.prank(alice);
        parimutuel.placeBet{value: 10 ether}(matchId, 1);
        vm.prank(bob);
        parimutuel.placeBet{value: 3.33 ether}(matchId, 1);

        // Charlie loses with 20 ETH
        vm.prank(charlie);
        parimutuel.placeBet{value: 20 ether}(matchId, 2);

        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1);

        // Claim for Alice
        vm.prank(alice);
        parimutuel.claimWinnings(matchId);

        // Claim for Bob
        vm.prank(bob);
        parimutuel.claimWinnings(matchId);

        // Withdraw Fees
        vm.prank(owner);
        parimutuel.withdrawFees(matchId);

        // Check if there is "Dust" (leftover wei due to rounding)
        // totalLiability should be 0 now, so anything left in balance is dust
        uint256 dust = address(parimutuel).balance;
        
        uint256 ownerBalanceBefore = owner.balance;
        vm.prank(owner);
        parimutuel.recoverETH();
        uint256 ownerBalanceAfter = owner.balance;

        // console.log(ownerBalanceAfter, ownerBalanceBefore, dust, address(parimutuel).balance);
        // assertEq(ownerBalanceAfter - ownerBalanceBefore, dust, "Owner should recover the exact dust amount");
        // assertEq(address(parimutuel).balance, 0, "Contract should be empty after recovery");
        
    }

    // @todo test no winner tries to claim 

    function test_Revert_ClaimTwice() public {
        // 1. Setup and Settle Match
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "match description", startTime);
        uint256 matchId = 0;

        vm.prank(alice);
        parimutuel.placeBet{value: 10 ether}(matchId, 1);

        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1);

        // 2. First Claim (Success)
        vm.prank(alice);
        parimutuel.claimWinnings(matchId);

        // 3. Second Claim (Should Revert)
        vm.prank(alice);
        vm.expectRevert(ParimutuelSportsBetting.AlreadyClaimed.selector);
        parimutuel.claimWinnings(matchId);
    }

    // Settlement edge cases 
    function test_Revert_SettleMatch_InvalidStates() public {
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Validation Test", startTime);
        uint256 matchId = 0;

        // Add a bet so we don't trigger the NoBetsInPool error first // @todo add test for this edge case
        vm.prank(alice);
        parimutuel.placeBet{value: 1 ether}(matchId, 1);

        // 1. Revert: Settle before start time
        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.MatchNotStarted.selector);
        parimutuel.settleMatch(matchId, 1);

        // Move time forward past start time for the remaining tests
        vm.warp(startTime + 1);

        // 2. Revert: Invalid outcome (Outcome must be 1, 2, or 3)
        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.InvalidOutcome.selector);
        parimutuel.settleMatch(matchId, 4); 

        // 3. Revert: Non-existent match
        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.MatchNotExists.selector);
        parimutuel.settleMatch(999, 1);

        // 4. Revert: Already settled
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1); // First settlement (success)
        
        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.AlreadySettled.selector);
        parimutuel.settleMatch(matchId, 1);

        // 5. Revert: Settling a cancelled match
        // Create a new match to test cancellation
        vm.prank(owner);
        parimutuel.createMatch("Team C", "Team D", "Cancel Test", block.timestamp + 1 hours);
        uint256 cancelMatchId = 1;
        
        vm.prank(owner);
        parimutuel.cancelMatch(cancelMatchId);
        
        vm.warp(block.timestamp + 2 hours); // Move past start time
        vm.prank(owner);
        vm.expectRevert(ParimutuelSportsBetting.MatchWasCancelled.selector);
        parimutuel.settleMatch(cancelMatchId, 1);
    }

    // 4. Safety, Refunds, & Edge Cases
    // Handling the scenarios where things don't go as planned.

    function test_Refund_NoWinners() public {
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "No winner bet test", startTime);

        // Alice and Bob bet on Outcome 1 and 2
        vm.prank(alice);
        parimutuel.placeBet{value: 10 ether}(0, 1);
        vm.prank(bob);
        parimutuel.placeBet{value: 20 ether}(0, 2);

        // Fast forward and settle on Outcome 3 (which has 0 bets)
        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(0, 3);

        // Verify state is set to noWinners
        (,,,,,,bool settled,,bool noWinners,) = parimutuel.matches(0);
        assertTrue(settled);
        assertTrue(noWinners);

        // Alice claims refund
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        parimutuel.claimRefund(0);
        
        assertEq(alice.balance, balanceBefore + 10 ether);
    }

    function test_Refund_WhenMatchCancelled() public {
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Cancellation Test", startTime);

        vm.prank(charlie);
        parimutuel.placeBet{value: 5 ether}(0, 1);

        // Owner cancels the match
        vm.prank(owner);
        parimutuel.cancelMatch(0);

        // Charlie claims refund
        uint256 balanceBefore = charlie.balance;
        vm.prank(charlie);
        parimutuel.claimRefund(0);

        assertEq(charlie.balance, balanceBefore + 5 ether);
    }

    function test_Revert_CancelAfterSettle() public {
        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Security Test", startTime);

        vm.prank(alice);
        parimutuel.placeBet{value: 1 ether}(0, 1);

        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(0, 1);

        // Attempting to cancel after settlement should revert
        vm.expectRevert(ParimutuelSportsBetting.MatchAlreadySettled.selector);
        vm.prank(owner);
        parimutuel.cancelMatch(0);
    }

}


// 1. Match Creation & Authorization
// These tests ensure that only the admin can initialize games and that the input data is sane.

// test_CreateMatch_Success: Verifies that the owner can successfully create a match and that the nextMatchId increments.

// test_Revert_CreateMatch_NotOwner: Confirms that a non-owner (Alice) cannot create a match, triggering the OpenZeppelin OwnableUnauthorizedAccount custom error.

// test_Revert_CreateMatch_InvalidTime: Ensures that matches cannot be created with a startTime in the past, triggering InvalidStartTime.

// 2. Betting Logic & Timing
// These tests check the core "money-in" phase of the contract.

// test_PlaceBet_Success: Validates that a user can place a bet, the contract balance increases, and the totalLiability tracks the deposit.

// test_Revert_PlaceBet_AfterStart: Checks the "Lock" mechanism, ensuring no one can bet once the match startTime has passed (BettingClosed).

// test_Revert_PlaceBet_InvalidOutcome: Ensures users can only bet on outcomes 1, 2, or 3, preventing funds from being locked in unreachable outcomes (InvalidOutcome).

// 3. Settlement & Payout Math
// The "Happy Path" where we calculate winners and protocol fees.

// test_FullFlow_WinnersClaim: The primary integration test. It simulates bets on different outcomes, settles the match, calculates the 3% rake, and verifies Alice receives exactly her proportional share of the net pool.

// test_Revert_ClaimTwice: Ensures the hasClaimed mapping correctly prevents a user from draining the pool by claiming multiple times (AlreadyClaimed).

// 4. Safety, Refunds, & Edge Cases
// Handling the scenarios where things don't go as planned.

// test_Refund_NoWinners: Tests the logic where a match is settled, but no one bet on the winning outcome. It verifies that bettors can reclaim their original stakes via claimRefund.

// test_Refund_WhenMatchCancelled: Validates that if the owner cancels a match, users can successfully withdraw their funds.

// test_Revert_CancelAfterSettle: A security check to ensure the owner cannot "undo" a finished match to try and manipulate refunds (MatchAlreadySettled).