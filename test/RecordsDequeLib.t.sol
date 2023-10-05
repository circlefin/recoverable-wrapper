// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {RecordsDeque, RecordsDequeLib, Record} from "../contracts/util/RecordUtil.sol";
import {Test} from "forge-std/src/Test.sol";
import {SECONDS_PER_DAY} from "./utils/constants.sol";

// solhint-disable var-name-mixedcase

contract RecordsTest is Test {
    RecordsDeque private rd;
    using RecordsDequeLib for RecordsDeque;

    error NoRecords();
    error InvalidUnfreezeAmount(uint256 currentFrozenInRecord, uint256 unfreezeAmount);
    error InvalidFreezeAmount(uint256 remainingToFreeze, uint256 freezeAmount);
    error InvalidSubtractedValue(uint256 rawIndex, uint256 amount, uint256 subtractedValue);

    function assertEqRecords(Record memory r1, Record memory r2) private {
        assertEq(r1.amount, r2.amount);
        assertEq(r1.settlementTime, r2.settlementTime);
        assertEq(r1.frozen, r2.frozen);
        assertEq(r1.prev, r2.prev);
        assertEq(r1.next, r2.next);
    }

    function testPreInitializedState() public {
        assertEq(rd.tail, 0);
        assertEq(rd.head, 0);
        assertEq(rd.nextRawIndex(), 1);

        vm.expectRevert(abi.encodeWithSelector(NoRecords.selector));
        rd.first();

        vm.expectRevert(abi.encodeWithSelector(NoRecords.selector));
        rd.dequeue(true);
    }

    function testEnqueue() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(100, block.timestamp + SECONDS_PER_DAY);
        assertEq(rawIndex, 1);
        assertEq(rd.tail, 1);
        assertEq(rd.head, 1);
        assertEqRecords(rd.getAt(rawIndex), r);


        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex2 = rd.enqueue(r2.amount, r2.settlementTime);
        assertEqRecords(rd.getAt(rawIndex2), r2);
        assertEq(rd.tail, 2); 
    }

    function testFirst() public {
        uint128 AMOUNT = 100;
        uint256 time = block.timestamp + SECONDS_PER_DAY;
        Record memory r = Record(AMOUNT, time, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);
        (Record memory r2, uint256 rawIndex) = rd.first();
        assertEqRecords(r, r2);
        assertEq(rawIndex, 1);
    }

    function testDequeue() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        rd.enqueue(r2.amount, r2.settlementTime);

        assertEq(rd.head, 1);
        assertEq(rd.tail, 2);
        
        rd.dequeue(false);
        assertEq(rd.head, 2);
        assertEq(rd.tail, 2);
        (Record memory rr,) = rd.first();
        assertEqRecords(rr, Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 0, 0));
         
        //assert it hasn't been deleted
        assertEqRecords(rd.getAt(rawIndex), Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 2));
        assertEq(rd.nextRawIndex(), 3);
    }

    function testDequeue_fail_empty() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);
        rd.dequeue(true);
        vm.expectRevert(abi.encodeWithSelector(NoRecords.selector));
        rd.dequeue(true);
    }

    function testDequeueAndDelete() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        rd.enqueue(r2.amount, r2.settlementTime);

        assertEq(rd.head, 1);
        assertEq(rd.tail, 2);
        
        rd.dequeue(true);
        assertEq(rd.head, 2);
        assertEq(rd.tail, 2);
        (Record memory rr,) = rd.first();

        assertEqRecords(rr, Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 0, 0));
         
        //assert it has been deleted
        assertEqRecords(rd.getAt(rawIndex), Record(0, 0, 0, 0, 0));
    }
    
    function testDecrementRecordAmount() public {
        uint128 initial = 100;
        uint128 subtractValue = 30;
        Record memory r = Record(initial, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);

        rd.decrementRecordAmount(1, subtractValue);
        assertEqRecords(rd.getAt(1), Record(initial - subtractValue, block.timestamp + SECONDS_PER_DAY, 0, 0, 0));
    }

    function testDecrementRecordAmount_fail() public {
        uint128 initial = 100;
        uint128 subtractValue = 110;
        Record memory r = Record(initial, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);
        vm.expectRevert(abi.encodeWithSelector(InvalidSubtractedValue.selector, 1, 100, 110));
        rd.decrementRecordAmount(1, subtractValue);
    }

    function testDeleteAt_start() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        rd.enqueue(r2.amount, r2.settlementTime);

        rd.deleteAt(rawIndex);
        assertEqRecords(rd.getAt(rawIndex), Record(0, 0, 0, 0, 0));
        assertEq(rd.head, 2);
        assertEq(rd.tail, 2);
    }

    function testDeleteAt_end() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex = rd.enqueue(r2.amount, r2.settlementTime);

        rd.deleteAt(rawIndex);
        assertEqRecords(rd.getAt(rawIndex), Record(0, 0, 0, 0, 0));
        assertEq(rd.head, 1);
        assertEq(rd.tail, 1);
    }

    function testDeleteAt_middle() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex = rd.enqueue(r2.amount, r2.settlementTime);

        Record memory r3 = Record(100, block.timestamp + SECONDS_PER_DAY + 1, 0, 0, 0);
        rd.enqueue(r3.amount, r3.settlementTime);

        rd.deleteAt(rawIndex);
        assertEqRecords(rd.getAt(rawIndex), Record(0, 0, 0, 0, 0));
        assertEq(rd.head, 1);
        assertEq(rd.tail, 3);
        assertEqRecords(rd.getAt(1), Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 3));
        assertEqRecords(rd.getAt(3), Record(100, block.timestamp + SECONDS_PER_DAY + 1, 0, 1, 0));
    }

    function testDeleteAt_higherStart() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);

        rd.dequeue(false);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex = rd.enqueue(r2.amount, r2.settlementTime);
        assertEq(rd.head, 2);
        assertEq(rd.tail, 2);

        Record memory r3 = Record(100, block.timestamp + SECONDS_PER_DAY + 1, 0, 0, 0);
        rd.enqueue(r3.amount, r3.settlementTime);

        rd.deleteAt(rawIndex);
        assertEq(rd.head, 3);
        assertEq(rd.tail, 3);
    }

    function testDeleteAt_justOne() public {
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        rd.enqueue(r.amount, r.settlementTime);

        Record memory r2 = Record(200, block.timestamp + 2 * SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex = rd.enqueue(r2.amount, r2.settlementTime);

        rd.dequeue(false);
        rd.deleteAt(rawIndex);
        assertEq(rd.head, 0);
        assertEq(rd.tail, 2);
    }

    function testFreezeRecord() public {
        uint128 FREEZE_AMOUNT = 40;
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);
        rd.freezeRecord(rawIndex, FREEZE_AMOUNT);
        assertEq(rd.queue[1].frozen, FREEZE_AMOUNT);

        // freeze another time
        rd.freezeRecord(rawIndex, FREEZE_AMOUNT);
        assertEq(rd.getAt(rawIndex).frozen, 2 * FREEZE_AMOUNT);

        // can't overfreeze
        vm.expectRevert(abi.encodeWithSelector(InvalidFreezeAmount.selector, 100 - 2 * FREEZE_AMOUNT, FREEZE_AMOUNT));
        rd.freezeRecord(rawIndex, FREEZE_AMOUNT);
    } 

    function testUnfreezeRecord() public {
        uint128 FREEZE_AMOUNT = 40;
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);
        rd.freezeRecord(rawIndex, FREEZE_AMOUNT);

        // freeze another record
        Record memory r2 = Record(80, block.timestamp + SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex2 = rd.enqueue(r2.amount, r2.settlementTime);
        rd.freezeRecord(rawIndex2, FREEZE_AMOUNT);

        // unfreeze 
        // hasn't settled yet, so don't delete. 
        rd.unfreezeRecord(rawIndex, FREEZE_AMOUNT - 1, false);
        // asserts that the data is still there. 
        assertEq(rd.getAt(rawIndex).frozen, 1);

        //not allowed to overfreeze
        vm.expectRevert(abi.encodeWithSelector(InvalidUnfreezeAmount.selector, 1, FREEZE_AMOUNT));
        rd.unfreezeRecord(rawIndex, FREEZE_AMOUNT, true);

        // not settled yet, so dont' delete
        rd.unfreezeRecord(rawIndex, 1, false);
        assertEq(rd.getAt(rawIndex).frozen, 0);
        assertEqRecords(rd.getAt(rawIndex), Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 2));
    }

    function testUnfreezeRecord_delete() public {
        uint128 FREEZE_AMOUNT = 40;
        Record memory r = Record(100, block.timestamp + SECONDS_PER_DAY, 0, 0, 0);
        uint256 rawIndex = rd.enqueue(r.amount, r.settlementTime);
        rd.freezeRecord(rawIndex, FREEZE_AMOUNT);

        // freeze another record
        Record memory r2 = Record(80, block.timestamp + SECONDS_PER_DAY, 0, 1, 0);
        uint256 rawIndex2 = rd.enqueue(r2.amount, r2.settlementTime);
        rd.freezeRecord(rawIndex2, FREEZE_AMOUNT);

        // unfreeze 
        // hasn't settled yet, so don't delete. 
        rd.unfreezeRecord(rawIndex, FREEZE_AMOUNT - 1, false);
        // asserts that the data is still there. 
        assertEq(rd.getAt(rawIndex).frozen, 1);

        //not allowed to overfreeze
        vm.expectRevert(abi.encodeWithSelector(InvalidUnfreezeAmount.selector, 1, FREEZE_AMOUNT));
        rd.unfreezeRecord(rawIndex, FREEZE_AMOUNT, true);

        skip(SECONDS_PER_DAY);

        // settled, so delete
        rd.unfreezeRecord(rawIndex, 1, true);
        assertEq(rd.getAt(rawIndex).settlementTime, 0);
        assertEq(rd.getAt(rawIndex).frozen, 0);
    }
}
