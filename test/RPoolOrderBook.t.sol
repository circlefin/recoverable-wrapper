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
import {MockERC20, ERC20} from "./utils/MockERC20.sol";
import {ERC20RWrapper} from "../contracts/ERC20R/ERC20RWrapper.sol";
import {SECONDS_PER_DAY} from "./utils/constants.sol";
import {RPoolOrderBook} from "../contracts/rpool/RPoolOrderBook.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract RPoolOrderBookTest is Test {
    using SafeCast for uint256;
    MockERC20 private erc20 = new MockERC20();
    address governance = makeAddr('governance');
    ERC20RWrapper private rtoken = new ERC20RWrapper("Recoverable ERC20", "ERC20R", SECONDS_PER_DAY, governance, address(erc20), 100);
    RPoolOrderBook private rpob;
    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    uint256 private constant HALF_DAY = SECONDS_PER_DAY / 2;

    struct BidInfo {
        uint128 expiration;
        uint128 minQuote;
    }

    /**
     * Emitted when an exchange is successful.
     * @param user bidder
     * @param lp LP supplying the base tokens
     * @param rAmount amount of unsettled ERC20R tokens LP receives
     * @param baseAmount amount of base tokens user receives
     * @param bidID bidID
     */
    event Exchange(address indexed user, address indexed lp, uint256 rAmount, uint256 baseAmount, bytes32 bidID);

    /**
     * Emitted when a Bid is posted. 
     * @param bidder account asking for base tokens
     * @param nonce current ERC20R nonce of the bidder
     * @param rAmount of ERC20R unsettled tokens bidder is selling
     * @param minBaseAmount minimum accepted base tokens in return
     * @param expiration of bid in absolute timestamp (seconds)
     * @param blockNumber of bid when posted 
     * @param bidID bidID
     */
    event Bid(address indexed bidder, uint128 nonce, uint256 rAmount, uint128 minBaseAmount, uint128 expiration, uint blockNumber, bytes32 bidID);

    /**
     * Emitted if bidder cancels a bid it already posted. 
     * @param bidID bidID
     */
    event BidCancelled(bytes32 bidID);

    function _wrapUnsettle(address account, uint256 amount) private {
        erc20.mint(account, amount);
        vm.startPrank(account);
        erc20.approve(address(rtoken), amount);
        rtoken.wrap(amount);
        rtoken.transfer(account, amount);
        vm.stopPrank();
    }

    function assertEqBid(bytes32 bidID, BidInfo memory b) private {
        (uint128 e, uint128 m) = rpob.bids(bidID);
        assertEq(e, b.expiration);
        assertEq(m, b.minQuote);
    }

    function setUp() public {
        rpob = new RPoolOrderBook(address(rtoken));
    }

    function testToken() public {
        assertEq(address(rpob.token()), address(rtoken));
        assertEq(address(rpob.base()), address(erc20));
    }

    function testPostBid() public {
        uint256 amount = 50;
        _wrapUnsettle(alice, 100);
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        uint128 nonce = rtoken.nonce(alice);
        bytes32 bidID = rpob.getBidID(alice, nonce, amount, block.number);
        vm.expectEmit();
        emit Bid(alice, rtoken.nonce(alice), amount, 30, expiry, block.number, bidID);
        assertEq(rpob.postBid(alice, amount, 30, expiry), bidID);
        assertEqBid(bidID, BidInfo(expiry, 30));
    }

    function testPostBid_fail_expiration() public {
        uint256 amount = 50;
        _wrapUnsettle(alice, 100);
        uint128 expiry = 0;
        vm.expectRevert("Expiration of bid must be in the future.");
        rpob.postBid(alice, amount, 30, expiry);
    }

    function _postBid(uint128 expiry, uint256 amount, uint128 minQuote) private returns (bytes32){
        uint128 nonce = rtoken.nonce(alice);
        bytes32 bidID = rpob.getBidID(alice, nonce, amount, block.number);
        assertEq(rpob.postBid(alice, amount, minQuote, expiry), bidID);
        return bidID;
    }

    function testCancelBid() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        bytes32 bidID = _postBid(expiry, 50, 30);
        uint128 nonce = rtoken.nonce(alice);
        vm.expectEmit();
        emit BidCancelled(bidID);
        vm.startPrank(alice);
        rpob.cancelBid(nonce, 50, block.number);
        vm.stopPrank();
        (uint128 e,) = rpob.bids(bidID);
        assertEq(e, 0);
    }

    function testCancelBid_fail() public {
        _wrapUnsettle(alice, 100);
        uint128 nonce = rtoken.nonce(alice);
        vm.expectRevert('Bid not found.');
        vm.startPrank(alice);
        rpob.cancelBid(nonce, 3, block.number);
        vm.stopPrank();
    }

    function testMatchBid_fail_nonce() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        _postBid(expiry, 50, 30);
        erc20.mint(bob, 100);
        vm.startPrank(bob);
        uint128 fakeNonce = rtoken.nonce(alice) + 1;
        vm.expectRevert("Nonce has changed.");
        rpob.matchBid(alice, fakeNonce, 50, 30, block.number);
        vm.stopPrank();
    }

    function testMatchBid_fail_wrongBid() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        _postBid(expiry, 50, 30);
        erc20.mint(bob, 100);
        vm.startPrank(bob);
        uint128 nonce = rtoken.nonce(alice);
        vm.expectRevert("Bid not found.");
        rpob.matchBid(alice, nonce, 5, 30, block.number);
        vm.stopPrank();
    }

    function testMatchBid_fail_minQuote() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        _postBid(expiry, 50, 30);
        erc20.mint(bob, 100);
        vm.startPrank(bob);
        uint128 nonce = rtoken.nonce(alice);
        vm.expectRevert("Quote cannot be less than minimum quote.");
        rpob.matchBid(alice, nonce, 50, 3, block.number);
        vm.stopPrank();
    }

    function testMatchBid_fail_expired() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        uint256 blockNumber = block.number;
        _postBid(expiry, 50, 30);
        erc20.mint(bob, 100);
        vm.startPrank(bob);
        uint128 nonce = rtoken.nonce(alice);
        skip(HALF_DAY);
        vm.expectRevert("Bid has expired.");
        rpob.matchBid(alice, nonce, 50, 30, blockNumber);
        vm.stopPrank();
    }

    function testMatchBid_fail_notApproved() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        _postBid(expiry, 50, 30);
        erc20.mint(bob, 100);
        vm.startPrank(bob);
        uint128 nonce = rtoken.nonce(alice);
        vm.expectRevert("ERC20: insufficient allowance");
        rpob.matchBid(alice, nonce, 50, 30, block.number);
        vm.stopPrank();
    }

    function approve(ERC20 token, address owner, address spender, uint256 amount) public {
        vm.startPrank(owner);
        token.approve(spender, amount);
        vm.stopPrank();
    }

    function testMatchBid() public {
        uint128 expiry = (block.timestamp + HALF_DAY).toUint128();
        _wrapUnsettle(alice, 100);
        bytes32 bidID =  _postBid(expiry, 50, 30);
        erc20.mint(bob, 200);
        uint128 nonce = rtoken.nonce(alice);
        approve(erc20, bob, address(rpob), 100);
        approve(rtoken, alice, address(rpob), 100);
        vm.expectEmit();
        emit Exchange(alice, bob, 50, 30, bidID);
        vm.startPrank(bob);
        rpob.matchBid(alice, nonce, 50, 30, block.number);
        vm.stopPrank();
        assertEq(erc20.balanceOf(alice), 30);
        _checkBalances(alice, 50, 0);
        assertEq(erc20.balanceOf(bob), 170);
        _checkBalances(bob, 50, 0);
    }

    function _checkBalances(address account, uint256 unsettled, uint256 settled) private  {
        assertEq(rtoken.balanceOf(account), settled);
        assertEq(rtoken.balanceOf(account, true), settled + unsettled);
    }
}
