/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PYIndex} from "./../src/RMM.sol";
import {SetUp, RMM} from "./SetUp.sol";

contract DeallocateTest is SetUp {
    function test_deallocate_BurnsLiquidity() public initDefaultPool dealSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad,,) =
            rmm.prepareAllocate(0.1 ether, 0.1 ether, PYIndex.wrap(YT.pyIndexCurrent()));

        (uint256 deltaLiquidity) = rmm.allocate(deltaXWad, deltaYWad, 0, address(this));

        uint256 lptBurned;
        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);

        uint256 preTotalLiquidity = rmm.totalLiquidity();
        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));
        assertEq(rmm.totalLiquidity(), preTotalLiquidity - deltaLiquidity / 2);
    }

    function test_deallocate_AdjustsPool() public initDefaultPool dealSY(address(this), 1_000 ether) {
        (uint256 deltaXWad, uint256 deltaYWad,,) =
            rmm.prepareAllocate(0.1 ether, 0.1 ether, PYIndex.wrap(YT.pyIndexCurrent()));

        (uint256 deltaLiquidity) = rmm.allocate(deltaXWad, deltaYWad, 0, address(this));

        uint256 lptBurned;
        (deltaXWad, deltaYWad, lptBurned) = rmm.prepareDeallocate(deltaLiquidity / 2);

        uint256 preReserveX = rmm.reserveX();
        uint256 preReserveY = rmm.reserveY();

        rmm.deallocate(deltaLiquidity / 2, 0, 0, address(this));
        assertEq(rmm.reserveX(), preReserveX - deltaXWad);
        assertEq(rmm.reserveY(), preReserveY - deltaYWad);
        assertEq(rmm.lastTimestamp(), block.timestamp);
    }

    function test_deallocate_TransfersTokens() public {
        vm.skip(true);
    }

    function test_deallocate_EmitsDeallocate() public {
        vm.skip(true);
    }

    function test_deallocate_RevertsIfInsufficientSYOutput() public {
        vm.skip(true);
    }

    function test_deallocate_RevertsIfInsufficientPTOutput() public {
        vm.skip(true);
    }
}
