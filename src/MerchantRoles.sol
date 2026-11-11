// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

library MerchantRoles {
    /// @notice Role that permits adding products, updating product card URIs,
    ///         and toggling the product active flag in ProductRegistry.
    bytes32 public constant PRODUCT_MANAGER_ROLE = keccak256("PRODUCT_MANAGER_ROLE");

    /// @notice Role that permits updating commissionBps and cashbackBps for
    ///         existing products in ProductRegistry.
    ///         Intentionally separate from PRODUCT_MANAGER_ROLE to restrict financial authority.
    bytes32 public constant COMMISSION_MANAGER_ROLE = keccak256("COMMISSION_MANAGER_ROLE");

    /// @notice Role that permits signing x402 settlement requests (facilitator /verify + /settle)
    ///         on the merchant's behalf. Checked OFF-CHAIN by the facilitator via hasRole; no
    ///         contract consumes it. Exists so a merchant's always-on server holds a key that can
    ///         do nothing but settle, instead of the owner key.
    bytes32 public constant SETTLEMENT_SIGNER_ROLE = keccak256("SETTLEMENT_SIGNER_ROLE");
}
