/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2023 Circle Internet Financial, LTD 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

pragma solidity 0.8.20;

struct RecordsDeque {
    mapping(uint256 => Record) queue;
    uint256 head;
    uint256 tail;
    uint256 cacheIndex;
}

struct Record {
    uint128 amount;
    uint256 settlementTime; //the block at which it becomes fully settled
    uint128 frozen;

    // for doubly linked list 
    uint256 prev;
    uint256 next; 
}

struct Suspension {
    address account;
    uint256 rawIndex;
    uint128 amount;
}

/**
 * Queue that allows enqueing at the back, but dequeing from either to front or the back (pop).
 * Implemented as a doubly linked list, because in some cases records may be deleted from the middle of the queue. 
 */
library RecordsDequeLib {
    error NoRecords();
    error InvalidUnfreezeAmount(uint256 currentFrozenInRecord, uint256 unfreezeAmount);
    error InvalidFreezeAmount(uint256 remainingToFreeze, uint256 freezeAmount);
    error InvalidSubtractedValue(uint256 rawIndex, uint256 amount, uint256 subtractedValue);
    error SentinelNodeNotDeletable();

    /**
     * Returns the index of the next Record if it were to be enqueued to the RecordDeque. 
     * frozen records that don't count as part of the unsettled queue would only be before rd.head, not after rd.tail. 
     * so we can safely assume that the index of the next enqueued record would be tail + 1. 
     * @param rd RecordsDeque
     */
    function nextRawIndex(RecordsDeque storage rd) public view returns (uint256) {
        return rd.tail + 1;
    }

    /**
     * Appends a new record with the specified amount and settlementTime fields to the back of the deque. 
     * Automatically fills in frozen=0, prev, and next. 
     * @param rd Records Deque
     * @param amount Record amount 
     * @param settlementTime of the Record
     */
    function enqueue(RecordsDeque storage rd, uint128 amount, uint256 settlementTime) public returns (uint256 rawIndex){
        Record memory r = Record(amount, settlementTime, 0, rd.tail, 0);
        
        if (rd.head == 0) {
            rd.head = rd.tail + 1;
            r.prev = 0;
        }

        // Keep sentinel node untouched
        if (rd.tail != 0) {
            rd.queue[rd.tail].next = rd.tail + 1;
        }

        rd.tail++;
        rd.queue[rd.tail] = r;

        rawIndex = rd.tail;
    }

    /**
     * Adjusts record's amount by subtracting the specified value. 
     * @param rd RecordsDeque
     * @param rawIndex of record to decrement amount of 
     * @param subtractedValue amount by which to decrement 
     */
    function decrementRecordAmount(RecordsDeque storage rd, uint256 rawIndex, uint128 subtractedValue) public {
        if (subtractedValue > rd.queue[rawIndex].amount) {
            revert InvalidSubtractedValue(rawIndex, rd.queue[rawIndex].amount, subtractedValue);
        }
        rd.queue[rawIndex].amount -= subtractedValue;
    }

    /**
     * Deletes a record from the doubly linked list. 
     * @param rd RecordsDeque
     * @param rawIndex of the record to delete 
     */
    function deleteAt(RecordsDeque storage rd, uint256 rawIndex) public {
        if (rawIndex == 0) revert SentinelNodeNotDeletable();
        uint256 next = rd.queue[rawIndex].next;
        uint256 prev = rd.queue[rawIndex].prev; 

        if (rd.tail == rawIndex && rd.tail != rd.head) {
            rd.tail = prev;
        }
        if (rd.head == rawIndex) {
            rd.head = next;
        }
        
        // Only update prev and next if it's not the sentinel node 
        if (prev != 0) {
            rd.queue[prev].next = next;
        }
        if (next != 0) {
            rd.queue[next].prev = prev;
        }

        delete rd.queue[rawIndex];
    }

    /**
     * Removes the first Record from the deque. 
     * @param rd RecordsDeque
     * @param del if true, the delete from storage. if false, update pointers but don't delete from storage.
     */
    function dequeue(RecordsDeque storage rd, bool del) public {
        _requireDequeNotEmpty(rd);
        uint256 next = rd.queue[rd.head].next;
        if (del) {
            delete rd.queue[rd.head];
        } // otherwise it doesn't change any of the values 
        rd.head = next;
        rd.queue[next].prev = 0;
    }

    /**
     * Returns the first Record part of the "unsettled records". 
     * @param rd RecordsDeque
     */
    function first(RecordsDeque storage rd) public view returns (Record memory r, uint256 rawIndex) {
        _requireDequeNotEmpty(rd);
        r = rd.queue[rd.head];
        rawIndex = rd.head;
    }

    /**
     * Returns the Record at the given rawIndex. 
     * @param rd RecordsDeque
     * @param rawIndex of the record to fetch
     */
    function getAt(RecordsDeque storage rd, uint256 rawIndex) public view returns (Record memory r) {
        r = rd.queue[rawIndex];
    }

    /**
     * This function will freeze freezeAmount at record rawIndex. 
     * It first checks that there's enough unfrozen value in the record to freeze in the first place. 
     * It then increments the frozen amount by freezeAmount. 
     * @param rd RecordsDeque
     * @param rawIndex of the record to be frozen
     * @param freezeAmount to freeze in the record 
     */
    function freezeRecord(RecordsDeque storage rd, uint256 rawIndex, uint128 freezeAmount) public {
        uint256 leftToFreeze = rd.queue[rawIndex].amount - rd.queue[rawIndex].frozen;
        if (freezeAmount > leftToFreeze) {
            revert InvalidFreezeAmount(leftToFreeze, freezeAmount);
        }
        rd.queue[rawIndex].frozen += freezeAmount;
    }

    /**
     * This function will unfreeze unfreezeAmount at record rawIndex. 
     * It first checks that there's enough frozen in the first place to unfreeze. 
     * If it unfreezes the remainder of the frozen amount in the record and the record is past settlement, 
     * then it will delete the record. Otherwise, it will simply adjust the frozen amount noted in the record. 
     * @param rd - Records Deque
     * @param rawIndex - index of record
     * @param unfreezeAmount - amount to unfreeze at record 
     * @param del - whether to delete or not. This should only be true if it's not part of the doubly linked list. 
     */
    function unfreezeRecord(RecordsDeque storage rd, uint256 rawIndex, uint128 unfreezeAmount, bool del) public   {
        uint256 frozen = rd.queue[rawIndex].frozen;
        if (unfreezeAmount > frozen) {
            revert InvalidUnfreezeAmount(frozen, unfreezeAmount);
        }
        if (del) {
                delete rd.queue[rawIndex];
        } else {
            rd.queue[rawIndex].frozen -= unfreezeAmount;
        }
    }

    /**
     * Returns whether the queue is empty. 
     * @param rd RecordsDeque
     */
    function isEmpty(RecordsDeque storage rd) public view returns (bool) {
        return rd.head == 0;
    }

    function _requireDequeNotEmpty(RecordsDeque storage rd) private view {
        if (rd.head == 0) {
            revert NoRecords();
        }
    }
}
