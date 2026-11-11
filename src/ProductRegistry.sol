// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IProductRegistry} from "./interfaces/IProductRegistry.sol";
import {IMerchantRegistry} from "./interfaces/IMerchantRegistry.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";
import {MerchantRoles} from "./MerchantRoles.sol";

/// @title ProductRegistry
/// @notice Per-merchant product catalog: commission rate, product type, active flag, card URI.
/// @dev Products are keyed by `(merchantId, productId)`; `productId` is a merchant-chosen
///      `bytes32` and is unique only within that merchant. Existence is encoded as
///      `createdAt != 0`, so a product can never be deleted — only deactivated.
///
///      Authorization is fully delegated to `MerchantRegistry.hasRole`, resolved through PAR at
///      call time (NOT cached): the merchant owner implicitly passes every check, and delegated
///      `PRODUCT_MANAGER_ROLE` / `COMMISSION_MANAGER_ROLE` holders pass their respective checks.
///      Commission changes are gated by a separate role from catalog edits on purpose
///      (financial authority vs. content authority).
///
///      Commission is LIVE: `SplitRouter` reads `commissionBps` from this registry at settlement
///      time, so `setCommission` changes the split of every in-flight purchase immediately.
///      The only on-chain bound is `commissionBps <= 10_000`; the router additionally clamps to
///      `10_000 - platformFeeBps` so a raise can never brick settlement (README §6).
///
///      `isProductActive` is the single predicate every consumer (SplitRouter, ReviewRegistry)
///      uses, and it folds the merchant's own active state in — a suspended merchant's products
///      all read inactive without any per-product write.
contract ProductRegistry is IProductRegistry {
    /// @dev Protocol address registry; `MERCHANT_REGISTRY` is resolved from it on every call.
    IProtocolAddressRegistry private immutable _PROTOCOL;
    /// @dev Basis-point denominator; the only rate bound enforced here is `<= BPS_DENOM`.
    uint256 private constant BPS_DENOM = 10_000;

    /// @dev `createdAt == 0` means "does not exist". Nothing ever resets it.
    mapping(uint256 merchantId => mapping(bytes32 productId => Product)) private _products;

    /// @param protocolAddressRegistry ProtocolAddressRegistry (PAR). Not zero-checked; a wrong
    ///                                address makes every write revert on the first `getAddress`.
    constructor(address protocolAddressRegistry) {
        _PROTOCOL = IProtocolAddressRegistry(protocolAddressRegistry);
    }

    // =========================================================================
    // Merchant owner / PRODUCT_MANAGER — write
    // =========================================================================

    /// @inheritdoc IProductRegistry
    /// @dev Check order: role → merchant active → not-already-exists → rate bound. The merchant
    ///      must be active at creation time only; later suspension is reflected via
    ///      `isProductActive`, not by mutating the product. `productType` is stored verbatim
    ///      (0 = Repeat, 1 = OneOff) and forwarded into every escrow record for this product.
    ///      `active` is always true on creation; use `setProductActive` to hide a product.
    function addProduct(
        uint256 merchantId,
        bytes32 productId,
        uint16 commissionBps,
        ProductType productType,
        string calldata productCardURI
    ) external {
        _checkProductManager(merchantId);
        address _merchantRegistry = _PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY());

        if (!IMerchantRegistry(_merchantRegistry).isActive(merchantId)) revert MerchantNotActive(merchantId);
        if (_products[merchantId][productId].createdAt != 0) revert ProductAlreadyExists(merchantId, productId);

        _validateRates(commissionBps);

        _products[merchantId][productId] = Product({
            merchantId: merchantId,
            productId: productId,
            commissionBps: commissionBps,
            active: true,
            productCardURI: productCardURI,
            createdAt: uint40(block.timestamp), // uint40 is good until year ~36812; also the existence flag
            productType: productType
        });

        emit ProductAdded(merchantId, productId, commissionBps);
    }

    /// @inheritdoc IProductRegistry
    /// @dev `PRODUCT_MANAGER_ROLE` (or owner). The URI is off-chain metadata only; no contract
    ///      reads it. Not gated on merchant/product active state — a hidden product may be edited.
    function setProductCardURI(uint256 merchantId, bytes32 productId, string calldata uri) external {
        _checkProductManager(merchantId);
        _requireProduct(merchantId, productId);
        _products[merchantId][productId].productCardURI = uri;
        emit ProductCardURIUpdated(merchantId, productId, uri);
    }

    /// @inheritdoc IProductRegistry
    /// @dev `PRODUCT_MANAGER_ROLE` (or owner). Deactivating takes effect immediately for BOTH
    ///      rails: `route()` reverts `ProductNotActive` before pulling funds, while
    ///      `splitCharge()` reverts after funds are already pooled in the router (README §9,
    ///      "settlement-time reverts park funds"). Idempotent; emits on every call.
    function setProductActive(uint256 merchantId, bytes32 productId, bool active) external {
        _checkProductManager(merchantId);
        _requireProduct(merchantId, productId);
        _products[merchantId][productId].active = active;
        emit ProductActiveSet(merchantId, productId, active);
    }

    // =========================================================================
    // Merchant owner / COMMISSION_MANAGER — write
    // =========================================================================

    /// @inheritdoc IProductRegistry
    /// @dev `COMMISSION_MANAGER_ROLE` (or owner). Takes effect for every not-yet-settled purchase
    ///      of this product (commission is read live at settlement — see the contract header). Only
    ///      bound: `<= 10_000`. There is no lower bound; 0 disables commission and therefore
    ///      escrow-funded cashback for the product.
    function setCommission(uint256 merchantId, bytes32 productId, uint16 commissionBps) external {
        _checkCommissionManager(merchantId);
        _requireProduct(merchantId, productId);
        _validateRates(commissionBps);
        _products[merchantId][productId].commissionBps = commissionBps;
        emit CommissionUpdated(merchantId, productId, commissionBps);
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc IProductRegistry
    /// @dev Reverts `ProductNotFound` for an unknown pair.
    function getProduct(uint256 merchantId, bytes32 productId) external view returns (Product memory) {
        _requireProduct(merchantId, productId);
        return _products[merchantId][productId];
    }

    /// @inheritdoc IProductRegistry
    /// @dev Reverts `ProductNotFound` for an unknown pair. `SplitRouter._computeSplitFor` relies
    ///      on this revert to fail settlement for an attribution naming a product that was never
    ///      created (rather than silently splitting at 0% commission). Reads two fields only, so
    ///      settlement cost does not grow with the merchant-set, unbounded `productCardURI`.
    function getSettlementTerms(uint256 merchantId, bytes32 productId)
        external
        view
        returns (uint16 commissionBps, ProductType productType)
    {
        _requireProduct(merchantId, productId);
        Product storage p = _products[merchantId][productId];
        return (p.commissionBps, p.productType);
    }

    /// @inheritdoc IProductRegistry
    /// @dev Never reverts — designed as a safe gate for the payment path. Returns false when:
    ///      the product does not exist, the product is deactivated, the merchant is inactive or
    ///      suspended, OR the merchant id is not a minted identity (MerchantRegistry would revert
    ///      `MerchantNotFound`; the try/catch turns that into false). A broken/misconfigured
    ///      `MERCHANT_REGISTRY` address also yields false, failing closed.
    function isProductActive(uint256 merchantId, bytes32 productId) external view returns (bool) {
        Product storage p = _products[merchantId][productId];
        if (p.createdAt == 0) return false;
        if (!p.active) return false;

        address _merchantRegistry = _PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY());

        // Fail closed: any revert from the merchant registry reads as "not active".
        try IMerchantRegistry(_merchantRegistry).isActive(merchantId) returns (bool merchantActive) {
            return merchantActive;
        } catch {
            return false;
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Reverts `Unauthorised` unless `msg.sender` is the merchant owner or holds
    ///      `PRODUCT_MANAGER_ROLE` for `merchantId`. `MerchantRegistry.hasRole` itself reverts
    ///      `MerchantNotFound` for an unminted merchant id, so that error surfaces first.
    function _checkProductManager(uint256 merchantId) internal view {
        address _merchantRegistry = _PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY());
        if (!IMerchantRegistry(_merchantRegistry).hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, msg.sender)) {
            revert Unauthorised(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, msg.sender);
        }
    }

    /// @dev Same as `_checkProductManager` but for `COMMISSION_MANAGER_ROLE`. Kept as a separate
    ///      function (rather than parameterised) so the two authorities are visibly distinct at
    ///      every call site.
    function _checkCommissionManager(uint256 merchantId) internal view {
        address _merchantRegistry = _PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY());
        if (!IMerchantRegistry(_merchantRegistry)
                .hasRole(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, msg.sender)) {
            revert Unauthorised(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, msg.sender);
        }
    }

    /// @dev Existence check via the `createdAt != 0` convention.
    function _requireProduct(uint256 merchantId, bytes32 productId) internal view {
        if (_products[merchantId][productId].createdAt == 0) revert ProductNotFound(merchantId, productId);
    }

    /// @dev Only rate constraint enforced by this registry. Commission + platform fee ≤ 100% is
    ///      NOT checked here (the fee lives on SplitRouter); the router clamps at settlement.
    function _validateRates(uint16 commissionBps) internal pure {
        if (commissionBps > BPS_DENOM) revert InvalidRates(commissionBps);
    }
}
