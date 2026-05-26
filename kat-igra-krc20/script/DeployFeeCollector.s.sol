// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @notice Deploy FeeCollector for KAT Igra KRC-20 Bridge (ERC-20 → KRC-20).
///
/// Required env variables:
///   OWNER       – admin address (can set feeRate / withdrawer)
///   WITHDRAWER  – address allowed to withdraw collected fees
///   FEE_PERCENT – fee in basis points (e.g. 75 = 0.75%)
///   BRIDGE      – KRC-20 Bridge.sol address on Igra
///                 (mainnet: 0x295ad12c9F62594523Aa460F10a871aA8F1469cd)
///
/// Example:
///   OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 BRIDGE=0x295ad12c9F62594523Aa460F10a871aA8F1469cd \
///     forge script script/DeployFeeCollector.s.sol \
///     --rpc-url https://rpc.igralabs.com:8545 --private-key $PRIVATE_KEY --broadcast
contract DeployFeeCollector is Script {
    function run() external {
        address owner      = vm.envAddress("OWNER");
        address withdrawer = vm.envAddress("WITHDRAWER");
        uint256 feeRate    = vm.envUint("FEE_PERCENT");
        address bridge     = vm.envAddress("BRIDGE");

        console.log("Deploying FeeCollector (KAT Igra KRC-20 Bridge)");
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
