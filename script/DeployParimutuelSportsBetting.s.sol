// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/ParimutuelSportsBetting.sol";

contract DeployParimutuel is Script {
    function run() external returns (ParimutuelSportsBetting) {
        // Look for the key, but provide a fallback for local tests
        uint256 deployerPrivateKey;
        
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployerPrivateKey = pk;
        } catch {
            // This is a standard Foundry default private key for local testing
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }

        vm.startBroadcast(deployerPrivateKey);
        ParimutuelSportsBetting parimutuel = new ParimutuelSportsBetting();
        vm.stopBroadcast();

        return parimutuel;
    }
}