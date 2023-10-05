// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * @dev Interface of the ERC20R standard.
 */
interface IERC20R {

   /**
    * @dev Emitted when a transfer occurs. Could be a settled transfer or 
    * an unsettled transfer. 
    * @param from - sender 
    * @param to - receiver 
    * @param unsettledTransferred - amount of sender's unsettled funds transferred. 0 if includeUnsettled was set to false. 
    * @param settledTransferred - amount of sender's settled funds transferred. Could be 0 if includeUnsettled was true. 
    * @param rawIndex - only needed if this transfer is frozen later. This 
    * is the index of the transfer record in memory, which is only deleted after
    * the funds are settled.
    */
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 unsettledTransferred,
        uint256 settledTransferred,
        uint256 rawIndex
    );

    /**
     * @dev Emitted when an account is disabled from unwrapping. 
     * @param account disabled
     */
    event UnwrapDisabled(address indexed account);

    /**
     *
     * @param dst - the account trying to wrap his own tokens
     * @param amount to wrap
     */
    event Wrap(address indexed dst, uint256 amount);

    /**
     *
     * @param src - account trying to unwrap tokens back to base token
     * @param amount to unwrap
     */
    event Unwrap(address indexed src, address indexed to, uint256 amount);

    /**
     * @dev returns the address of the base token this contract wraps.
     */
    function baseToken() external view returns (address);

    /**
     * @dev returns the window of recovery. 
     */
    function recoverableWindow() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`. If includeUnsettled
     * is false, then it returns the settled balance.
     */
    function balanceOf(address account, bool includeUnsettled)
        external
        view
        returns (uint256);

    /**
     * Each time an account receives ERC20R tokens, this nonce increments. This may be
     * useful in contexts where another party wants to evaluate the clawback risk of an account's 
     * tokens, based on the account's current state. 
     * @param account to retrieve nonce for. 
     */
    function nonce(address account) external view returns (uint128);

    /**
     * Allows caller to wrap their own base tokens
     * @param amount to wrap
     */
    function wrap(uint256 amount) external;

    /**
     * Allows caller to unwrap their own recoverable tokens back to the base token
     * @param amount to unwrap
     */
    function unwrap(uint256 amount) external;

    /**
     * First unwraps caller's recoverable tokens and then sends base token to another address
     * @param amount to unwrap
     * @param to - the address to send unwrapped tokens to
     */
    function unwrapTo(address to, uint256 amount) external;
    
    /**
     * Disables all future unwrap calls for the caller's account. 
     * This is an optional extra safety precaution for certain addresses (i.e. contracts) that 
     * should only issue out ERC20R tokens in wrapped form, preventing bad actors from 
     * calling unwrap on its behalf in the future. 
     */
    function disableUnwrap() external;

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     * if `includeUnsettled` is false, it will only transfer out of settled funds.
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {TransferSettled} event, or both {TransferSettled} and {TransferUnsettled} events.
     */
    function transfer(
        address to,
        uint256 amount,
        bool includeUnsettled
    ) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance. if `includeUnsettled` is false, the allowance must also be settled-only.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount,
        bool includeUnsettled
    ) external returns (bool);
}
