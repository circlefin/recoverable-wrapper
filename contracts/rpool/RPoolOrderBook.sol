// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20R} from "../interfaces/IERC20R.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OrderBook reference implementation of an RPool
 * This contract allows users to post sell orders of their unsettled ERC20R tokens in exchange for 
 * the underlying base token. LPs can match the orders. 
 * This contract is for demonstration purposes and has not been audited or meant for production use.
 */
contract RPoolOrderBook {
    IERC20R public token;
    IERC20 public base;

    struct BidInfo {
        uint128 expiration;
        uint128 minQuote;
    }
    
    // key is abi.encode(address bidder, uint128 nonce, uint256 amount, uint256 blockNumber)
    mapping(bytes32 => BidInfo) public bids;

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

    constructor(address token_) {
        token = IERC20R(token_);
        base = IERC20(token.baseToken());
    }

    /**
     * 
     * @param bidder account asking for base tokens
     * @param nonce current ERC20R nonce of the bidder
     * @param rAmount of ERC20R unsettled tokens bidder is selling
     * @param blockNumber of the transaction when the bid was posted 
     */
    function getBidID(address bidder, uint128 nonce, uint256 rAmount, uint blockNumber) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidder, nonce, rAmount, blockNumber));
    }

    /**
     * User could also call this function to update their bid with a new minQuote or expiration. 
     * @param bidder account requesting swap
     * @param amount to swap
     * @param minQuote minimum accepted base tokens in return
     * @param expiration of bid in absolute timestamp (seconds)
     */
    function postBid(address bidder, uint256 amount, uint128 minQuote, uint128 expiration) external returns (bytes32 bidID) {
        require(expiration > block.timestamp, "Expiration of bid must be in the future.");
        uint128 nonce = token.nonce(bidder);
        bidID = getBidID(bidder, nonce, amount, block.number);

        bids[bidID] = BidInfo(expiration, minQuote);
        emit Bid(bidder, nonce, amount, minQuote, expiration, block.number, bidID);
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
     * @param blockNumber when the bid was posted
     */
    function matchBid(address bidder, uint128 nonce, uint256 amount, uint128 quote, uint blockNumber) external {
        // LP matches bid contingent on the the funds' probability of recovery staying the same.
        require(token.nonce(bidder) == nonce, "Nonce has changed."); 
        address lp = msg.sender;
        bytes32 bidID = getBidID(bidder, nonce, amount, blockNumber);
        require(bids[bidID].expiration > 0, "Bid not found.");
        require(quote >= bids[bidID].minQuote, "Quote cannot be less than minimum quote.");
        require(block.timestamp < bids[bidID].expiration, "Bid has expired.");

        token.transferFrom(bidder, lp, amount, true);
        base.transferFrom(lp, bidder, quote);

        delete bids[bidID];
        emit Exchange(bidder, lp, amount, quote, bidID);
    }

    /**
     * Function to allow bidder to cancel. Assumes that the caller is the bidder.
     * A bid can only be cancelled by the bidder himself.
     * @param nonce current ERC20R nonce of the bidder
     * @param rAmount of ERC20R unsettled tokens bidder is selling
     * @param blockNumber of the transaction when the bid was posted 
     */
    function cancelBid(uint128 nonce, uint256 rAmount, uint blockNumber) external {
        bytes32 bidID = getBidID(msg.sender, nonce, rAmount, blockNumber);
        require(bids[bidID].expiration > 0, "Bid not found.");
        delete bids[bidID];
        emit BidCancelled(bidID);
    }
}
