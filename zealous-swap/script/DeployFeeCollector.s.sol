// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @notice Deploy FeeCollector.
///
/// Required environment variables:
///   OWNER       — address that can change feeRate / withdrawer
///   WITHDRAWER  — address that can withdraw collected fees
///   FEE_PERCENT — fee in basis points (percentage × 100)
///                 e.g. 75 = 0.75% | 100 = 1% | 500 = 5% | 1000 = 10% (max)
///   ROUTER      — Zealous Swap Router address
///
/// Usage:
///   OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 ROUTER=0x... \
///     forge script script/DeployFeeCollector.s.sol \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract DeployFeeCollector is Script {
    function run() external {
        address owner      = vm.envAddress("OWNER");
        address withdrawer = vm.envAddress("WITHDRAWER");
        address router     = vm.envAddress("ROUTER");

        // FEE_PERCENT is percentage × 100 (basis points).
        // The contract stores this value and divides by 10000 on each swap.
        // Examples: 75 → 0.75% | 100 → 1.00% | 1000 → 10.00% (max)
        uint256 feeBps = vm.envUint("FEE_PERCENT");

        console.log("Deploying FeeCollector...");
        console.log("  owner     :", owner);
        console.log("  withdrawer:", withdrawer);
        console.log("  feeRate   :", feeBps, "bps ( /10000 )");
        console.log("  router    :", router);

        vm.startBroadcast();
        FeeCollector fc = new FeeCollector(owner, withdrawer, feeBps, router);
        vm.stopBroadcast();

        console.log("FeeCollector deployed at:", address(fc));
    }
}
