/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2023 Circle Internet Financial, LTD 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

pragma solidity 0.8.20;

import {Suspension, Record, RecordsDeque} from "../contracts/util/RecordUtil.sol";
import {Test} from "forge-std/src/Test.sol";
import {ERC20RWrapper} from "../contracts/ERC20R/ERC20RWrapper.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SECONDS_PER_DAY} from "./utils/constants.sol";

// solhint-disable var-name-mixedcase

contract ERC20RWrapperTest is Test {
    ERC20RWrapper private rtoken;
    address private governance = makeAddr("governance");
    MockERC20 private erc20 = new MockERC20();
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private victim = makeAddr("victim");

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 unsettledTransferred,
        uint256 settledTransferred,
        uint256 rawIndex
    );
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event UnwrapDisabled(address indexed account);
    event Wrap(address indexed dst, uint256 amount);
    event Unwrap(address indexed src, address indexed to, uint256 amount);
    event Freeze(address indexed account, uint256 amountFrozen, uint256 rawIndex);
    event CaseClosed(
        bool recover,
        address indexed victim,
        Suspension[] suspensions
    );
    event UnsettledRecordSpend(address indexed from, uint256 fromIndexSpent, uint256 amount);

    error UnwrapNotAllowed(address account);
    error ZeroAddressNotAllowed();
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);
    error NegativeAllowance(address owner, address spender, uint256 currentAllowance, uint256 subtraction);
    error InsufficientSpendableFunds(address account, uint256 spendableFunds, uint256 attemptedAmount, bool unsettledIncluded);
    error CallerMustBeGovernance(address caller);
    error RecordNotFound(address account, uint256 rawIndex);
    error RecordAlreadySettled(address account, uint256 rawIndex);
    error InvalidUnfreezeAmount(uint256 currentFrozenInRecord, uint256 unfreezeAmount);
    error InvalidFreezeAmount(uint256 remainingToFreeze, uint256 freezeAmount);
    
    function setUp() public {
        rtoken = new ERC20RWrapper("Recoverable ERC20", "ERC20R", SECONDS_PER_DAY, governance, address(erc20), 100);
    }

    function testName() public {
        assertEq(rtoken.name(), "Recoverable ERC20");
    }

    function testSymbol() public {
        assertEq(rtoken.symbol(), "ERC20R");
    }

    function testRecoverableWindow() public {
        assertEq(rtoken.recoverableWindow(), SECONDS_PER_DAY);
    }

    function testBaseToken() public {
        assertEq(rtoken.baseToken(), address(erc20));
    }

    function testGovernanceAddress() public {
        assertEq(rtoken.governanceAddress(), governance);
    }

    function testDecimals() public {
        assertEq(rtoken.decimals(), erc20.decimals());
    }

    function _wrap(address account, uint256 amount) private {
        erc20.mint(account, amount);
        vm.startPrank(account);
        erc20.approve(address(rtoken), amount);
        rtoken.wrap(amount);
        vm.stopPrank();
    }

    function testWrap_Fail_NoApproval() public {
        erc20.mint(alice, 100);
        vm.startPrank(alice);
        vm.expectRevert("ERC20: insufficient allowance");
        rtoken.wrap(100);
        vm.stopPrank();
    }

    function testWrap_Fail_InsufficientBalance() public {
        erc20.mint(alice, 50);
        vm.startPrank(alice);
        erc20.approve(address(rtoken), 100);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        rtoken.wrap(100);
        vm.stopPrank();
    }

    function testWrap_Success() public {
        erc20.mint(alice, 100);
        assertEq(rtoken.totalSupply(), 0);
        vm.startPrank(alice);
        erc20.approve(address(rtoken), 100);
        vm.expectEmit(address(rtoken));
        emit Wrap(alice, 100);
        rtoken.wrap(100);
        vm.stopPrank();
        assertEq(rtoken.totalSupply(), 100);
    }

    function testBalanceOf_PostWrap() public {
        assertEq(rtoken.balanceOf(alice, true), 0);
        assertEq(rtoken.balanceOf(alice, false), 0);
        _wrap(alice, 100);
        assertEq(rtoken.balanceOf(alice, true), 100);
        assertEq(rtoken.balanceOf(alice, false), 100);
    }

    function testERC20BalanceOf() public {
        assertEq(rtoken.balanceOf(alice, true), 0);
        assertEq(rtoken.balanceOf(alice), 0);
        _wrap(alice, 100);
        assertEq(rtoken.balanceOf(alice, true), 100);
        assertEq(rtoken.balanceOf(alice), 100);
    }

    function testSpendableBalanceOf() public {
        _wrap(alice, 100);
        _wrap(bob, 100);
        _transferSettled(alice, bob, 10);
        _transferSettled(bob, alice, 10);
        _freeze2(Suspension(alice, 1, 5), Suspension(bob, 1, 10));
        assertEq(rtoken.spendableBalanceOf(alice, true), 95);
        assertEq(rtoken.spendableBalanceOf(alice, false), 90);
    }

    function testTransfer_Settled_Success() public {
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        assertEq(rtoken.nonce(bob), 0);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);

        rtoken.transfer(bob, TRANSFER_AMOUNT, false);
        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, false), 0);
        skip(SECONDS_PER_DAY);
        assertEq(rtoken.balanceOf(bob, false), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.nonce(bob), 1);
        assertEq(rtoken.nonce(alice), 1);
        vm.stopPrank();
    }

    
    function testAsERC20Transfer() public {
        // should be same as transfer settled 
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        assertEq(rtoken.nonce(bob), 0);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);

        rtoken.transfer(bob, TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, false), 0);
        skip(SECONDS_PER_DAY);
        assertEq(rtoken.balanceOf(bob, false), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.nonce(bob), 1);
        assertEq(rtoken.nonce(alice), 1);
        vm.stopPrank();
    }   

    function testTransfer_Settled_Fail_InsufficientBalance() public {
        uint256 ALICE_INITIAL = 50;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        assertEq(rtoken.nonce(bob), 0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientSpendableFunds.selector, alice, ALICE_INITIAL, TRANSFER_AMOUNT, false));
        rtoken.transfer(bob, TRANSFER_AMOUNT, false);
        vm.stopPrank();
    }   

    function testTransfer_Settled_Fail_Unsettled() public {
        uint256 ALICE_INITIAL = 50;
        uint256 TRANSFER_AMOUNT = 40;
        _wrap(alice, ALICE_INITIAL);

        // unsettle by sending back to herself
        vm.startPrank(alice);
        rtoken.transfer(alice, ALICE_INITIAL, true);

        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL);
        assertEq(rtoken.balanceOf(alice, false), 0);

        // try to transferSettled to bob, fails.
        vm.expectRevert(abi.encodeWithSelector(InsufficientSpendableFunds.selector, alice, 0, TRANSFER_AMOUNT, false));
        rtoken.transfer(bob, TRANSFER_AMOUNT, false);

        //fast forward so it settles
        skip(SECONDS_PER_DAY);

        // successfully send to bob 
        rtoken.transfer(bob, TRANSFER_AMOUNT, false);
        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    // also does clean 
    function testTransfer_Unsettled_SettledTokens_Success() public {
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);

        // includeUnsettled = true 
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        _checkBalances(alice, 0, ALICE_INITIAL - TRANSFER_AMOUNT);
        _checkBalances(bob, TRANSFER_AMOUNT, 0);
        skip(SECONDS_PER_DAY);
        _checkBalances(bob, 0, TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function testTransfer_QueueIndex() public {
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 10;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);

        // includeUnsettled = true 
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);

        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 2);

        // includeUnsettled = true 
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        vm.stopPrank();

        //bob sends back to alice
        vm.startPrank(bob);
        vm.expectEmit();
        emit Transfer(bob, alice, TRANSFER_AMOUNT, 0, 1);
        rtoken.transfer(alice, TRANSFER_AMOUNT, true);
        vm.stopPrank();

        //alice sends back to bob
        vm.startPrank(alice);
        vm.expectEmit();
        emit Transfer(alice, bob, TRANSFER_AMOUNT, 0, 2);
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        vm.stopPrank();

    }

    function testTransfer_Unsettled_UnsettledTokens_Success() public {
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        
        // unsettle
        vm.expectEmit();
        emit Transfer(alice, alice, 0, ALICE_INITIAL, 1);
        rtoken.transfer(alice, ALICE_INITIAL, true);

        vm.expectEmit();
        emit UnsettledRecordSpend(alice, 1, TRANSFER_AMOUNT);

        vm.expectEmit();
        emit Transfer(alice, bob, TRANSFER_AMOUNT, 0, 1);

        // includeUnsettled = true 
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function testTransfer_Unsettled_someSettled_Success() public {
        uint256 ALICE_INITIAL = 100;
        uint256 ALICE_UNSETTLED = 40;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);

        // unsettle some 
        rtoken.transfer(alice, ALICE_UNSETTLED, false);

        // should transfer all of the unsettled 
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, ALICE_UNSETTLED, TRANSFER_AMOUNT - ALICE_UNSETTLED, 1);


        // includeUnsettled = true 
        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, false), 0);
        skip(SECONDS_PER_DAY);
        assertEq(rtoken.balanceOf(bob, false), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function testClean() public {
        uint256 ALICE_INITIAL = 100;
        uint256 TRANSFER_AMOUNT = 60;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);

        rtoken.transfer(bob, TRANSFER_AMOUNT, true);
        skip(SECONDS_PER_DAY);

        rtoken.transfer(bob, 10, true);
        vm.stopPrank();
    }

    function testApprove_Success() public {
        uint256 ALLOWANCE = 30;
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Approval(alice, bob, ALLOWANCE);
        rtoken.approve(bob, ALLOWANCE);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE);
        vm.stopPrank();
    }

    function testApprove_Fail_SpenderZeroAddress() public {
        uint256 ALLOWANCE = 30;
        vm.startPrank(alice);
        vm.expectRevert("ERC20: approve to the zero address");
        rtoken.approve(address(0), ALLOWANCE);
        vm.stopPrank();
    }

    function testTransferFrom_Fail_ReceiverIsZeroAddress() public {
        vm.startPrank(alice);
        rtoken.approve(address(this), type(uint).max);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ZeroAddressNotAllowed.selector));
        rtoken.transferFrom(alice, address(0), 1, true);
    }

    function testTransferFrom_Fail_NotApproved() public {
        uint256 AMOUNT = 30;
        vm.expectRevert("ERC20: insufficient allowance");
        rtoken.transferFrom(alice, bob, AMOUNT, true);
    }

    function testTransferFrom_Fail_NotEnoughApproved() public {
        uint256 AMOUNT = 30;
        uint256 APPROVAL_AMOUNT = 10;
        vm.startPrank(alice);
        rtoken.approve(address(this), APPROVAL_AMOUNT);
        vm.stopPrank();
        vm.expectRevert("ERC20: insufficient allowance");
        rtoken.transferFrom(alice, bob, AMOUNT, true);
    }

    function testTransferFrom_Success() public {
        uint256 ALICE_INITIAL = 30;
        uint256 TRANSFER_AMOUNT = 10;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        rtoken.approve(address(this), type(uint).max);
        vm.stopPrank();

        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);
        rtoken.transferFrom(alice, bob, TRANSFER_AMOUNT, true);

        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, false), 0);
        skip(SECONDS_PER_DAY);
        assertEq(rtoken.balanceOf(bob, false), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.nonce(bob), 1);
        assertEq(rtoken.totalSupply(), ALICE_INITIAL);
    }

    function testERC20TransferFrom_Success() public {
        uint256 ALICE_INITIAL = 30;
        uint256 TRANSFER_AMOUNT = 10;
        _wrap(alice, ALICE_INITIAL);
        vm.startPrank(alice);
        rtoken.approve(address(this), type(uint256).max);
        vm.stopPrank();
        vm.expectEmit(address(rtoken));
        emit Transfer(alice, bob, 0, TRANSFER_AMOUNT, 1);
        rtoken.transferFrom(alice, bob, TRANSFER_AMOUNT);

        assertEq(rtoken.balanceOf(alice, true), ALICE_INITIAL - TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, false), 0);
        skip(SECONDS_PER_DAY);
        assertEq(rtoken.balanceOf(bob, false), TRANSFER_AMOUNT);
        assertEq(rtoken.balanceOf(bob, true), TRANSFER_AMOUNT);
        assertEq(rtoken.nonce(bob), 1);
        assertEq(rtoken.totalSupply(), ALICE_INITIAL);
    }

    function testIncreaseAllowance_Success() public {
        uint256 ALLOWANCE = 30;
        uint256 TOPUP = 15;
        vm.startPrank(alice);
        rtoken.approve(bob, ALLOWANCE);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE);
        rtoken.increaseAllowance(bob, TOPUP);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE + TOPUP);
        vm.stopPrank();
    }

    function testDecreaseAllowance_Success() public {
        uint256 ALLOWANCE = 30;
        uint256 SUBTRACTED_VALUE = 15;
        vm.startPrank(alice);
        rtoken.approve(bob, ALLOWANCE);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE);
        rtoken.decreaseAllowance(bob, SUBTRACTED_VALUE);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE - SUBTRACTED_VALUE);
        vm.stopPrank();
    }

    function testDecreaseAllowance_Fail_NegativeAllowance() public {
        uint256 ALLOWANCE = 30;
        uint256 SUBTRACTED_VALUE = 45;
        vm.startPrank(alice);
        rtoken.approve(bob, ALLOWANCE);
        assertEq(rtoken.allowance(alice, bob), ALLOWANCE);
        vm.expectRevert("ERC20: decreased allowance below zero");
        rtoken.decreaseAllowance(bob, SUBTRACTED_VALUE);
        vm.stopPrank();
    }

    function testUnwrap_Success() public {
        uint256 amount = 100;
        _wrap(alice, amount);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Unwrap(alice, alice, amount);
        rtoken.unwrap(amount);
        assertEq(erc20.balanceOf(alice), amount);
        assertEq(rtoken.balanceOf(alice, true), 0);
        vm.stopPrank();
    }

    function testUnwrap_Unsettled() public {
        uint256 amount = 100;

        _wrap(alice, amount);
        vm.startPrank(alice);
        rtoken.transfer(bob, amount, false);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientSpendableFunds.selector, bob, 0, amount, false));
        rtoken.unwrap(amount);

        skip(SECONDS_PER_DAY);

        rtoken.unwrap(amount);
        assertEq(erc20.balanceOf(bob), amount);
        assertEq(rtoken.balanceOf(bob, true), 0);
        vm.stopPrank();
    }

    function testUnwrapTo_Success() public {
        uint256 amount = 100;
        _wrap(alice, amount);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit Unwrap(alice, bob, amount);
        rtoken.unwrapTo(bob, amount);
        assertEq(erc20.balanceOf(bob), amount);
        assertEq(erc20.balanceOf(alice), 0);
        assertEq(rtoken.balanceOf(alice, true), 0);
    }

    function testDisableUnwrap_Success() public {
        uint256 amount = 100;
        _wrap(alice, amount);
        vm.startPrank(alice);
        vm.expectEmit(address(rtoken));
        emit UnwrapDisabled(alice);
        rtoken.disableUnwrap();
        vm.expectRevert(abi.encodeWithSelector(UnwrapNotAllowed.selector, alice));
        rtoken.unwrap(amount);
        vm.expectRevert(abi.encodeWithSelector(UnwrapNotAllowed.selector, alice));
        rtoken.unwrapTo(bob, amount);
        vm.stopPrank();
    }

    function testFreeze_Success() public {
        uint256 initial = 100;
        _wrap(alice, initial);
        _wrap(bob, initial);

        // unsettle
        vm.startPrank(alice);
        rtoken.transfer(bob, initial, false);
        vm.stopPrank();
        vm.startPrank(bob);
        rtoken.transfer(alice, initial, false);
        vm.stopPrank();
        assertEq(rtoken.balanceOf(bob, true), initial);
        assertEq(rtoken.balanceOf(bob, false), 0);

        // freeze
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        vm.startPrank(governance);
        vm.expectEmit();
        emit Freeze(alice, aliceAmount, 1);
        vm.expectEmit();
        emit Freeze(bob, bobAmount, 1);

        assertEq(rtoken.freeze(freezes), true);
        assertEq(rtoken.frozen(alice), aliceAmount);
        assertEq(rtoken.frozen(bob), bobAmount);
        vm.stopPrank();

        skip(SECONDS_PER_DAY);
        // unsettled funds that were NOT frozen should settled
        assertEq(rtoken.balanceOf(alice, false), initial);
        assertEq(rtoken.balanceOf(alice, true), initial);
    }

    function testFreeze_Fail_NotGovernance() public {
        // freeze
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        vm.expectRevert(abi.encodeWithSelector(CallerMustBeGovernance.selector, address(this)));
        rtoken.freeze(freezes);
    }


    function testFreeze_Fail_InvalidFreezeAmount() public {
        uint256 initial = 100;
        _wrap(alice, initial);
        _wrap(bob, initial);

        // unsettle
        vm.startPrank(alice);
        rtoken.transfer(bob, initial, false);
        vm.stopPrank();
        vm.startPrank(bob);
        rtoken.transfer(alice, initial, false);
        vm.stopPrank();
        assertEq(rtoken.balanceOf(bob, true), initial);
        assertEq(rtoken.balanceOf(bob, false), 0);

        // freeze
        uint128 aliceAmount = 50;
        uint128 bobAmount = 150;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidFreezeAmount.selector, initial, bobAmount));
        rtoken.freeze(freezes);
        vm.stopPrank();
    }

    function testFreeze_Fail_AlreadySettled() public {
        uint256 initial = 100;
        _wrap(alice, initial);
        _wrap(bob, initial);

        // unsettle
        vm.startPrank(alice);
        rtoken.transfer(bob, initial, false);
        vm.stopPrank();
        vm.startPrank(bob);
        rtoken.transfer(alice, initial, false);
        vm.stopPrank();
        assertEq(rtoken.balanceOf(bob, true), initial);
        assertEq(rtoken.balanceOf(bob, false), 0);

        skip(SECONDS_PER_DAY);

        // freeze
        uint128 aliceAmount = 50;
        uint128 bobAmount = 150;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(RecordAlreadySettled.selector, alice, 1));
        rtoken.freeze(freezes);
        vm.stopPrank();
    }

    function testFreeze_Fail_InvalidIndex() public {
        _wrap(alice, 100);
        _wrap(alice, 100);
        _wrap(alice, 100);
        _wrap(bob, 100);
        _transferSettled(alice, bob, 10);
        _transferSettled(bob, alice, 10);
        vm.expectRevert(abi.encodeWithSelector(RecordNotFound.selector, alice, 2));
        Suspension[] memory freezes = new Suspension[](1);
        freezes[0] = Suspension(alice, 2, 10);
        vm.startPrank(governance);
        rtoken.freeze(freezes);
        vm.stopPrank();
    }

    function testTransfer_Unsettled_Fail_Frozen() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        uint256 transferAmount = 60;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientSpendableFunds.selector, alice, initial - aliceAmount, transferAmount, true));
       
        rtoken.transfer(bob, transferAmount, true);
        vm.stopPrank();
    } 

    function testTransfer_Settled_Fail_Frozen() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        uint256 transferAmount = 60;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        skip(SECONDS_PER_DAY);
        _checkBalances(alice, 0, initial);
        _checkBalances(bob, 0, initial);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientSpendableFunds.selector, alice, initial-aliceAmount, transferAmount, false));

        rtoken.transfer(bob, transferAmount, false);
        vm.stopPrank();
    }

    function _wrapUnsettleFreeze(uint256 initial, Suspension[] memory freezes) private {
        for (uint i = 0; i < freezes.length; i++) {
            _wrap(freezes[i].account, initial);
            vm.startPrank(freezes[i].account);
            rtoken.transfer(freezes[i].account, initial, false);
            vm.stopPrank();
        }

        _freeze(freezes);
    }

    function testCloseCase_Success_noRecovery() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        // close case
        vm.startPrank(governance);
        vm.expectEmit();
        emit CaseClosed(false, victim, freezes);
        rtoken.closeCase(false, victim, freezes);
        assertEq(rtoken.frozen(alice), 0);
        assertEq(rtoken.balanceOf(alice, true), initial);
        assertEq(rtoken.balanceOf(alice, false), 0);
        assertEq(rtoken.frozen(bob), 0);
        assertEq(rtoken.balanceOf(bob, true), initial);
        assertEq(rtoken.balanceOf(bob, false), 0);
        vm.stopPrank();
    }

    function testCloseCase_Fail_RecordNotFound() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        Suspension[] memory closing = new Suspension[](2);
        closing[0] = Suspension(alice, 1, aliceAmount);
        closing[1] = Suspension(bob, 2, bobAmount);

        // close case
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(RecordNotFound.selector, bob, 2));
        rtoken.closeCase(false, victim, closing);
        vm.stopPrank();
    }

    function testCloseCase_Success_Recovery() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        // close case
        vm.startPrank(governance);
        vm.expectEmit();
        emit CaseClosed(true, victim, freezes);
        rtoken.closeCase(true, victim, freezes);
        assertEq(rtoken.frozen(alice), 0);
        assertEq(rtoken.balanceOf(alice, true), initial - aliceAmount);
        assertEq(rtoken.balanceOf(alice, false), 0);
        assertEq(rtoken.frozen(bob), 0);
        assertEq(rtoken.balanceOf(bob, true), initial - bobAmount);
        assertEq(rtoken.balanceOf(bob, false), 0);

        assertEq(rtoken.balanceOf(victim, true), aliceAmount + bobAmount);
        assertEq(rtoken.balanceOf(victim, false), 0);
        vm.stopPrank();
    }

    function assertEqRecords(Record memory r1, Record memory r2) private {
        assertEq(r1.amount, r2.amount);
        assertEq(r1.settlementTime, r2.settlementTime);
        assertEq(r1.frozen, r2.frozen);
        assertEq(r1.prev, r2.prev);
        assertEq(r1.next, r2.next);
    }

    function testCloseCase_Success_Recovery_unclean() public {
        // freeze
        uint128 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;

        _wrap(alice, initial);
        _transferSettled(alice, alice, initial - 2);
        _transferSettled(alice, alice, 2);

        _wrap(bob, initial);
        _transferSettled(bob, bob, initial-2);
        _transferSettled(bob, bob, 2);

        _freeze2(Suspension(alice, 1, aliceAmount), Suspension(bob, 1, bobAmount));

        skip(SECONDS_PER_DAY);
        // it thinks unsettled balance is 98.... when it actually should be 0 
        _checkBalances(alice, 0, initial);
        // now, there will be some old records still in the queue 
        // close case
        _closeCase2(Suspension(alice, 1, aliceAmount), Suspension(bob, 1, bobAmount - 1), true, victim, false);

        assertEq(rtoken.frozen(alice), 0);
        _checkBalances(alice, 0, initial - aliceAmount);

        assertEq(rtoken.frozen(bob), 1);
        _checkBalances(bob, 0, initial - bobAmount + 1);

        assertEq(rtoken.balanceOf(victim, true), aliceAmount + bobAmount - 1);
        assertEq(rtoken.balanceOf(victim, false), 0);
    }

    function testCloseCase_Fail_NotGovernance() public {
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        vm.expectRevert(abi.encodeWithSelector(CallerMustBeGovernance.selector, address(this)));
        rtoken.closeCase(true, victim, freezes);
    }

    function testCloseCase_Fail_FreezingMoreThanFrozenBalance() public {
        // freeze
        uint256 initial = 100;
        uint128 aliceAmount = 50;
        uint128 bobAmount = 30;
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = Suspension(alice, 1, aliceAmount);
        freezes[1] = Suspension(bob, 1, bobAmount);
        _wrapUnsettleFreeze(initial, freezes);

        // close case
        Suspension[] memory closing = new Suspension[](2);
        closing[0] = Suspension(alice, 1, aliceAmount + 1);
        closing[1] = Suspension(bob, 1, bobAmount);

        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidUnfreezeAmount.selector, aliceAmount, aliceAmount + 1));
        rtoken.closeCase(true, victim, closing);
        vm.stopPrank();
    }

    function _transferSettled(address from, address to, uint256 amount) private {
        vm.startPrank(from);
        rtoken.transfer(to, amount, false);
        vm.stopPrank();
    }

    function _transferAny(address from, address to, uint256 amount) private {
        vm.startPrank(from);
        rtoken.transfer(to, amount, true);
        vm.stopPrank();
    }

    function _checkBalances(address account, uint256 unsettled, uint256 settled) private  {
        assertEq(rtoken.balanceOf(account), settled);
        assertEq(rtoken.balanceOf(account, true), settled + unsettled);
    }

    function _freeze2(Suspension memory s1, Suspension memory s2) private {
        Suspension[] memory freezes = new Suspension[](2);
        freezes[0] = s1;
        freezes[1] = s2;
        _freeze(freezes);
    }

    function _freeze(Suspension[] memory freezes) private {
        uint256[] memory frozenBefore = new uint256[](freezes.length);
        for (uint i = 0; i < freezes.length; i++) {
            frozenBefore[i] = rtoken.frozen(freezes[i].account);
            vm.expectEmit();
            emit Freeze(freezes[i].account, freezes[i].amount, freezes[i].rawIndex);
        }
        vm.startPrank(governance);

        assertEq(rtoken.freeze(freezes), true);
        vm.stopPrank();
        for (uint i = 0; i < freezes.length; i++) {
            assertEq(rtoken.frozen(freezes[i].account), frozenBefore[i] + freezes[i].amount);
        }
    }

    function _closeCase(Suspension[] memory cases, bool recover, address victim_, bool stillUnsettled ) private {
        uint256[] memory frozenBefore = new uint256[](cases.length);
        uint256[] memory balBefore = new uint256[](cases.length);
        vm.startPrank(governance);
        for (uint i = 0; i < cases.length; i++) {
            frozenBefore[i] = rtoken.frozen(cases[i].account);
            balBefore[i] = rtoken.balanceOf(cases[i].account, stillUnsettled);
        }
        vm.expectEmit();
        emit CaseClosed(recover, victim_, cases);
        assertEq(rtoken.closeCase(recover, victim_, cases), true);

        for (uint i = 0; i < cases.length; i++) {
            assertEq(rtoken.frozen(cases[i].account), frozenBefore[i] - cases[i].amount);
            if (recover) {
                assertEq(rtoken.balanceOf(cases[i].account, stillUnsettled), balBefore[i] - cases[i].amount);
            } else {
                assertEq(rtoken.balanceOf(cases[i].account, stillUnsettled), balBefore[i]);
            }
        }
    }

    function _closeCase2(Suspension memory s1, Suspension memory s2, bool recover, address victim_, bool stillUnsettled) private {
        Suspension[] memory cases = new Suspension[](2);
        cases[0] = s1;
        cases[1] = s2;
        _closeCase(cases, recover, victim_, stillUnsettled);
    }

    function testCleanFrozenRecord() public {
        _wrap(alice, 100);
        _wrap(bob, 100);
        _transferSettled(alice, bob, 10);
        _transferSettled(bob, alice, 10);
        _freeze2(Suspension(alice, 1, 10), Suspension(bob, 1, 10));
        skip(SECONDS_PER_DAY / 2);
        _transferSettled(alice, bob, 10);
        _transferSettled(bob, alice, 10);
        skip(SECONDS_PER_DAY / 2);
        _checkBalances(bob, 10, 90);
    }

    function testExtendedScenario() public {
        uint256 initial = 100;
        _wrap(alice, initial);
        _wrap(bob, initial);
        _wrap(carol, initial);
        _transferSettled(alice, bob, 30);
        _transferAny(bob, carol, 20);
        // carol should have 100 settled and 20 unsettled
        _checkBalances(carol, 20, 100);

        // bob should have 10 unsettled and 100 settled
        _checkBalances(bob, 10, 100);

        _transferAny(carol, carol, 15);

        // carol should still have 100 settled and 20 unsettled 
        _checkBalances(carol, 20, 100);

        _transferAny(alice, bob, 30);
        //bob should have 40 unsettled 
        _checkBalances(bob, 40, 100);
        // alice has 40 settled 
        _checkBalances(alice, 0, 40);

        _transferSettled(bob, alice, 50);
        // alice should have 50 unsettled, 40 settled
        _checkBalances(alice, 50, 40);
        // bob should have 40 unsettled and 50 settled
        _checkBalances(bob, 40, 50);

        _freeze2(Suspension(alice, 1, 20), Suspension(bob, 2, 30));
        
        vm.expectEmit();
        emit UnsettledRecordSpend(alice, 1, 30);
        vm.expectEmit();
        emit Transfer(alice, bob, 30, 1, 3);
        _transferAny(alice, bob, 31);  
        _checkBalances(alice, 20, 39);
        _checkBalances(bob, 71, 50);

        vm.expectEmit();
        emit UnsettledRecordSpend(bob, 3, 31);
        vm.expectEmit();
        emit UnsettledRecordSpend(bob, 1, 5);
        vm.expectEmit();
        emit Transfer(bob, alice, 36, 0, 2);
        _transferAny(bob, alice, 36);
        // alice now has 56 unsettled, 39 settled 
        _checkBalances(alice, 56, 39);
        // bob has 35 unsettled, 50 settled 
        _checkBalances(bob, 35, 50);

        vm.expectEmit();
        emit Transfer(carol, bob, 0, 5, 3);
        _transferSettled(carol, bob, 5);
        _checkBalances(carol, 20, 95);
        _checkBalances(bob, 40, 50);

        skip(SECONDS_PER_DAY * 2);
        vm.expectEmit();
        emit Transfer(carol, bob, 0, 10, 4);
        _transferAny(carol, bob, 10);
        _checkBalances(carol, 0, 105);
        _checkBalances(bob, 10, 90);

        vm.expectEmit();
        emit Transfer(alice, carol, 0, 10, 3);
        vm.expectEmit();
        emit Transfer(bob, carol, 0, 30, 4);
        _closeCase2(Suspension(alice, 1, 10), Suspension(bob, 2, 30), true, carol, false);
        _checkBalances(carol, 40, 105);
    }

    // many unsettled records 
    function testStressManyRecords() public {
        _wrap(alice, 1000);
        _wrap(bob, 1000);
        for (uint i = 0; i < 500; i++) {
            _transferAny(alice, bob, 1);
        }
        _checkBalances(bob, 500, 1000);
        _transferSettled(bob, alice, 5);
        _checkBalances(bob, 500, 995);
        _checkBalances(alice, 5, 500);
    }

    // many records that are now settled
    function testStressBalanceOf() public {
        _wrap(alice, 1000);
        _wrap(bob, 1000);
        for (uint i = 0; i < 500; i++) { 
            _transferAny(alice, bob, 1);
        }
        _checkBalances(bob, 500, 1000);
        _checkBalances(alice, 0, 500);
        skip(SECONDS_PER_DAY);

        _transferAny(bob, alice, 5);
        _checkBalances(bob, 0, 1495);
        _checkBalances(alice, 5, 500);
    }

    // many records in a period of time 
    function testStressConsecutiveTransfers() public {
        _wrap(alice, 1000);
        uint step = SECONDS_PER_DAY / 500; 

        for (uint i = 0; i < SECONDS_PER_DAY; i += step) {
            _checkBalances(bob, i / step, 0); // this would be expensive if there is no cache 
            _transferSettled(alice, bob, 1);
            skip(step);
        }
        for (uint i = 0; i < SECONDS_PER_DAY; i += step) {
            // this would be expensive if there is a cache
            // most expensive would be if the last settled record was the one before cacheIndex 
            rtoken.balanceOf(bob); 
            skip(step);
        }
    }
}
