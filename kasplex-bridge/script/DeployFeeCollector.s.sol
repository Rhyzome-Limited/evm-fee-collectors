// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @notice Deploy FeeCollector for Kasplex Bridge.
///
/// Required env variables:
///   OWNER       – admin address (can set feeRate / withdrawer)
///   WITHDRAWER  – address allowed to withdraw collected fees
///   FEE_PERCENT – fee in basis points (e.g. 75 = 0.75%)
///   BRIDGE      – Kasplex Bridge L2 contract address
///                 (mainnet: 0x34606e6d01280f49791628b311cf33a808d1f7c6)
///
/// Example:
///   OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 BRIDGE=0x34606e6d01280f49791628b311cf33a808d1f7c6 \
///     forge script script/DeployFeeCollector.s.sol --rpc-url $RPC_URL --broadcast
contract DeployFeeCollector is Script {
    function run() external {
        address owner      = vm.envAddress("OWNER");
        address withdrawer = vm.envAddress("WITHDRAWER");
        uint256 feeRate    = vm.envUint("FEE_PERCENT");
        address bridge     = vm.envAddress("BRIDGE");

        console.log("Deploying FeeCollector (Kasplex Bridge)");
        console.log("  owner     :", owner);
        console.log("  withdrawer:", withdrawer);
        console.log("  feeRate   :", feeRate, "bps");
        console.log("  bridge    :", bridge);

        vm.startBroadcast();
        FeeCollector fc = new FeeCollector(owner, withdrawer, feeRate, bridge);
        vm.stopBroadcast();

        console.log("FeeCollector deployed at:", address(fc));
    }
}
