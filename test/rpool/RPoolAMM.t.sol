/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2023 Circle Internet Financial, LTD 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

pragma solidity 0.8.20;

import {Test} from "forge-std/src/Test.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {ERC20RWrapper} from "../../contracts/ERC20R/ERC20RWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {SECONDS_PER_DAY} from "../utils/constants.sol";
import {RPoolAMM} from "../../contracts/rpool/RPoolAMM.sol";

contract RPoolAMMTest is Test {
    address private governance = makeAddr("governance");
    MockERC20 private erc20 = new MockERC20();
    ERC20RWrapper private rtoken = new ERC20RWrapper("Recoverable ERC20", "ERC20R", SECONDS_PER_DAY, governance, address(erc20), 100);
    RPoolAMM private ramm;
    uint8 private constant minQuotes = 2;
    uint256 private constant minQuoterDeposit = 100;
    address private owner = makeAddr("owner");
    address private q1 = vm.addr(1);
    address private q2 = vm.addr(2);
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private temp = makeAddr("temp");
    SigUtils internal sigUtils;

    event AddLiquidity(address indexed lp, uint256 deposit, uint256 LPshares);
    event RemoveLiquidity(
        address indexed lp,
        uint256 shares,
        uint256 withdrawnTotal
    );
    event Exchange(address indexed account, uint256 P, uint256 x);
    event NewQuoterAllowed(address indexed quoter);
    event QuoterRevoked(address indexed quoter);

    function setUp() public {
        uint256 tenPercent = 10 ** 5; //assuming decimals is 6
        vm.startPrank(owner);
        ramm = new RPoolAMM(address(rtoken), 9 * tenPercent, 8 * tenPercent, minQuotes, minQuoterDeposit, 5 * tenPercent);
        vm.stopPrank();
        sigUtils = new SigUtils(ramm.domainSeparator());
    }

    function testAddAllowedQuoter_fail_notOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        ramm.addAllowedQuoter(q1);
    }

    function testAddAllowedQuoter_fail_insufficientStake() public {
        vm.expectRevert("Insufficient staked value.");
        vm.startPrank(owner);
        ramm.addAllowedQuoter(q1);
        vm.stopPrank();
    }

    function testAddLiquidity_fail_depositZero() public {
        vm.expectRevert("Invalid amount");
        ramm.addLiquidity(0);
    }

    function _addLiquidity(address account, uint256 deposit, uint256 expectedShares) public {
        uint256 totalSharesBefore = ramm.totalShares();
        uint256 sharesBefore = ramm.lpShares(account);
        uint256 rtokensBefore = rtoken.balanceOf(address(ramm), false);
        erc20.mint(account, deposit);
        vm.startPrank(account);
        erc20.approve(address(ramm), deposit);
        vm.expectEmit();
        emit AddLiquidity(account, deposit, expectedShares);
        ramm.addLiquidity(deposit);
        vm.stopPrank();
        assertEq(ramm.totalShares(), totalSharesBefore + expectedShares);
        assertEq(ramm.lpShares(account), sharesBefore + expectedShares);
        assertEq(rtoken.balanceOf(address(ramm), false), rtokensBefore + deposit);
    }

    function testAddLiquidity() public {
        _addLiquidity(q1, 100, 100);
        _addLiquidity(q2, 100, 100);
    }

    function testAddAllowedQuoter() public {
        _addLiquidity(q1, minQuoterDeposit, minQuoterDeposit);
        vm.expectEmit();
        emit NewQuoterAllowed(q1);
        vm.startPrank(owner);
        ramm.addAllowedQuoter(q1);
        vm.stopPrank();
        assertEq(ramm.allowedQuoterRound(q1), 1);
    }

    function testRemoveQuoter_fail_notOnAllowlist() public {
        vm.expectRevert("Quoter not on allowlist.");
        vm.startPrank(owner);
        ramm.revokeAllowedQuoter(q1);
        vm.stopPrank();
    }

    function testRemoveQuoter() public {
        _addLiquidity(q1, minQuoterDeposit, minQuoterDeposit);
        vm.startPrank(owner);
        ramm.addAllowedQuoter(q1);
        ramm.revokeAllowedQuoter(q1);
        vm.stopPrank();
        assertEq(ramm.allowedQuoterRound(q1), 0);
    }

    function _addQuoter(address account, uint256 deposit, uint256 expectedShares) private {
         _addLiquidity(account, deposit, expectedShares);
        vm.startPrank(owner);
        ramm.addAllowedQuoter(account);
        vm.stopPrank();
        assertEq(ramm.allowedQuoterRound(account), 1);
    }

    function testRemoveLiquidity_fail_tooManyShares() public {
        vm.expectRevert("Cannot redeem more shares than LP owns.");
        ramm.removeLiquidity(5);
    }

    function testRemoveLiquidity_nothingToWithdraw() public {
        vm.expectRevert("Nothing to withdraw.");
        ramm.removeLiquidity(0);
    }

    function testRemoveLiquidity_AllowedQuoter() public {
        _addLiquidity(q1, minQuoterDeposit, minQuoterDeposit);
        vm.startPrank(owner);
        ramm.addAllowedQuoter(q1);
        vm.stopPrank();
        vm.startPrank(q1);
        vm.expectRevert("Quoters must keep minimum share value in pool.");
        ramm.removeLiquidity(1);
        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        _addLiquidity(q1, 100, 100);
        vm.startPrank(q1);
        vm.expectEmit();
        emit RemoveLiquidity(q1, 1, 1);
        ramm.removeLiquidity(1);
        vm.stopPrank();
        assertEq(erc20.balanceOf(q1), 1);
        assertEq(ramm.lpShares(q1), 99);
    }

    function _makeQuote(uint256 sk, address account, uint128 nonce, uint256 rAmount, uint256 expiry, uint256 quote) public view returns (RPoolAMM.Quote memory q) {
        bytes32 digest = sigUtils.getTypedDataHash(ramm.QUOTE_TYPE_HASH(), account, nonce, rAmount, expiry, quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        q = RPoolAMM.Quote(quote, expiry, signature);
    }

    function testExchange_fail_rAmountZero() public {
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](1);
        quotes[0] = _makeQuote(1, alice, 1, 0, block.timestamp + 1, 0);
        vm.expectRevert("Nothing to exchange.");
        ramm.exchange(q1, 0, quotes);
    }

    function _wrapUnsettle(address account, uint256 amount) private {
        erc20.mint(temp, amount);
        vm.startPrank(temp);
        erc20.approve(address(rtoken), amount);
        rtoken.wrap(amount);
        rtoken.transfer(account, amount);
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

    function testExchange_fail_insufficientQuotes() public {
        _wrapUnsettle(alice, 100);
        _wrapUnsettle(bob, 100);
        assertEq(rtoken.nonce(alice), 1);
        _transferAny(alice, bob, 10);
        assertEq(rtoken.nonce(alice), 2);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](1);
        quotes[0] = _makeQuote(1, alice, 2, 10, block.timestamp + 1, 1000000);
        vm.expectRevert("Insufficient quotes.");
        ramm.exchange(alice, 10, quotes);
    }

    function testExchange_fail_decreasingQuotes() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 10, block.timestamp + 1, 1000000);
        quotes[1] = _makeQuote(2, alice, 1, 10, block.timestamp + 1, 100000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        vm.expectRevert("Quotes must be increasing.");
        ramm.exchange(alice, 10, quotes);
    }

    function testExchange_fail_quoterNotAllowed() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 2, 10, block.timestamp + 1, 1000000);
        quotes[1] = _makeQuote(2, alice, 2, 10, block.timestamp + 1, 1000000);
        vm.expectRevert("Signer not allowed");
        ramm.exchange(alice, 10, quotes);
    }

    function testExchange_fail_quoteExpired() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 2, 10, block.timestamp -1 , 1000000);
        quotes[1] = _makeQuote(2, alice, 2, 10, block.timestamp -1, 1000000);
        vm.expectRevert("Quote has expired.");
        ramm.exchange(alice, 10, quotes);
    }

    function testExchange_fail_quoterParticipated() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 10, block.timestamp + 1, 1000000);
        quotes[1] = _makeQuote(1, alice, 1, 10, block.timestamp + 1, 1000000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        vm.expectRevert("Quoter already participated");
        ramm.exchange(alice, 10, quotes);
    }

    function testExchange_fail_notWithinRiskBounds() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 10, block.timestamp + 1, 700000);
        quotes[1] = _makeQuote(2, alice, 1, 10, block.timestamp + 1, 800000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        _addQuoter(q2, minQuoterDeposit, minQuoterDeposit);
        vm.expectRevert("Rate is not within risk bounds.");
        ramm.exchange(alice, 10, quotes);
    }

    function _checkBalances(address account, uint256 unsettled, uint256 settled) private  {
        assertEq(rtoken.balanceOf(account), settled);
        assertEq(rtoken.balanceOf(account, true), settled + unsettled);
    }

    function testExchange_fail_allowance() public {
        _wrapUnsettle(alice, 100);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 100, block.timestamp + 1, 800000);
        quotes[1] = _makeQuote(2, alice, 1, 100, block.timestamp + 1, 900000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        _addQuoter(q2, minQuoterDeposit, minQuoterDeposit);
        vm.expectRevert("ERC20: insufficient allowance");
        ramm.exchange(alice, 100, quotes);
    }

    function _approve(address account, address spender, uint256 amount, IERC20 token) public {
        vm.startPrank(account);
        token.approve(spender, amount);
        vm.stopPrank();
    }

    function testExchange_success() public {
        _wrapUnsettle(alice, 100);
        _approve(alice, address(ramm), 100, rtoken);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 100, block.timestamp + 1, 800000);
        quotes[1] = _makeQuote(2, alice, 1, 100, block.timestamp + 1, 900000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        _addQuoter(q2, minQuoterDeposit, minQuoterDeposit);
        vm.expectEmit();
        emit Exchange(alice, 100, 85);
        ramm.exchange(alice, 100, quotes);
        _checkBalances(address(ramm), 100, 115);
        _checkBalances(alice, 0, 0);
        assertEq(erc20.balanceOf(alice), 85);
    }

    function testExchange_bondingCurve() public {
        _wrapUnsettle(alice, 150);
        uint256 expectedBack = 83;
        _approve(alice, address(ramm), 150, rtoken);
        RPoolAMM.Quote[] memory quotes = new RPoolAMM.Quote[](2);
        quotes[0] = _makeQuote(1, alice, 1, 150, block.timestamp + 1, 800000);
        quotes[1] = _makeQuote(2, alice, 1, 150, block.timestamp + 1, 800000);
        _addQuoter(q1, minQuoterDeposit, minQuoterDeposit);
        _addQuoter(q2, minQuoterDeposit, minQuoterDeposit);
        vm.expectEmit();
        emit Exchange(alice, 150, expectedBack);
        ramm.exchange(alice, 150, quotes);
        _checkBalances(address(ramm), 150, 200 - expectedBack);
        _checkBalances(alice, 0, 0);
        assertEq(erc20.balanceOf(alice), expectedBack);
    }
}
