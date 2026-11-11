// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";

/// @dev Configurable stub. setProductRaw() inserts a product record directly.
contract MockProductRegistry is IProductRegistry {
    mapping(uint256 => mapping(bytes32 => Product)) private _products;
    mapping(uint256 => mapping(bytes32 => bool)) private _exists;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setProductRaw(uint256 merchantId, bytes32 productId, Product calldata product) external {
        _products[merchantId][productId] = product;
        _exists[merchantId][productId] = true;
    }

    function setActiveRaw(uint256 merchantId, bytes32 productId, bool active) external {
        _products[merchantId][productId].active = active;
    }

    // -------------------------------------------------------------------------
    // IProductRegistry
    // -------------------------------------------------------------------------

    function addProduct(
        uint256 merchantId,
        bytes32 productId,
        uint16 commissionBps,
        ProductType productType,
        string calldata productCardURI
    ) external {
        if (_exists[merchantId][productId]) {
            revert ProductAlreadyExists(merchantId, productId);
        }
        _products[merchantId][productId] = Product({
            merchantId: merchantId,
            productId: productId,
            commissionBps: commissionBps,
            active: true,
            productCardURI: productCardURI,
            createdAt: uint40(block.timestamp),
            productType: productType
        });
        _exists[merchantId][productId] = true;
        emit ProductAdded(merchantId, productId, commissionBps);
    }

    function setProductCardURI(uint256 merchantId, bytes32 productId, string calldata uri) external {
        _products[merchantId][productId].productCardURI = uri;
        emit ProductCardURIUpdated(merchantId, productId, uri);
    }

    function setProductActive(uint256 merchantId, bytes32 productId, bool active) external {
        _products[merchantId][productId].active = active;
        emit ProductActiveSet(merchantId, productId, active);
    }

    function setCommission(uint256 merchantId, bytes32 productId, uint16 commissionBps) external {
        _products[merchantId][productId].commissionBps = commissionBps;
        emit CommissionUpdated(merchantId, productId, commissionBps);
    }

    function getProduct(uint256 merchantId, bytes32 productId) external view returns (Product memory) {
        if (!_exists[merchantId][productId]) revert ProductNotFound(merchantId, productId);
        return _products[merchantId][productId];
    }

    function getSettlementTerms(uint256 merchantId, bytes32 productId)
        external
        view
        returns (uint16 commissionBps, ProductType productType)
    {
        if (!_exists[merchantId][productId]) revert ProductNotFound(merchantId, productId);
        Product storage p = _products[merchantId][productId];
        return (p.commissionBps, p.productType);
    }

    function isProductActive(uint256 merchantId, bytes32 productId) external view returns (bool) {
        return _exists[merchantId][productId] && _products[merchantId][productId].active;
    }
}
