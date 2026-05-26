// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @notice Deploy FeeCollector for KAT Igra Bridge (iKAS → KAS exit).
///
/// Required env variables:
///   OWNER       – admin address (can set feeRate / withdrawer)
///   WITHDRAWER  – address allowed to withdraw collected fees
///   FEE_PERCENT – fee in basis points (e.g. 75 = 0.75%)
///   BRIDGE      – KasBridge contract address on Igra
///                 (mainnet: 0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d)
///
/// Example:
///   OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 BRIDGE=0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0 \
///   BRIDGE=0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d \
///     forge script script/DeployFeeCollector.s.sol \
///     --rpc-url https://rpc.igralabs.com:8545 --private-key $PRIVATE_KEY --broadcast
contract DeployFeeCollector is Script {
    function run() external {
        address owner      = vm.envAddress("OWNER");
        address withdrawer = vm.envAddress("WITHDRAWER");
        uint256 feeRate    = vm.envUint("FEE_PERCENT");
        address bridge     = vm.envAddress("BRIDGE");

        console.log("Deploying FeeCollector (KAT Igra Bridge)");
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
