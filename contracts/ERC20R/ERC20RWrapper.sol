/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2023 Circle Internet Financial, LTD 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

pragma solidity 0.8.20;

import {IERC20R} from "../interfaces/IERC20R.sol";
import {RecordsDeque, RecordsDequeLib, Record, Suspension} from "../util/RecordUtil.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract ERC20RWrapper is IERC20R, ERC20 {
    using RecordsDequeLib for RecordsDeque;
    using SafeCast for uint256;
    uint16 private immutable MAX_TO_CLEAN;

    struct AccountState {
        uint128 balance; // total balance including both settled and unsettled or frozen
        uint128 nonce; // incremeted every send or receive 
        uint128 cachedUnsettled; // cached amount of unsettled funds (includes frozen unsettled)
        uint128 cachedUnsettledFrozen; // cached amount of frozen funds that have not reached their original settlement time 
    }

    mapping(address => AccountState) internal _accountState;
    mapping(address => uint256) public frozen;
    mapping(address => RecordsDeque) internal _unsettledRecords;
    mapping(address => bool) public unwrapDisabled;

    modifier governanceOnly() {
        if (msg.sender != governanceAddress) {
            revert CallerMustBeGovernance(msg.sender);
        }
        _;
    }

    IERC20Metadata internal immutable baseERC20;
    uint256 internal _totalSupply; // includes settled and unsettled. 

    /**
     * Length of recoverable window after each transaction, in seconds  
     */
    uint256 public immutable recoverableWindow;

    /**
     * Address of the governance that is allowed to call freeze and closeCase 
     */
    address public governanceAddress;

    /**
     * @dev emitted after an unsettled record is spent during a transfer to help trace stolen funds.
     */
    event UnsettledRecordSpend(address indexed from, uint256 fromIndexSpent, uint256 amount);

    /**
     * @dev Can be customized by the developer
     * @param account - account just frozen
     * @param amountFrozen - amount just frozen at account
     * @param rawIndex - the index of the record in RecordDeque storage. This record must still exist in order to freeze
     */
    event Freeze(address indexed account, uint256 amountFrozen, uint256 rawIndex);

    /**
     * @dev Can be customized by the developer
     * @param recover - if true, that means a recovery happened and frozen funds have been returned to the victim. 
     * @param victim - address of the original victim
     * @param suspensions - more detail about the funds that were previously frozen 
     */
    event CaseClosed(
        bool recover,
        address indexed victim,
        Suspension[] suspensions
    );

    error UnwrapNotAllowed(address account);
    error ZeroAddressNotAllowed();
    error InsufficientSpendableFunds(address account, uint256 spendableFunds, uint256 attemptedAmount, bool unsettledIncluded);
    error CallerMustBeGovernance(address caller);
    error RecordNotFound(address account, uint256 rawIndex);
    error RecordAlreadySettled(address account, uint256 rawIndex);
    error SelfTransferNotAllowed();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 recoverableWindow_,
        address governanceAddress_,
        address baseERC20_,
        uint16 maxToClean
    ) ERC20(name_, symbol_) {
        recoverableWindow = recoverableWindow_;
        governanceAddress = governanceAddress_;
        baseERC20 = IERC20Metadata(baseERC20_);
        MAX_TO_CLEAN = maxToClean;
    }

    /**
     * Returns total supply.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @inheritdoc IERC20Metadata
     */
    function decimals() public view virtual override returns (uint8) {
        return baseERC20.decimals();
    }

    /**
     * @inheritdoc IERC20R
     */
    function baseToken() external view virtual override returns (address) {
        return address(baseERC20);
    }

    /**
     * @inheritdoc IERC20R
     */
    function balanceOf(address account, bool includeUnsettled)
        external
        view
        virtual
        override
        returns (uint256)
    {
       return _balanceOf(account, includeUnsettled);
    }

    /**
     * Defaults to not using unsettled funds
     * 
     * @inheritdoc ERC20
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balanceOf(account, false);
    }

    /**
     * Returns either the settled balance or total balance of an account.
     * @param account - the account we're querying
     * @param includeUnsettled - if false, then return just the settled balance.
     */
    function _balanceOf(address account, bool includeUnsettled) private view returns (uint256) {
        if (includeUnsettled) {
            return _accountState[account].balance;
        } else {
            (uint256 unsettledTotal,) =  _unsettledBalanceOf(account);
            return  _accountState[account].balance - unsettledTotal;
        }
    }

    /**
     * Returns the current spendable balance of the account, not including any frozen funds. 
     * @param account - account to query
     * @param includeUnsettled - if false, then return just spendable settled funds. 
     */
    function spendableBalanceOf(address account, bool includeUnsettled) public view returns (uint256) {
        if (includeUnsettled) {
            return _accountState[account].balance - frozen[account];
        } else {
            (uint256 unsettledBalance, uint256 unsettledFrozen) =  _unsettledBalanceOf(account);
            return _accountState[account].balance - unsettledBalance - (frozen[account] - unsettledFrozen);
        }
    }

    /**
     * @inheritdoc IERC20R
     */
    function nonce(address account) external view override returns (uint128) {
        return _accountState[account].nonce;
    }

    /**
     * @inheritdoc IERC20R
     */
    function wrap(uint256 amount) external override {
        // Caller must have already approved account 
        SafeERC20.safeTransferFrom(
            baseERC20,
            msg.sender,
            address(this),
            amount
        );
        _mint(msg.sender, amount);
        emit Wrap(msg.sender, amount);
    }

    /**
     * @inheritdoc IERC20R
     */
    function unwrap(uint256 amount) external override {
        if (unwrapDisabled[msg.sender]) {
            revert UnwrapNotAllowed(msg.sender);
        }

        // will fail if settled balance is insufficient 
        _burn(msg.sender, amount);

        SafeERC20.safeTransfer(
            baseERC20,
            msg.sender,
            amount
        );
        emit Unwrap(msg.sender, msg.sender, amount);
    }

    /**
     * @inheritdoc IERC20R
     */
    function unwrapTo(address to, uint256 amount) external override {
        if (unwrapDisabled[msg.sender]) {
            revert UnwrapNotAllowed(msg.sender);
        }

        _burn(msg.sender, amount);
        SafeERC20.safeTransfer(baseERC20, to, amount);

        emit Unwrap(msg.sender, to, amount);
    }

    /**
     * @inheritdoc IERC20R
     */
    function disableUnwrap() external override {
        unwrapDisabled[msg.sender] = true;
        emit UnwrapDisabled(msg.sender);
    }

    /**
     * @inheritdoc IERC20R
     */
    function transfer(
        address to,
        uint256 amount,
        bool includeUnsettled
    ) external virtual override returns (bool) {
        _transfer(msg.sender, to, amount.toUint128(), includeUnsettled);
        return true;
    }

    /**
     * Defaults to not using unsettled funds
     * 
     * @inheritdoc ERC20
     */
    function transfer(address to, uint256 value) public virtual override returns (bool) {
        _transfer(msg.sender, to, value.toUint128(), false);
        return true;
    }

    /**
     * @inheritdoc IERC20R
     */
    function transferFrom(
        address from,
        address to,
        uint256 value,
        bool includeUnsettled
    ) external virtual override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, value);
        _transfer(from, to, value.toUint128(), includeUnsettled);
        return true;
    }

    /**
     * Defaults to only using settled funds. 
     * @inheritdoc ERC20
     */
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, value);
        _transfer(from, to, value.toUint128(), false);
        return true;
    }

    /**
     * Goes through the list of records and removes records that have settled (based on timestamp). Updates cache. 
     * @param account to clean
     */
    function _clean(address account) internal virtual {
        uint128 unsettled = _accountState[account].cachedUnsettled;
        uint256 cacheIndex = _unsettledRecords[account].cacheIndex;
        uint128 unsettledFrozen = _accountState[account].cachedUnsettledFrozen;
        uint16 i = 0;
        Record memory r;

        // Delete expired records from the head of the queue. 
        // Stops when it gets to the end, or reaches MAX_TO_CLEAN, or gets to records that are not due for settlement yet. 
        while (_unsettledRecords[account].head > 0 && i < MAX_TO_CLEAN) {
            uint256 index;
            (r, index) = _unsettledRecords[account].first();
            if (r.settlementTime > block.timestamp) break; //not expired yet 
            if (r.frozen > 0) {
                // don't delete it from storage
                _unsettledRecords[account].dequeue(false);
            } else {
                // no longer needed, so can delete from storage
                _unsettledRecords[account].dequeue(true);
            }

            if (index <= cacheIndex) {
                // this has already been cached 
                unsettled -= r.amount;
                if (r.frozen > 0) { //it's been counted as part of unsettledFrozen 
                    unsettledFrozen -= r.frozen;
                }
            } else {
                // uncached but also no longer unsettled 
                cacheIndex = index;
            }
            i++;
        }

        // Now, cache any new records that haven't been cached yet. 
        r = _unsettledRecords[account].getAt(cacheIndex);
        uint256 head = _unsettledRecords[account].head;
        for (i; i < MAX_TO_CLEAN; i++) {

            if (r.next == 0) {
                break;
            }
            // cacheIndex needs to catch up
            cacheIndex = cacheIndex < head ? head : r.next;
            r = _unsettledRecords[account].getAt(cacheIndex);
            unsettled += r.amount;
            unsettledFrozen += r.frozen;
        }

        _accountState[account].cachedUnsettled = unsettled;
        // if we've deleted all of the records in the queue, set cacheIndex to 0. Otherwise, set it to where we left off. 
        _unsettledRecords[account].cacheIndex = _unsettledRecords[account].isEmpty() ? 0 : cacheIndex;
        _accountState[account].cachedUnsettledFrozen = unsettledFrozen;
    }

    /**
     * Returns unsettled balance of account
     * @param account to query
     */
    function _unsettledBalanceOf(address account)
        private
        view
        returns (uint256 unsettledTotal, uint256 unsettledFrozen)
    {
        // add up the new uncached unsettled, starting from the most recently added record. 
        uint256 cacheIndex = _unsettledRecords[account].cacheIndex;
        uint256 current = _unsettledRecords[account].tail;
        while (current > cacheIndex) {
            Record memory r = _unsettledRecords[account].getAt(current);
            if (r.settlementTime <= block.timestamp) break; //it's expired
            unsettledTotal += r.amount;
            unsettledFrozen += r.frozen;
            current = r.prev;
        }

        // if the last cached record itself is already settled, then no need to count through all the records before it
        if (_unsettledRecords[account].getAt(cacheIndex).settlementTime <= block.timestamp) {
            return (unsettledTotal, unsettledFrozen);
        }
        unsettledTotal += _accountState[account].cachedUnsettled;
        unsettledFrozen += _accountState[account].cachedUnsettledFrozen;

        // subtract out the expired records from the cached unsettled balance
        for (current = _unsettledRecords[account].head; current <= cacheIndex && current > 0;) { 
            Record memory r  = _unsettledRecords[account].getAt(current);
            if (r.settlementTime > block.timestamp) break; // not expired
            unsettledTotal -= r.amount;
            if (r.frozen > 0) {
                unsettledFrozen -= r.frozen;
            }
            current = r.next;
        }
    }

    /**
     * Mints into settled balance of account
     * @param account to mint to
     * @param amount to mint
     */
    function _mint(address account, uint256 amount) internal virtual override {
        _checkNotZeroAddress(account);
        _clean(account);
        
        _totalSupply += amount;
        _accountState[account].balance += amount.toUint128(); //goes into settled balance
    }

    /**
     * Transfers either just from the settled balance, or out of first unsettled then settled.
     * @param from - src address
     * @param to - destination address
     * @param amount to transfer
     * @param includeUnsettled if false, then sends only out of settled balance.
     */
    function _transfer(
        address from,
        address to,
        uint128 amount,
        bool includeUnsettled
    ) internal virtual {
        // there is no need to check if `from` is the zero address, because it cannot 
        // call transfer, nor would anyone have approval to spend from it. 
        _checkNotZeroAddress(to);

        // Transfering to self should not be allowed, would add confusing UX 
        if (to == from) {
            revert SelfTransferNotAllowed();
        }

        _clean(from);
        _clean(to);
        uint256 unsettledUsed = 0;

        uint256 spendable = spendableBalanceOf(from, includeUnsettled);
        if (spendable < amount) {
            revert InsufficientSpendableFunds(from, spendable, amount, includeUnsettled);
        }

        if (includeUnsettled) {
            unsettledUsed = _spendUnsettled(
                from,
                amount 
            );
        } 
     
        uint256 rawIndex = _unsettledRecords[to].enqueue(amount, block.timestamp + recoverableWindow);

        _accountState[from].balance -= amount;
        _accountState[to].balance += amount;
        _accountState[to].nonce++;
        _accountState[from].nonce++;
        emit Transfer(from, to, unsettledUsed, amount - unsettledUsed, rawIndex);
    }

    /**
     * Helper method to handle spending from unsettled balance.
     * Returns the amount of unsettled tokens, which is `amount` if the unsettled balance is greater than or equal to `amount`.
     * @param from - source address
     * @param amount to transfer
     * @return unsettledSpent - amount of unsettled funds used up 
     */
    function _spendUnsettled(
        address from,
        uint128 amount
    ) internal virtual returns (uint256 unsettledSpent) {
        uint128 remaining = amount;
        uint256 current = _unsettledRecords[from].tail;
        uint256 cacheIndex = _unsettledRecords[from].cacheIndex;
        uint128 unsettledTotal = _accountState[from].cachedUnsettled;

        // starting from the end, spend unsettled records until you've spent `amount` or ran out of unsettled records. 
        // if any of the spent records were cached, update cache accordingly. 
        while (true) {
            Record memory r = _unsettledRecords[from].getAt(current);
            if (r.settlementTime <= block.timestamp) break; //it's expired
            uint128 toSpend = Math.min(remaining, r.amount - r.frozen).toUint128();

            if (toSpend > 0) {
                remaining -= toSpend;

                if (r.frozen == 0 && toSpend == r.amount) {
                    // delete 
                    _unsettledRecords[from].deleteAt(current);
                } else {
                    _unsettledRecords[from].decrementRecordAmount(current, toSpend);
                }
                emit UnsettledRecordSpend(from, current, toSpend);

                if (current <= cacheIndex) {
                    unsettledTotal -= toSpend;
                }
            }
            if (r.prev == 0 || remaining == 0) break;
            current = r.prev;
        }
        unsettledSpent = amount - remaining;
        _accountState[from].cachedUnsettled = unsettledTotal;

        // if queue is empty, set cacheIndex to 0. 
        if (_unsettledRecords[from].isEmpty()) {
            _unsettledRecords[from].cacheIndex = 0;
        }
        // if end of queue was cached and now deleted, then update the cache index to the new tail. 
        else if (_unsettledRecords[from].tail < cacheIndex) {
            _unsettledRecords[from].cacheIndex = _unsettledRecords[from].tail;
        }
    }

    /**
     * Burns amount in account; must come from settled funds.
     * @param account to burn from
     * @param amount to burn
     */
    function _burn(address account, uint256 amount) internal virtual override {
        _checkNotZeroAddress(account);
        _clean(account);

        (uint256 unsettledBalance, uint256 unsettledFrozen) = _unsettledBalanceOf(account);
        uint256 spendableSettled = _accountState[account].balance - unsettledBalance - (frozen[account] - unsettledFrozen);

        if (spendableSettled < amount) {
            revert InsufficientSpendableFunds(account, spendableSettled, amount, false);
        }
        _accountState[account].balance -= amount.toUint128();
        _totalSupply -= amount;
    }

    /**
     * @dev Example of a freeze function, but this can be implemented in other however way the dev would like. 
     * @param freezes - contains the info of all the accounts and amounts that need to be frozen. 
     */
    function freeze(
        Suspension[] memory freezes
    ) external virtual governanceOnly returns (bool) {
        for (uint256 i = 0; i < freezes.length; i++) {
            uint256 rawIndex = freezes[i].rawIndex;
            address account = freezes[i].account;
            uint128 amount = freezes[i].amount;
            Record memory r = _unsettledRecords[account].getAt(rawIndex);
            if (r.settlementTime == 0) {
                revert RecordNotFound(account, rawIndex);
            }

            if (r.settlementTime <= block.timestamp) {
                revert RecordAlreadySettled(account, rawIndex);
            }

            if (rawIndex <= _unsettledRecords[account].cacheIndex) {
                _accountState[account].cachedUnsettledFrozen += amount;
            }

            // checks that there is enough to freeze 
            _unsettledRecords[account].freezeRecord(rawIndex, amount);
            frozen[account] += amount;
            emit Freeze(account, amount, rawIndex);
        }
        return true;
    }

    /**
     * @dev called when a case is closed after a freeze. 
     * @param recover - if true, then returns the funds back to the victim. 
     * @param victim - address of the victim who will receive the stolen funds. 
     * @param freezes - contains the info of all accounts and amounts that need to be frozen (and potentially recovered). 
     * All items must already be frozen in order to be unfrozen. 
     */
    function closeCase(
        bool recover,
        address victim,
        Suspension[] memory freezes
    ) external virtual governanceOnly returns (bool) {

        for (uint256 i = 0; i < freezes.length; i++) {
            uint256 rawIndex = freezes[i].rawIndex;
            address account = freezes[i].account;
            uint128 amount = freezes[i].amount;
            Record memory r = _unsettledRecords[account].getAt(rawIndex);

            if (r.settlementTime == 0) {
                revert RecordNotFound(account, rawIndex);
            }
            uint256 head = _unsettledRecords[account].head;

            // checks that there is enough frozen to unfreeze. only deletes if past settlement time and is before head. 
            // should also delete if queue is empty 
            bool del = rawIndex < head || _unsettledRecords[account].isEmpty();
            _unsettledRecords[account].unfreezeRecord(rawIndex, amount, del);

            frozen[account] -= amount;
            // remove from cachedUnsettledFrozen
            if (rawIndex <= _unsettledRecords[account].cacheIndex) { 
                _accountState[account].cachedUnsettledFrozen -= amount;
            }

            if (recover) {
                // spend the now-unfrozen record 
                if (!del) { 
                    _unsettledRecords[account].decrementRecordAmount(rawIndex, amount);
                    if (rawIndex <= _unsettledRecords[account].cacheIndex) {
                        _accountState[account].cachedUnsettled -= amount;
                    }
                }
                uint256 toRawIndex = _unsettledRecords[victim].enqueue(amount, block.timestamp + recoverableWindow);

                _accountState[account].balance -= amount;
                _accountState[victim].balance += amount;
                _accountState[account].nonce++;
                _accountState[victim].nonce++;
                bool pastSettlement = r.settlementTime <= block.timestamp;
                emit Transfer(account, victim, pastSettlement ? 0 : amount, pastSettlement ? amount : 0, toRawIndex);
            }
        }
        emit CaseClosed(recover, victim, freezes);
        return true;
    }

    /**
     * @dev helper function to check that the address is not zero. 
     * @param account - address to check 
     */
    function _checkNotZeroAddress(address account) private pure {
        if (account == address(0)) {
            revert ZeroAddressNotAllowed();
        }
    }
}
