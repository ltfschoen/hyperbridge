// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {StructSizeCalc, Body} from "../src/utils/StructSizeCalc.sol";

contract MiniTest is Test {

    StructSizeCalc public structSizeContract;

    function setUp() public {
        structSizeContract = new StructSizeCalc();
    }

    function test_struct_length() public {

        Body memory body = Body({
            amount: 100,
            tokenId: bytes32(0x0000000000000000000000000000000000000000000000000000000000000020),
            redeem: false,
            from: vm.addr(uint256(keccak256("from"))),
            to: vm.addr(uint256(keccak256("to")))
        });

        uint256 size = structSizeContract.calculateStruct(body);

        assertEq(size, 160);
    }
}