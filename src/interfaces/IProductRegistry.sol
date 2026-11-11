// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IProductRegistry
/// @notice On-chain product records for all merchant products.
///         Stores exactly what the protocol needs to function trustlessly:
///         the product identifier, commission rate, active status,
///         and a pointer to off-chain metadata. Product names, descriptions,
///         endpoint URLs, and categories live off-chain in Supabase.
///
///         Intentionally separate from MerchantRegistry: product CRUD is high-frequency
///         while merchant identity is low-frequency. Separation reduces the audit surface
///         of the identity contract and allows independent upgrade paths.
///
///         The commission rate stored here is read LIVE by SplitRouter at settlement.
///         The merchant's current rate applies to every purchase, including
///         purchases authorised before the rate changed. Signed attribution tokens carry
///         no commission rate. The only bound is a structural clamp to
///         (10_000 - platformFeeBps), applied by the router so a rate change cannot make
///         settlement revert; it is not a rate any party agreed to.
///
/// @dev    All write access is gated by MerchantRegistry.hasRole(). The registry address
///         is resolved from ProtocolAddressRegistry at construction and stored as an immutable.
///         productId is a bytes32 derived from keccak256 of a merchant-assigned slug,
///         scoped per merchant (i.e. collisions between merchants are acceptable).
interface IProductRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Whether the product is repeat-purchase or one-off.
    ///         Drives Review Rank signal weights and escrow unlock formula selection.
    enum ProductType {
        Repeat,
        OneOff
    }

    /// @notice Full on-chain record for a product.
    struct Product {
        /// @dev The merchant that owns this product.
        uint256 merchantId;
        /// @dev keccak256 of a merchant-assigned slug. Unique per merchant.
        bytes32 productId;
        /// @dev Commission rate in basis points (e.g. 1000 = 10%). SplitRouter reads the live
        ///      commission rate from here at settlement, on both the x402 and MPP charge
        ///      paths — the merchant's current rate applies to every purchase.
        uint16 commissionBps;
        /// @dev Whether new purchases and ref links are accepted for this product.
        bool active;
        /// @dev URI pointing to off-chain product metadata JSON (IPFS CID or HTTPS).
        string productCardURI;
        /// @dev Block timestamp when the product was first added.
        uint40 createdAt;
        /// @dev Whether this is a repeat-purchase or one-off product.
        ///      Drives Review Rank signal weights and escrow unlock formula selection.
        ProductType productType;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new product is added to a merchant's catalogue.
    /// @param merchantId    The merchant that owns the product.
    /// @param productId     The product identifier.
    /// @param commissionBps The initial commission rate in basis points.
    event ProductAdded(uint256 indexed merchantId, bytes32 indexed productId, uint16 commissionBps);

    /// @notice Emitted when the commission rate is updated for a product.
    ///         The new rate applies LIVE at settlement, including to purchases
    ///         already authorised under the previous rate.
    /// @param merchantId       The merchant that owns the product.
    /// @param productId        The product identifier.
    /// @param newCommissionBps The updated commission rate.
    event CommissionUpdated(uint256 indexed merchantId, bytes32 indexed productId, uint16 newCommissionBps);

    /// @notice Emitted when a product's active status changes.
    /// @param merchantId The merchant that owns the product.
    /// @param productId  The product identifier.
    /// @param active     The new active status.
    event ProductActiveSet(uint256 indexed merchantId, bytes32 indexed productId, bool indexed active);

    /// @notice Emitted when a product's off-chain metadata URI is updated.
    /// @param merchantId The merchant that owns the product.
    /// @param productId  The product identifier.
    /// @param uri        The new product card URI.
    event ProductCardURIUpdated(uint256 indexed merchantId, bytes32 indexed productId, string uri);

    // =========================================================================
    // Merchant owner / PRODUCT_MANAGER — write
    // =========================================================================

    /// @notice Adds a new product to the merchant's on-chain catalogue.
    ///         Access: NFT owner of merchantId OR address holding PRODUCT_MANAGER
    ///         role for this merchantId in MerchantRegistry.
    /// @dev    Reverts if the productId already exists for this merchant.
    ///         Reverts if productType > 1.
    ///         Emits ProductAdded.
    /// @param merchantId             The token ID of the owning merchant. Must be active.
    /// @param productId              bytes32 identifier, typically keccak256 of a slug string.
    /// @param commissionBps          Initial commission rate in basis points. Must be <= 10000.
    /// @param productType            Repeat or OneOff. ABI decoding rejects out-of-range values.
    /// @param productCardURI         URI pointing to off-chain product metadata JSON.
    function addProduct(
        uint256 merchantId,
        bytes32 productId,
        uint16 commissionBps,
        ProductType productType,
        string calldata productCardURI
    ) external;

    /// @notice Updates the off-chain metadata pointer for a product.
    ///         Access: NFT owner of merchantId OR PRODUCT_MANAGER for this merchantId.
    /// @dev    Emits ProductCardURIUpdated.
    /// @param merchantId  The token ID of the owning merchant.
    /// @param productId   The product to update.
    /// @param uri         The new product card URI.
    function setProductCardURI(uint256 merchantId, bytes32 productId, string calldata uri) external;

    /// @notice Activates or inactivates a product.
    ///         Inactive products cannot generate new ref links or receive purchases.
    ///         Access: NFT owner of merchantId OR PRODUCT_MANAGER for this merchantId.
    /// @dev    Emits ProductActiveSet.
    /// @param merchantId The token ID of the owning merchant.
    /// @param productId  The product to update.
    /// @param active     True to activate; false to inactivate.
    function setProductActive(uint256 merchantId, bytes32 productId, bool active) external;

    // =========================================================================
    // Merchant owner / COMMISSION_MANAGER — write
    // =========================================================================

    /// @notice Updates the commission rate for an existing product.
    ///         The new rate is read LIVE by SplitRouter at settlement, so it
    ///         applies to every purchase that settles after this call — including ref links
    ///         issued, and payments authorised, under the previous rate. There is no locked
    ///         or signed rate anywhere on-chain.
    ///         Access: NFT owner of merchantId OR COMMISSION_MANAGER for this merchantId.
    ///         Intentionally separate from PRODUCT_MANAGER to restrict financial authority.
    /// @dev    Emits CommissionUpdated.
    /// @param merchantId      The token ID of the owning merchant.
    /// @param productId       The product to update.
    /// @param commissionBps   New commission rate in basis points. Must be <= 10000.
    function setCommission(uint256 merchantId, bytes32 productId, uint16 commissionBps) external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns the full on-chain record for a product, including `productCardURI`.
    ///         For off-chain readers; the payment path uses getSettlementTerms instead.
    /// @param merchantId The token ID of the owning merchant.
    /// @param productId  The product identifier.
    /// @return The full Product struct.
    function getProduct(uint256 merchantId, bytes32 productId) external view returns (Product memory);

    /// @notice Returns only the fields settlement needs, without copying `productCardURI`.
    ///         Called by SplitRouter on every route() and splitCharge().
    /// @dev    Reverts ProductNotFound for an unknown pair, like getProduct.
    /// @param merchantId The token ID of the owning merchant.
    /// @param productId  The product identifier.
    /// @return commissionBps The live commission rate in basis points.
    /// @return productType   The product type recorded on the escrow.
    function getSettlementTerms(uint256 merchantId, bytes32 productId)
        external
        view
        returns (uint16 commissionBps, ProductType productType);

    /// @notice Returns true if the product exists and its active flag is true,
    ///         and the owning merchant is also active (not suspended or paused).
    ///         Checked by ReviewRegistry before publishReview and by the backend
    ///         at ref link generation time.
    /// @param merchantId The token ID of the owning merchant.
    /// @param productId  The product identifier.
    /// @return True if new purchases and ref links are currently accepted.
    function isProductActive(uint256 merchantId, bytes32 productId) external view returns (bool);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a write is attempted by an address that lacks the required role.
    error Unauthorised(uint256 merchantId, bytes32 role, address caller);

    /// @notice Thrown when addProduct is called with a productId that already exists
    ///         for this merchantId.
    error ProductAlreadyExists(uint256 merchantId, bytes32 productId);

    /// @notice Thrown when a write or read targets a productId that does not exist
    ///         for the given merchantId.
    error ProductNotFound(uint256 merchantId, bytes32 productId);

    /// @notice Thrown when commissionBps exceeds 10000 (100%).
    error InvalidRates(uint16 commissionBps);

    /// @notice Thrown when addProduct is called and the owning merchant is not active.
    error MerchantNotActive(uint256 merchantId);
}
