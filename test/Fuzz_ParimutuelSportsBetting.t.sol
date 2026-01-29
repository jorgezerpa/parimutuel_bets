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

    // Analize how the protocol behaves when user's inputs cause not-precise operations 
    function testFuzz_PayoutPrecision_And_Dust(
        uint256 aliceBet,
        uint256 bobBet,
        uint256 charlieBet
    ) public {

        uint256 startTime = block.timestamp + 1 hours;
        vm.prank(owner);
        parimutuel.createMatch("Team A", "Team B", "Dust Test", startTime);
        uint256 matchId = 0;

        // 1. Setup bets
        // Winning Outcome (1) total: 13.33 ETH
        vm.prank(alice);
        parimutuel.placeBet{value: 10 ether}(matchId, 1);
        vm.prank(bob);
        parimutuel.placeBet{value: 3.33 ether}(matchId, 1);

        // Losing Outcome (2) total: 20 ETH
        vm.prank(charlie);
        parimutuel.placeBet{value: 20 ether}(matchId, 2);

        // 2. Settle
        vm.warp(startTime + 1);
        vm.prank(owner);
        parimutuel.settleMatch(matchId, 1);

        // 3. Manual Math for Assertions
        // Total Pool: 33.33 ETH
        // Rake (3%): (33.33 * 300) / 10000 = 0.9999 ETH
        // Net Pool: 33.33 - 0.9999 = 32.3301 ETH
        // Total Winning Pool: 13.33 ETH
        
        uint256 totalPool = 33.33 ether;
        uint256 winningPool = 13.33 ether;
        uint256 rake = (totalPool * parimutuel.RAKE_PERCENT()) / parimutuel.BPS();
        uint256 netPool = totalPool - rake;

        uint256 expectedAlice = (10 ether * netPool) / winningPool;
        uint256 expectedBob = (3.33 ether * netPool) / winningPool;

        // 4. Execution
        uint256 alicePre = alice.balance;
        vm.prank(alice);
        parimutuel.claimWinnings(matchId);
        
        uint256 bobPre = bob.balance;
        vm.prank(bob);
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
        assertTrue(remainingDust == 1, "Dust is higher than expected for these values");
        
        // Final sanity check: Alice + Bob + Owner + Dust == Total Initial Pool
        assertEq(expectedAlice + expectedBob + rake + remainingDust, totalPool, "Accounting error");
    }

}

 