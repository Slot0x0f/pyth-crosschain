// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/OracleSwap.sol";
import "pyth-sdk-solidity/MockPyth.sol";

contract MyScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        MockPyth mockPyth = new MockPyth(60, 1);

        vm.startBroadcast(deployerPrivateKey);

        OracleSwap swap = new OracleSwap(
            address(mockPyth),
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b,
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            address(0xdAC17F958D2ee523a2206206994597C13D831ec7)
        );

        vm.stopBroadcast();
    }
}
