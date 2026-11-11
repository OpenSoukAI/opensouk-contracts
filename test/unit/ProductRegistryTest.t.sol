// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {ProductRegistry} from "../../src/ProductRegistry.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {MerchantRoles} from "../../src/MerchantRoles.sol";

/// @dev Stub whose isActive() always reverts — covers the catch branch in isProductActive().
contract RevertingMerchantRegistry {
    function isActive(uint256) external pure returns (bool) {
        revert("always reverts");
    }
}

contract ProductRegistryTest is MockFixture {
    ProductRegistry internal productReg;

    address internal merchantOwner = makeAddr("merchantOwner");
    address internal productManager = makeAddr("productManager");
    address internal commissionManager = makeAddr("commissionManager");
    address internal outsider = makeAddr("outsider");

    uint256 internal merchantId;
    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");

    function setUp() public override {
        super.setUp();
        productReg = new ProductRegistry(address(par));
        merchantId = agentRegistry.mint(merchantOwner);
        merchantRegistry.setActiveRaw(merchantId, true);
        // Owner implicitly holds all roles in the real MerchantRegistry; mirror that in the mock.
        merchantRegistry.setRoleRaw(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, merchantOwner, true);
        merchantRegistry.setRoleRaw(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, merchantOwner, true);
        merchantRegistry.setRoleRaw(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, productManager, true);
        merchantRegistry.setRoleRaw(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, commissionManager, true);
    }

    // =========================================================================
    // addProduct
    // =========================================================================

    function test_AddProduct_OwnerCanAdd() public {
        vm.prank(merchantOwner);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "ipfs://test");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).commissionBps, 1000);
    }

    function test_AddProduct_ProductManagerCanAdd() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "ipfs://test");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).commissionBps, 1000);
    }

    function test_AddProduct_EmitsProductAdded() public {
        vm.expectEmit(true, true, false, true);
        emit IProductRegistry.ProductAdded(merchantId, PRODUCT_ID, 1000);
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "ipfs://test");
    }

    function test_AddProduct_StoresCorrectFields() public {
        uint40 ts = uint40(block.timestamp);
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "ipfs://card");

        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.merchantId, merchantId);
        assertEq(p.productId, PRODUCT_ID);
        assertEq(p.commissionBps, 1000);
        assertEq(p.productCardURI, "ipfs://card");
        assertEq(p.createdAt, ts);
        assertTrue(p.active);
        assertTrue(p.productType == IProductRegistry.ProductType.Repeat);
    }

    function test_AddProduct_ActiveByDefault() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
        assertTrue(productReg.getProduct(merchantId, PRODUCT_ID).active);
    }

    function test_AddProduct_Revert_MerchantNotActive() public {
        merchantRegistry.setActiveRaw(merchantId, false);
        vm.prank(productManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.MerchantNotActive.selector, merchantId));
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
    }

    function test_AddProduct_Revert_ProductAlreadyExists() public {
        vm.startPrank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductAlreadyExists.selector, merchantId, PRODUCT_ID));
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
        vm.stopPrank();
    }

    function test_AddProduct_Revert_InvalidRates_CommissionExceeds() public {
        vm.prank(productManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.InvalidRates.selector, uint16(10_001)));
        productReg.addProduct(merchantId, PRODUCT_ID, 10_001, IProductRegistry.ProductType.Repeat, "");
    }

    function test_addProduct_revertsOnCommissionOver100pct() public {
        vm.prank(productManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.InvalidRates.selector, uint16(10_001)));
        productReg.addProduct(merchantId, PRODUCT_ID, 10_001, IProductRegistry.ProductType.Repeat, "uri");
    }

    function test_AddProduct_Revert_Unauthorised() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector, merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, outsider
            )
        );
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
    }

    function test_AddProduct_ZeroRates_Allowed() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 0, IProductRegistry.ProductType.Repeat, "");
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.commissionBps, 0);
    }

    function test_AddProduct_MaxRates_Allowed() public {
        // commissionBps=10000: valid
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 10000, IProductRegistry.ProductType.Repeat, "");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).commissionBps, 10000);
    }

    function test_AddProduct_DifferentProductIds_SameMerchant() public {
        bytes32 productB = keccak256("product-beta");
        vm.startPrank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "");
        productReg.addProduct(merchantId, productB, 500, IProductRegistry.ProductType.Repeat, ""); // must not revert
        vm.stopPrank();
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).commissionBps, 1000);
        assertEq(productReg.getProduct(merchantId, productB).commissionBps, 500);
    }

    // =========================================================================
    // setProductCardURI
    // =========================================================================

    function _addProduct() internal {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.Repeat, "ipfs://old");
    }

    function test_SetProductCardURI_OwnerCanUpdate() public {
        _addProduct();
        vm.prank(merchantOwner);
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "ipfs://new");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).productCardURI, "ipfs://new");
    }

    function test_SetProductCardURI_ProductManagerCanUpdate() public {
        _addProduct();
        vm.prank(productManager);
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "ipfs://new");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).productCardURI, "ipfs://new");
    }

    function test_SetProductCardURI_EmitsProductCardURIUpdated() public {
        _addProduct();
        vm.expectEmit(true, true, false, true);
        emit IProductRegistry.ProductCardURIUpdated(merchantId, PRODUCT_ID, "ipfs://new");
        vm.prank(productManager);
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "ipfs://new");
    }

    function test_SetProductCardURI_Revert_Unauthorised() public {
        _addProduct();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector, merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, outsider
            )
        );
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "ipfs://new");
    }

    function test_SetProductCardURI_Revert_CommissionManager_Unauthorised() public {
        _addProduct();
        vm.prank(commissionManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector,
                merchantId,
                MerchantRoles.PRODUCT_MANAGER_ROLE,
                commissionManager
            )
        );
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "ipfs://new");
    }

    function test_SetProductCardURI_Revert_ProductNotFound() public {
        bytes32 unknownProduct = keccak256("no-such-product");
        vm.prank(productManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductNotFound.selector, merchantId, unknownProduct));
        productReg.setProductCardURI(merchantId, unknownProduct, "ipfs://new");
    }

    function test_SetProductCardURI_EmptyString_Allowed() public {
        _addProduct();
        vm.prank(productManager);
        productReg.setProductCardURI(merchantId, PRODUCT_ID, "");
        assertEq(productReg.getProduct(merchantId, PRODUCT_ID).productCardURI, "");
    }

    // =========================================================================
    // setProductActive
    // =========================================================================

    function test_SetProductActive_OwnerCanDeactivate() public {
        _addProduct();
        vm.prank(merchantOwner);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
        assertFalse(productReg.getProduct(merchantId, PRODUCT_ID).active);
    }

    function test_SetProductActive_OwnerCanActivate() public {
        _addProduct();
        vm.startPrank(merchantOwner);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
        productReg.setProductActive(merchantId, PRODUCT_ID, true);
        vm.stopPrank();
        assertTrue(productReg.getProduct(merchantId, PRODUCT_ID).active);
    }

    function test_SetProductActive_ProductManagerCanToggle() public {
        _addProduct();
        vm.startPrank(productManager);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
        assertFalse(productReg.getProduct(merchantId, PRODUCT_ID).active);
        productReg.setProductActive(merchantId, PRODUCT_ID, true);
        assertTrue(productReg.getProduct(merchantId, PRODUCT_ID).active);
        vm.stopPrank();
    }

    function test_SetProductActive_EmitsProductActiveSet() public {
        _addProduct();
        vm.expectEmit(true, true, false, true);
        emit IProductRegistry.ProductActiveSet(merchantId, PRODUCT_ID, false);
        vm.prank(productManager);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
    }

    function test_SetProductActive_Revert_Unauthorised() public {
        _addProduct();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector, merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, outsider
            )
        );
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
    }

    function test_SetProductActive_Revert_CommissionManager_Unauthorised() public {
        _addProduct();
        vm.prank(commissionManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector,
                merchantId,
                MerchantRoles.PRODUCT_MANAGER_ROLE,
                commissionManager
            )
        );
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
    }

    function test_SetProductActive_Revert_ProductNotFound() public {
        bytes32 unknownProduct = keccak256("no-such-product");
        vm.prank(productManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductNotFound.selector, merchantId, unknownProduct));
        productReg.setProductActive(merchantId, unknownProduct, false);
    }

    function test_SetProductActive_Idempotent_AlreadyActive() public {
        _addProduct(); // active=true by default
        vm.prank(productManager);
        productReg.setProductActive(merchantId, PRODUCT_ID, true); // must not revert
        assertTrue(productReg.getProduct(merchantId, PRODUCT_ID).active);
    }

    function test_SetProductActive_Idempotent_AlreadyInactive() public {
        _addProduct();
        vm.startPrank(productManager);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
        productReg.setProductActive(merchantId, PRODUCT_ID, false); // must not revert
        vm.stopPrank();
        assertFalse(productReg.getProduct(merchantId, PRODUCT_ID).active);
    }

    // =========================================================================
    // setCommission
    // =========================================================================

    function test_SetCommission_OwnerCanUpdate() public {
        _addProduct();
        vm.prank(merchantOwner);
        productReg.setCommission(merchantId, PRODUCT_ID, 2000);
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.commissionBps, 2000);
    }

    function test_SetCommission_CommissionManagerCanUpdate() public {
        _addProduct();
        vm.prank(commissionManager);
        productReg.setCommission(merchantId, PRODUCT_ID, 2000);
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.commissionBps, 2000);
    }

    function test_SetCommission_EmitsCommissionUpdated() public {
        _addProduct();
        vm.expectEmit(true, true, false, true);
        emit IProductRegistry.CommissionUpdated(merchantId, PRODUCT_ID, 2000);
        vm.prank(commissionManager);
        productReg.setCommission(merchantId, PRODUCT_ID, 2000);
    }

    function test_SetCommission_Revert_InvalidRates_CommissionExceeds() public {
        _addProduct();
        vm.prank(commissionManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.InvalidRates.selector, uint16(10001)));
        productReg.setCommission(merchantId, PRODUCT_ID, 10001);
    }

    function test_SetCommission_Revert_Unauthorised_Outsider() public {
        _addProduct();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector, merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, outsider
            )
        );
        productReg.setCommission(merchantId, PRODUCT_ID, 2000);
    }

    function test_SetCommission_ProductManager_Revert_Unauthorised() public {
        _addProduct();
        vm.prank(productManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProductRegistry.Unauthorised.selector,
                merchantId,
                MerchantRoles.COMMISSION_MANAGER_ROLE,
                productManager
            )
        );
        productReg.setCommission(merchantId, PRODUCT_ID, 2000);
    }

    function test_SetCommission_Revert_ProductNotFound() public {
        bytes32 unknownProduct = keccak256("no-such-product");
        vm.prank(commissionManager);
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductNotFound.selector, merchantId, unknownProduct));
        productReg.setCommission(merchantId, unknownProduct, 1000);
    }

    function test_SetCommission_ZeroRates_Allowed() public {
        _addProduct();
        vm.prank(commissionManager);
        productReg.setCommission(merchantId, PRODUCT_ID, 0);
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.commissionBps, 0);
    }

    function test_SetCommission_MaxRate_Allowed() public {
        _addProduct();
        vm.prank(commissionManager);
        productReg.setCommission(merchantId, PRODUCT_ID, 10000);
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.commissionBps, 10000);
    }

    // =========================================================================
    // getProduct
    // =========================================================================

    function test_GetProduct_ReturnsCorrectStruct() public {
        _addProduct();
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertEq(p.merchantId, merchantId);
        assertEq(p.productId, PRODUCT_ID);
        assertEq(p.commissionBps, 1000);
        assertEq(p.productCardURI, "ipfs://old");
        assertTrue(p.active);
        assertGt(p.createdAt, 0);
    }

    function test_GetProduct_Revert_ProductNotFound() public {
        bytes32 unknownProduct = keccak256("no-such-product");
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductNotFound.selector, merchantId, unknownProduct));
        productReg.getProduct(merchantId, unknownProduct);
    }

    // =========================================================================
    // isProductActive
    // =========================================================================

    function test_IsProductActive_TrueWhenActiveAndMerchantActive() public {
        _addProduct(); // product.active=true, merchantRegistry mock has merchant active
        assertTrue(productReg.isProductActive(merchantId, PRODUCT_ID));
    }

    function test_IsProductActive_FalseWhenProductInactive() public {
        _addProduct();
        vm.prank(productManager);
        productReg.setProductActive(merchantId, PRODUCT_ID, false);
        assertFalse(productReg.isProductActive(merchantId, PRODUCT_ID));
    }

    function test_IsProductActive_FalseWhenProductNotFound() public view {
        // Non-existent product returns false, does NOT revert.
        bytes32 unknownProduct = keccak256("no-such-product");
        assertFalse(productReg.isProductActive(merchantId, unknownProduct));
    }

    function test_IsProductActive_FalseWhenMerchantInactive() public {
        _addProduct();
        merchantRegistry.setActiveRaw(merchantId, false);
        assertFalse(productReg.isProductActive(merchantId, PRODUCT_ID));
    }

    function test_IsProductActive_FalseWhenMerchantSuspended() public {
        // MockMerchantRegistry.isActive returns false when suspended.
        _addProduct();
        merchantRegistry.setSuspendedRaw(merchantId, true);
        assertFalse(productReg.isProductActive(merchantId, PRODUCT_ID));
    }

    function test_IsProductActive_FalseWhenMerchantRegistryReverts() public {
        // Covers the catch {} branch: isActive() reverts → isProductActive returns false.
        _addProduct();
        RevertingMerchantRegistry reverting = new RevertingMerchantRegistry();
        vm.prank(admin);
        par.setAddress(keccak256("MERCHANT_REGISTRY"), address(reverting));
        par.executeUpdate(keccak256("MERCHANT_REGISTRY"));
        assertFalse(productReg.isProductActive(merchantId, PRODUCT_ID));
    }

    // =========================================================================
    // addProduct — productType and lock durations
    // =========================================================================

    function test_AddProduct_StoresProductType_OneOff() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.OneOff, "ipfs://test");
        assertTrue(productReg.getProduct(merchantId, PRODUCT_ID).productType == IProductRegistry.ProductType.OneOff);
    }

    function test_AddProduct_Revert_InvalidProductType() public {
        // productType=2 is out of range for the enum; ABI decoder rejects it.
        bytes memory data = abi.encodeWithSelector(
            IProductRegistry.addProduct.selector, merchantId, PRODUCT_ID, uint16(1000), uint8(2), uint32(0), ""
        );
        vm.prank(productManager);
        (bool ok,) = address(productReg).call(data);
        assertFalse(ok);
    }

    function test_AddProduct_Revert_InvalidProductType_MaxUint8() public {
        // productType=255 is out of range for the enum; ABI decoder rejects it.
        bytes memory data = abi.encodeWithSelector(
            IProductRegistry.addProduct.selector, merchantId, PRODUCT_ID, uint16(1000), uint8(255), uint32(0), ""
        );
        vm.prank(productManager);
        (bool ok,) = address(productReg).call(data);
        assertFalse(ok);
    }

    // =========================================================================
    // getSettlementTerms (#24)
    // =========================================================================

    function test_GetSettlementTerms_ReturnsCommissionAndType() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1234, IProductRegistry.ProductType.OneOff, "ipfs://test");
        (uint16 commissionBps, IProductRegistry.ProductType productType) =
            productReg.getSettlementTerms(merchantId, PRODUCT_ID);
        assertEq(commissionBps, 1234);
        assertTrue(productType == IProductRegistry.ProductType.OneOff);
    }

    function test_GetSettlementTerms_Revert_ProductNotFound() public {
        bytes32 unknownProduct = keccak256("no-such-product");
        vm.expectRevert(abi.encodeWithSelector(IProductRegistry.ProductNotFound.selector, merchantId, unknownProduct));
        productReg.getSettlementTerms(merchantId, unknownProduct);
    }

    /// @dev The settlement read must not scale with the merchant-set URI.
    function test_GetSettlementTerms_GasIndependentOfUriLength() public {
        _addProduct();
        uint256 g = gasleft();
        productReg.getSettlementTerms(merchantId, PRODUCT_ID);
        uint256 shortUriGas = g - gasleft();

        bytes memory longUri = new bytes(4096);
        for (uint256 i = 0; i < longUri.length; i++) {
            longUri[i] = "a";
        }
        vm.prank(productManager);
        productReg.setProductCardURI(merchantId, PRODUCT_ID, string(longUri));

        g = gasleft();
        productReg.getSettlementTerms(merchantId, PRODUCT_ID);
        // Tolerance absorbs gasleft() measurement noise; copying a 4 KB string costs thousands.
        assertApproxEqAbs(g - gasleft(), shortUriGas, 50);
    }

    // =========================================================================
    // getProduct — new fields
    // =========================================================================

    function test_GetProduct_ReturnsNewFields() public {
        vm.prank(productManager);
        productReg.addProduct(merchantId, PRODUCT_ID, 1000, IProductRegistry.ProductType.OneOff, "ipfs://test");
        IProductRegistry.Product memory p = productReg.getProduct(merchantId, PRODUCT_ID);
        assertTrue(p.productType == IProductRegistry.ProductType.OneOff);
    }
}
