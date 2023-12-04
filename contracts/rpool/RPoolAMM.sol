/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2023 Circle Internet Financial, LTD 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

pragma solidity 0.8.20;

import {IRecoverableWrapper} from "../interfaces/IRecoverableWrapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "../util/EIP712.sol";

/**
 * @title RPool in AMM form. LPs can add liquidity to this contract and receive rewards,
 * and users can exchange their unsettled ERC20R tokens for base tokens. 
 * In order to do so, they must receive quotes and signatures from the risk rating oracle. 
 * See paper for more information. 
 */
contract RPoolAMM is Ownable {
    using SafeMath for uint256;

    /**
     * @notice Used for EIP712 utilities. 
     */
    bytes32 public immutable domainSeparator;
    // keccak256(address account, uint64 nonce, uint256 amount, uint256 expiration, uint256 quote)
    bytes32 public constant QUOTE_TYPE_HASH = 0x550c61ee2589627c43a1db81922bc00c1bb90a2545dd2325e49034b5128dfe1b;

    IRecoverableWrapper public immutable token;
    IERC20 public immutable baseToken;

    /**
     * @notice Total number of LP shares
     */
    uint256 public totalShares;

    /**
     * @notice Minimum number of quotes and signatures needed to exchange unsettled ERC20R. 
     */
    uint8 public immutable minQuotes;

    /**
     * @notice Minimum share value for an account to be a quoter. 
     */
    uint256 public immutable minQuoterShareValue; // using decimals. 
    
    /**
     * @notice Parameters for the pool. For example, if maxExchangeRate is 90%
     * and minExchangeRate is 80%, this pool only accepts exchanges for ERC20R funds with 
     * an estimated 10-20% risk of clawback. 
     */
    uint256 public immutable maxExchangeRate; // (based on decimals, e.g. 1000000 == 1. )
    uint256 public immutable minExchangeRate; 
    uint8 public constant decimals = 6;

    /**
     * @notice LP token balance
     */
    mapping(address => uint256) public lpShares;

    /**
     * @notice if 0, then quoter is not whitelisted. Otherwise, value represents 
     * the roundNumber (Rpool nonce) during which the quoter last quoted. This helps 
     * detect malicious multiple quotes from the same address during the same exchange request. 
     */
    mapping(address => uint256) public allowedQuoterRound;

    /**
     * @dev Utility variable to ensure that a quoter doesn't sign more than one quote per exchange request. 
     */
    uint256 private roundNumber = 1; 

    /**
     * @notice The reciprocal of a decimal number between 0 and 1, where the decimal represents the settled pool percentage at which the multiplier 
     * of the exchange rate starts to decrease from 1. 
     */
    uint256 public immutable bondingMultiplier;

    struct Quote {
        uint256 rate; // number between 0 and 1. number of decimal places is `decimals`
        uint256 expiration; // expiration of the quote, in absolute seconds 
        bytes signature; // EIP712
    }

    /**
     * Emitted when an LP adds liquidity.
     * @param lp adding liquidity in ERC20 base tokens
     * @param deposit amount of ERC20 base tokens
     * @param LPshares received in exchange for liquidity. 
     */
    event AddLiquidity(address indexed lp, uint256 deposit, uint256 LPshares);

    /**
     * Emitted when an LP redeems their LP shares for ERC20R. 
     * @param lp removing liquidity 
     * @param shares redeemed by the LP
     * @param withdrawnTotal (in ERC20R tokens)
     */
    event RemoveLiquidity(
        address indexed lp,
        uint256 shares,
        uint256 withdrawnTotal
    );
    event Exchange(address indexed account, uint256 P, uint256 x);
    event NewQuoterAllowed(address indexed quoter);
    event QuoterRevoked(address indexed quoter);

    /**
     * @param token_ ERC20R token to be serviced by the pool
     * @param maxExchangeRate_ based on risk estimate from oracles
     * @param minExchangeRate_ based on risk estimate from oracles
     * @param minQuotes_ Minimum number of quotes and signatures needed to exchange using the rpool. 
     * @param minQuoterShareValue_ Minimum share value for an account to be a quoter. 
     * @param threshold_ A decimal number representing the settled pool percentage at which the multiplier 
     * of the exchange rate starts to decrease from 1. (number of decimals = `decimals`)
     */
    constructor(address token_, 
                uint256 maxExchangeRate_, 
                uint256 minExchangeRate_, 
                uint8 minQuotes_, 
                uint256 minQuoterShareValue_,
                uint256 threshold_) {
        token = IRecoverableWrapper(token_);
        baseToken = IERC20(token.baseToken());
        maxExchangeRate = maxExchangeRate_;
        minExchangeRate = minExchangeRate_;
        minQuotes = minQuotes_;
        minQuoterShareValue = minQuoterShareValue_;
        domainSeparator = EIP712.makeDomainSeparator();
        bondingMultiplier = 10 ** decimals / threshold_;
        // to allow wrapping from this address
        baseToken.approve(address(token), type(uint).max);
    }

    /**
     * In practice, this would be called via protocol/DAO governance. 
     * An alternative design is that the allowed quoter list is initialized 
     * upon pool creation and cannot be modified. 
     * Note that quoter must be an active LP with a minimum deposit.
     * @param quoter to add to allow list. 
     */
    function addAllowedQuoter(address quoter) external onlyOwner {
        require(_sharesValue(lpShares[quoter]) >= minQuoterShareValue, "Insufficient staked value.");
        allowedQuoterRound[quoter] = 1;
        emit NewQuoterAllowed(quoter);
    }

    /**
     * Removes quoter from the quoter list. 
     * @param quoter to remove from allowlist
     */
    function revokeAllowedQuoter(address quoter) external onlyOwner {
        require(allowedQuoterRound[quoter] > 0, "Quoter not on allowlist.");
        delete allowedQuoterRound[quoter];
        emit QuoterRevoked(quoter);
    }

    /**
     * Allows caller to deposit base ERC20 tokens as an LP and receive LP shares. 
     * The number of LP shares they receive (t) satisfies the equation t/(totalShares + t) = deposit/(totalRtokens + deposit)
     * This is to incentivize deposits even after a recovery happens in the pool. 
     * If a recovery completely drains the pool however, then the pool is no longer usable. 
     * @param deposit amount of base ERC20 from the LP
     */
    function addLiquidity(uint256 deposit) external {
        address account = msg.sender;
        require(deposit > 0, "Invalid amount");
        uint256 totalRtokens = token.balanceOf(address(this), true);
        
        uint256 shares;
        if (totalRtokens == 0) {
            require(totalShares == 0, "Pool has been completely drained due to recoveries; cannot be used anymore except for withdrawing LP stakes.");
            shares = deposit;
        } else {
            shares = deposit.mul(totalShares).div(totalRtokens);
        }

        //transfer underlying asset first. can't be ERC20R which can get clawed back
        baseToken.transferFrom(account, address(this), deposit);
        //turn into settled ERC20R
        token.wrap(deposit);

        lpShares[msg.sender] += shares;
        totalShares += shares;
        emit AddLiquidity(account, deposit, shares);
    }

    /**
     * The ERC20R tokens they receive will be in the same proportion of base vs unsettled
     * as the pool's proportion of settled vs unsettled, respectively.
     * @param shares to redeem
     */
    function removeLiquidity(uint256 shares)
        external
        returns (uint256 liquidityToRemove)
    {
        require(shares <= lpShares[msg.sender], "Cannot redeem more shares than LP owns.");
        liquidityToRemove = _sharesValue(shares);
        require(liquidityToRemove > 0, "Nothing to withdraw.");
        
        if (allowedQuoterRound[msg.sender] > 0) {
            require(_sharesValue(lpShares[msg.sender] - shares) >= minQuoterShareValue, "Quoters must keep minimum share value in pool.");
        }

        uint256 total = token.balanceOf(address(this), true);
        uint256 settled = token.balanceOf(address(this), false);

        uint256 settledToWithdraw = liquidityToRemove.mul(settled).div(total);

        lpShares[msg.sender] -= shares;
        totalShares -= shares;

        // Transfer settled tokens proportional to pool ratio (and unwrap to base token)
        token.unwrapTo(
            msg.sender,
            settledToWithdraw //includes fees they've earned
        );
        // Transfer unsettled tokens proportional to pool ratio
        token.transferFrom(
            address(this),
            msg.sender,
            uint128(liquidityToRemove - settledToWithdraw), //includes fees they've earned
            true
        );

        emit RemoveLiquidity(msg.sender, shares, liquidityToRemove);
    }

    /**
     * Called by ERC20R holder to exchange their unsettled tokens for base tokens. 
     * @param account holder of unsettled ERC20R 
     * @param rAmount sum of amount of recoverable token that will be unwrapped and the fee
     * @param quotes provided by the risk rating oracle
     */
    function exchange(address account, uint256 rAmount, Quote[] calldata quotes) external returns (uint256 baseTokens) {
        require(rAmount > 0, "Nothing to exchange.");
        roundNumber++;
        _checkSigs(account, rAmount, token.nonce(account), quotes);
        uint256 unadjustedBaseTokens = _getUnadjustedBaseAmount(rAmount, quotes);
        uint256 settled = token.balanceOf(address(this), false);

        /**
         * Note: In this toy example, the bonding curve factor is based on what the final state would be without any bonding curve. 
         * This should not be done in practice as it results in underutilization of the pool. One could base the bonding curve factor 
         * on the actual predicted final state which includes the bonding curve, though this will be more computationally expensive. 
         */
        require(unadjustedBaseTokens < settled, "Cannot withdraw all settled tokens in this version of the RPool.");
        uint256 totalAfter = token.balanceOf(address(this), true) - unadjustedBaseTokens + rAmount;
        uint256 settledAfter = settled - unadjustedBaseTokens;

        // apply bonding curve described in the paper 
        baseTokens = Math.min(unadjustedBaseTokens, unadjustedBaseTokens.mul(settledAfter).mul(bondingMultiplier).div(totalAfter));

        token.transferFrom(account, address(this), rAmount, true);
        token.unwrapTo(account, baseTokens);
        emit Exchange(account, rAmount, baseTokens);
    }

    /**
     * Helper function to check the quotes and verify them.
     * @param account exchanging unsettled tokens for base tokens
     * @param rAmount of unsettled tokens 
     * @param nonce of the account currently
     * @param quotes provided by the risk rating oracle 
     */
    function _checkSigs(address account, uint256 rAmount, uint128 nonce, Quote[] calldata quotes) private {
        require(quotes.length >= minQuotes, "Insufficient quotes.");

        uint256 lastRate = 0;
        for (uint i = 0; i < quotes.length; i++) {
            uint256 rate = quotes[i].rate;
            require(rate >= lastRate, "Quotes must be increasing.");
            require(block.timestamp < quotes[i].expiration, "Quote has expired.");

            // verify signature 
            bytes memory data = abi.encode(
                QUOTE_TYPE_HASH,
                account, 
                nonce, 
                rAmount,
                quotes[i].expiration,
                rate
            );
            address signer = EIP712.recover(domainSeparator, quotes[i].signature, data);
            require(allowedQuoterRound[signer] > 0, "Signer not allowed");
            require(lpShares[signer] >= minQuoterShareValue, "Insufficient deposit");
            require(allowedQuoterRound[signer] != roundNumber, "Quoter already participated");
            lastRate = rate;
            allowedQuoterRound[signer] = roundNumber;
        }
    }

    /**
     * Takes the median rate of all the quotes and multiples by the amount of unsettled tokens. 
     * This is the number of base tokens the user would receive back, excluding any adjustments
     * from the bonding curve. 
     * @param rAmount of unsettled tokens the user is attempting to exchnage
     * @param quotes an array of quotes provided by allowed quoters. 
     */
    function _getUnadjustedBaseAmount(uint256 rAmount, Quote[] calldata quotes) private view returns (uint256 x) {
        uint256 len = quotes.length;
        uint256 medianRate;

        // quotes array is already verified to be in increasing order
        if (len % 2 == 1) {
            medianRate = quotes[len / 2].rate;
        } else {
            // take average of two middle elements 
            medianRate = (quotes[len / 2].rate + quotes[len / 2 - 1].rate) / 2;
        }

        require (medianRate >= minExchangeRate && medianRate <= maxExchangeRate, "Rate is not within risk bounds.");

        x = rAmount.mul(medianRate).div(10 ** decimals);
    }

    /**
     * Helper function to determine how much LP shares are worth. 
     * @param shares number
     */
    function _sharesValue(uint256 shares) private view returns (uint256) {
        return totalShares == 0 ? 0 : shares.mul(token.balanceOf(address(this), true)).div(totalShares); 
    }
}
