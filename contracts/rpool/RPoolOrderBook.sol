// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20R} from "../interfaces/IERC20R.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OrderBook implementation of an RPool
 */
contract RPoolOrderBook {
    IERC20R public token;
    IERC20 public base;

    struct BidInfo {
        uint128 expiration;
        uint128 minQuote;
    }
    
    //key is abi.encode(address bidder, uint128 nonce, uint256 amount)
    mapping(bytes32 => BidInfo) public bids;

    /**
     * Emitted when an exchange is successful.
     * @param user bidder
     * @param lp supplying the base tokens
     * @param p amount of unsettled ERC20R tokens LP receives
     * @param x amount of base tokens user receives
     */
    event Exchange(address indexed user, address indexed lp, uint256 p, uint256 x);

    /**
     * Emitted when a Bid is posted. 
     * @param bidder account asking for base tokens
     * @param nonce current ERC20R nonce of the bidder
     * @param amount of ERC20R unsettled tokens bidder is selling
     * @param minQuote minimum accepted base tokens in return
     * @param expiration of bid
     * @param bidID bidID
     */
    event Bid(address indexed bidder, uint128 nonce, uint256 amount, uint128 minQuote, uint128 expiration, bytes32 bidID);

    /**
     * Emitted if bidder cancels a bid it already posted. 
     * @param bidID bidID
     */
    event BidCancelled(bytes32 bidID);

    constructor(address token_) {
        token = IERC20R(token_);
        base = IERC20(token.baseToken());
    }

    function getBidID(address bidder, uint128 nonce, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidder, nonce, amount));
    }

    /**
     * User could also call this function to update their bid with a new minQuote or expiration. 
     * @param bidder account requesting swap
     * @param amount to swap
     * @param minQuote minimum accepted base tokens in return
     * @param expiration of bid 
     */
    function postBid(address bidder, uint256 amount, uint128 minQuote, uint128 expiration) external returns (bytes32 bidID) {
        uint128 nonce = token.nonce(bidder);
        bidID = getBidID(bidder, nonce, amount);

        bids[bidID] = BidInfo(expiration, minQuote);
        emit Bid(bidder, nonce, amount, minQuote, expiration, bidID);
    }

    /**
     * Called by LP to match an existing bid. Moves the ERC20R unsettled funds from the bidder to the LP,
     * and base tokens from the LP to the bidder. 
     * If there is concern about the bidder not having the ERC20R funds anymore, one could easily modify 
     * this contract to lock the ERC20R unsettled funds first. 
     * @param bidder holder of ERC20R tokens bidding for base tokens
     * @param nonce nonce that matches with bidID and bidder's current ERC20R nonce
     * @param amount of ERC20R tokens the LP will receive
     * @param quote of number of base tokens the LP will give to the bidder
     */
    function matchBid(address bidder, uint128 nonce, uint256 amount, uint128 quote) external {
        address lp = msg.sender;
        require(token.nonce(bidder) == nonce, "Nonce has changed.");
        bytes32 bidID = getBidID(bidder, nonce, amount);
        require(bids[bidID].expiration > 0, "Bid not found.");
        require(quote >= bids[bidID].minQuote, "Quote cannot be less than minimum quote.");
        require(block.timestamp < bids[bidID].expiration, "Bid has expired.");

        token.transferFrom(bidder, lp, amount, true);
        base.transferFrom(lp, bidder, quote);

        //delete bid 
        delete bids[bidID];
        emit Exchange(bidder, lp, amount, quote);
    }

    /**
     * Function to allow bidder to cancel. Assumes that the caller is the bidder.
     * A bid can only be cancelled by the bidder himself.
     * @param bidID of the bid
     */
    function cancelBid(bytes32 bidID) external {
        require(bids[bidID].expiration > 0, "Bid not found.");
        delete bids[bidID];
        emit BidCancelled(bidID);
    }
}
