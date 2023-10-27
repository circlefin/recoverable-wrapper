// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

contract SigUtils {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    // computes the hash of a permit
    function getStructHash(bytes32 typehash, address account, uint128 nonce, uint256 rAmount, uint256 expiration, uint256 quote)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    typehash,
                    account,
                    nonce,
                    rAmount,
                    expiration,
                    quote
                )
            );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(bytes32 typehash, address account, uint128 nonce, uint256 rAmount, uint256 expiration, uint256 quote)
        public
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    getStructHash(typehash, account, nonce, rAmount, expiration, quote)
                )
            );
    }
}
