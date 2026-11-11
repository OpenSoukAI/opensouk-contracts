// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolAddressRegistry} from "../src/ProtocolAddressRegistry.sol";
import {MerchantRegistry} from "../src/MerchantRegistry.sol";
import {ProductRegistry} from "../src/ProductRegistry.sol";
import {ReviewRegistry} from "../src/ReviewRegistry.sol";
import {CommissionEscrow} from "../src/CommissionEscrow.sol";
import {SplitRouter} from "../src/SplitRouter.sol";

/// @notice Deploys and wires the full Ref-Agent protocol.
///
/// Required env vars:
///   IDENTITY_REGISTRY  — already-deployed ERC-8004 IdentityRegistry address
///   USDC               — USDC token address
///   TREASURY           — treasury address (receives platform fees)
///   ORACLE             — oracle address (ORACLE_ROLE on ReviewRegistry + CommissionEscrow)
///   ORACLE_SIGNER      — charge-attestation signer (ORACLE_SIGNER_ROLE on SplitRouter). Must
///                        differ from ORACLE.
///   KEEPER             — Chainlink Automation address (KEEPER_ROLE)
///   FACILITATOR        — x402 facilitator address, x402scan-listed identity (FACILITATOR_ROLE)
///   FACILITATOR_UNLISTED — x402 facilitator address, unlisted identity (FACILITATOR_ROLE). The
///                        facilitator service picks between the two per merchant at settle time
///                        (REF-333); both must hold the role or settlements submitted from the
///                        unlisted address revert.
///   GUARDIAN           — immutable second key on ProtocolAddressRegistry that may cancel a
///                        queued address update alongside the owner. Must be a key with different
///                        custody from the owner multisig: the whole point is that it still works
///                        when the owner key is compromised. Cannot be zero.
///
/// Optional:
///   PAUSER             — extra holder of PAUSER_ROLE on CommissionEscrow, alongside the deployer.
///                        Pausing the escrow halts BOTH payment rails, so it is the emergency
///                        lever; it is a separate role from admin so it stays reachable in minutes
///                        once admin is a multisig. The deployer is always granted it, because a
///                        deployment where nobody holds PAUSER_ROLE cannot be paused at all.
///   TIMELOCK_DELAY     — the delay the registry ENDS at, in seconds (21600 = 6h on mainnet)
///   PLATFORM_FEE_BPS   — platform fee in basis points (e.g. 200 = 2%)
///
/// The registry is always constructed with a delay of ZERO so the wiring below applies in the same
/// run — its constructor is the only path that bypasses the delay, and every other key must go
/// through setAddress. TIMELOCK_DELAY is then applied as the final step, which also takes effect
/// at once because the current delay is still zero. The script reads the delay back and reverts if
/// it did not take: a deploy that finished half-protected would look identical to a correct one.
contract Deploy is Script {
    // PAR keys
    bytes32 private constant AGENT_REGISTRY_KEY = keccak256("AGENT_REGISTRY");
    bytes32 private constant MERCHANT_REGISTRY_KEY = keccak256("MERCHANT_REGISTRY");
    bytes32 private constant PRODUCT_REGISTRY_KEY = keccak256("PRODUCT_REGISTRY");
    bytes32 private constant REVIEW_REGISTRY_KEY = keccak256("REVIEW_REGISTRY");
    bytes32 private constant ESCROW_KEY = keccak256("ESCROW");
    bytes32 private constant SPLIT_ROUTER_KEY = keccak256("SPLIT_ROUTER");
    bytes32 private constant KEEPER_KEY = keccak256("KEEPER");
    bytes32 private constant TREASURY_KEY = keccak256("TREASURY");

    // AccessControl role IDs
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 private constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 private constant FACILITATOR_ROLE = keccak256("FACILITATOR_ROLE");
    bytes32 private constant ORACLE_SIGNER_ROLE = keccak256("ORACLE_SIGNER_ROLE");
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Deployed addresses stored in script storage to avoid stack-too-deep.
    ProtocolAddressRegistry private _par;
    address private _merchantRegistry;
    address private _productRegistry;
    address private _reviewRegistry;
    address private _escrow;
    address private _splitRouter;

    function run() external {
        uint256 deployerKey = vm.envUint("KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = vm.envAddress("USDC");
        address treasury = vm.envAddress("TREASURY");
        address oracle = vm.envAddress("ORACLE");
        address oracleSigner = vm.envAddress("ORACLE_SIGNER");
        require(oracleSigner != address(0), "ORACLE_SIGNER unset");
        require(oracleSigner != oracle, "ORACLE_SIGNER must differ from ORACLE");
        address keeper = vm.envAddress("KEEPER");
        address facilitator = vm.envAddress("FACILITATOR");
        address facilitatorUnlisted = vm.envAddress("FACILITATOR_UNLISTED");
        uint256 timelockDelay = vm.envUint("TIMELOCK_DELAY");
        uint256 rawFeeBps = vm.envUint("PLATFORM_FEE_BPS");
        require(rawFeeBps <= type(uint16).max, "PLATFORM_FEE_BPS exceeds uint16");
        uint16 platformFeeBps = uint16(rawFeeBps);

        vm.startBroadcast(deployerKey);

        _deployPar(deployer, vm.envAddress("GUARDIAN"), vm.envAddress("IDENTITY_REGISTRY"), treasury);
        _deployContracts(deployer, usdc, platformFeeBps);
        _wirePar(keeper);
        _grantRoles(oracle, oracleSigner, facilitator, facilitatorUnlisted, deployer, vm.envOr("PAUSER", address(0)));
        _raiseTimelockDelay(timelockDelay);

        vm.stopBroadcast();

        _logSummary(
            deployer,
            vm.envAddress("IDENTITY_REGISTRY"),
            usdc,
            treasury,
            oracle,
            oracleSigner,
            keeper,
            facilitator,
            facilitatorUnlisted,
            platformFeeBps,
            timelockDelay
        );
    }

    // ── Step 1 ────────────────────────────────────────────────────────────────
    // Deploy ProtocolAddressRegistry with AGENT_REGISTRY and TREASURY pre-set.
    // Both must be readable the moment the protocol contracts exist:
    //   AGENT_REGISTRY — MerchantRegistry, ReviewRegistry, CommissionEscrow and
    //     SplitRouter all cache it as an immutable at their own construction.
    //   TREASURY — SplitRouter.route(), CommissionEscrow.settleHeldBack() and
    //     triggerSettleFallback() resolve it LIVE on every call, so an unset key
    //     reverts AddressNotSet and bricks all payments. Seeding it through the
    //     constructor is the only path that bypasses the timelock: setAddress()
    //     queues even a first-time set, so wiring it in _wirePar would leave
    //     settlement dead for the whole timelock window.
    function _deployPar(address deployer, address guardian, address identityRegistry, address treasury) private {
        bytes32[] memory keys = new bytes32[](2);
        address[] memory vals = new address[](2);
        keys[0] = AGENT_REGISTRY_KEY;
        vals[0] = identityRegistry;
        keys[1] = TREASURY_KEY;
        vals[1] = treasury;
        // Zero here on purpose; raised to TIMELOCK_DELAY at the end of the run.
        _par = new ProtocolAddressRegistry(deployer, guardian, 0, keys, vals);
    }

    // ── Step 2 ────────────────────────────────────────────────────────────────
    // Deploy all protocol contracts in dependency order.
    function _deployContracts(address deployer, address usdc, uint16 platformFeeBps) private {
        address par = address(_par);

        // ProductRegistry resolves every peer address lazily. MerchantRegistry does too
        // except for AGENT_REGISTRY, which it caches like the three below.
        _merchantRegistry = address(new MerchantRegistry(par, deployer));
        _productRegistry = address(new ProductRegistry(par));

        // These cache AGENT_REGISTRY as an immutable, so PAR must already have it set
        // (done in _deployPar).
        _reviewRegistry = address(new ReviewRegistry(par, deployer));
        _escrow = address(new CommissionEscrow(par, deployer, usdc));

        // SplitRouter caches AGENT_REGISTRY too; deploy last.
        _splitRouter = address(new SplitRouter(par, deployer, usdc, platformFeeBps));
    }

    // ── Step 3 ────────────────────────────────────────────────────────────────
    // Wire the remaining PAR entries. The registry is still at zero delay here, so each queued
    // update executes in the same run. There is no ORACLE key: the charge-attestation signer is a
    // role on SplitRouter, granted in _grantRoles.
    function _wirePar(address keeper) private {
        _par.setAddress(MERCHANT_REGISTRY_KEY, _merchantRegistry);
        _par.setAddress(PRODUCT_REGISTRY_KEY, _productRegistry);
        _par.setAddress(REVIEW_REGISTRY_KEY, _reviewRegistry);
        _par.setAddress(ESCROW_KEY, _escrow);
        _par.setAddress(SPLIT_ROUTER_KEY, _splitRouter);
        _par.setAddress(KEEPER_KEY, keeper);

        _par.executeUpdate(MERCHANT_REGISTRY_KEY);
        _par.executeUpdate(PRODUCT_REGISTRY_KEY);
        _par.executeUpdate(REVIEW_REGISTRY_KEY);
        _par.executeUpdate(ESCROW_KEY);
        _par.executeUpdate(SPLIT_ROUTER_KEY);
        _par.executeUpdate(KEEPER_KEY);
    }

    // ── Step 4 ────────────────────────────────────────────────────────────────
    // Grant operational roles. The deployer retains DEFAULT_ADMIN_ROLE on all
    // contracts; transfer to a multisig by granting it DEFAULT_ADMIN_ROLE then
    // revoking the deployer after confirming.
    function _grantRoles(
        address oracle,
        address oracleSigner,
        address facilitator,
        address facilitatorUnlisted,
        address deployer,
        address pauser
    ) private {
        ReviewRegistry(_reviewRegistry).grantRole(ORACLE_ROLE, oracle);

        CommissionEscrow(_escrow).grantRole(ORACLE_ROLE, oracle);

        // Both settlement identities hold the role; the facilitator service picks between them
        // per merchant at settle time (REF-333). They must be two DIFFERENT addresses: granting
        // one address the role twice is a silent no-op, the router then looks correctly
        // configured, and every merchant who chose the unlisted identity would be settled from
        // the x402scan-listed EOA and indexed there permanently.
        require(facilitator != facilitatorUnlisted, "FACILITATOR and FACILITATOR_UNLISTED must be different addresses");
        SplitRouter(_splitRouter).grantRole(FACILITATOR_ROLE, facilitator);
        SplitRouter(_splitRouter).grantRole(FACILITATOR_ROLE, facilitatorUnlisted);

        // Charge attestations verify against this role, so a compromised signer is revoked in one
        // transaction rather than waiting out the registry timelock.
        SplitRouter(_splitRouter).grantRole(ORACLE_SIGNER_ROLE, oracleSigner);

        // Always the deployer, so the escrow is never left unpausable; plus the operational pauser
        // when one is supplied. Unpausing stays with DEFAULT_ADMIN_ROLE.
        CommissionEscrow(_escrow).grantRole(PAUSER_ROLE, deployer);
        if (pauser != address(0)) {
            CommissionEscrow(_escrow).grantRole(PAUSER_ROLE, pauser);
        }
    }

    // ── Step 5 ────────────────────────────────────────────────────────────────
    // Raise the registry delay from the zero it was constructed with. Both calls apply at once
    // because the current delay is still zero. The read-back is the whole point: a run that wired
    // everything and then failed to raise the delay leaves a live protocol with no timelock and
    // nothing to show for it.
    function _raiseTimelockDelay(uint256 timelockDelay) private {
        _par.setTimelockDelay(timelockDelay);
        _par.executeTimelockDelayUpdate();
        require(_par.timelockDelay() == timelockDelay, "timelock delay not applied");
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    function _logSummary(
        address deployer,
        address identityRegistry,
        address usdc,
        address treasury,
        address oracle,
        address oracleSigner,
        address keeper,
        address facilitator,
        address facilitatorUnlisted,
        uint16 platformFeeBps,
        uint256 timelockDelay
    ) private view {
        console2.log("=== Deployment Summary ===");
        console2.log("Deployer:                ", deployer);
        console2.log("ProtocolAddressRegistry: ", address(_par));
        console2.log("PAR guardian:            ", _par.guardian());
        console2.log("MerchantRegistry:        ", _merchantRegistry);
        console2.log("ProductRegistry:         ", _productRegistry);
        console2.log("ReviewRegistry:          ", _reviewRegistry);
        console2.log("CommissionEscrow:        ", _escrow);
        console2.log("SplitRouter:             ", _splitRouter);
        console2.log("--- External / config ---");
        console2.log("IdentityRegistry:        ", identityRegistry);
        console2.log("USDC:                    ", usdc);
        console2.log("Treasury:                ", treasury);
        console2.log("Oracle:                  ", oracle);
        console2.log("Oracle signer:           ", oracleSigner);
        console2.log("Keeper:                  ", keeper);
        console2.log("Facilitator (listed):    ", facilitator);
        console2.log("Facilitator (unlisted):  ", facilitatorUnlisted);
        console2.log("Platform fee (bps):      ", platformFeeBps);
        console2.log("PAR timelock (s):        ", timelockDelay);

        console2.log("");
        console2.log("All PAR entries are live: the registry was built at zero delay and raised");
        console2.log("to the value above as the final step. Every LATER change now waits it out.");
    }
}
