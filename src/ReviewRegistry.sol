// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IReviewRegistry} from "./interfaces/IReviewRegistry.sol";
import {IProductRegistry} from "./interfaces/IProductRegistry.sol";
import {IMerchantRegistry} from "./interfaces/IMerchantRegistry.sol";
import {ICommissionEscrow} from "./interfaces/ICommissionEscrow.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ReviewRegistry
/// @notice On-chain anchor for published reviews. Stores a content hash per review together
///         with the authoring agent, the reviewed product and how the review was proven.
/// @dev Two publication paths, distinguished by `ProofType`:
///
///      1. Oracle path — `publishReview`. The backend (holder of `ORACLE_ROLE`) submits a review
///         together with an EIP-712 `ReviewCommitment` signed by the agent. The contract verifies
///         the signature against the agent's identity (NFT owner or configured `agentWallet`),
///         so the oracle can relay but cannot forge a review for an agent. Replay is prevented
///         per agent by `_usedNonces[agentId][nonce]` plus an `expiry`. Any `ProofType` EXCEPT
///         `InSystemPurchase` is accepted here.
///
///      2. Agent-direct path — `publishReviewWithEscrowProof`. No signature and no oracle: the
///         agent (or its `agentWallet`) calls directly and proves entitlement by pointing at a
///         `CommissionEscrow` record whose `buyerAgentId` is the caller's agent. Each escrow id
///         can back exactly one review. Always minted as `ProofType.InSystemPurchase`, and only
///         reviews minted this way may later be edited (`updateReviewContent`, 7-day window).
///
///      Review ids start at 1. Id 0 is reserved as the "no referral" sentinel that `SplitRouter`
///      uses to mean "this purchase carries no review, pay no commission".
///
///      Trust boundaries:
///        - `ORACLE_ROLE` can publish on behalf of any agent that signed, but not without the
///          signature. It can choose WHEN to publish (up to `expiry`) and can withhold.
///        - Content is off-chain; the chain only holds `contentHash`. The hash is agent-chosen
///          and intentionally excludes `block.timestamp` so it can be signed ahead of time.
///        - `_AGENT_REGISTRY` is cached as an immutable (README §4); `PRODUCT_REGISTRY` and
///          `ESCROW` are resolved live from PAR on every call.
///        - This contract never moves funds. Cashback release is NOT triggered by publishing
///          (see `publishReviewWithEscrowProof`); the oracle does that on `CommissionEscrow`.
contract ReviewRegistry is IReviewRegistry, AccessControl, EIP712 {
    /// @notice Role allowed to call `publishReview` (the oracle-relayed path).
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @dev EIP-712 type hash for the agent-signed commitment verified in `publishReview`.
    ///      Field order MUST match the backend and the MCP signer byte-for-byte; the domain is
    ///      `("ReviewRegistry", "1")` bound to this chain id and this contract address.
    bytes32 private constant _REVIEW_COMMITMENT_TYPEHASH = keccak256(
        "ReviewCommitment(uint256 agentId,uint256 merchantId,bytes32 productId,bytes32 contentHash,uint256 nonce,uint256 expiry)"
    );

    /// @notice How long after publication an agent-direct review may still be edited.
    /// @dev Measured from the ORIGINAL `timestamp`; an edit does not extend the window.
    uint256 public constant EDIT_WINDOW = 7 days;

    /// @dev Protocol address registry; `PRODUCT_REGISTRY` and `ESCROW` are read from it live.
    IProtocolAddressRegistry private immutable _PROTOCOL;

    /// @dev ERC-8004 identity registry, cached at deploy (README §4). Used for `ownerOf` and
    ///      `getAgentWallet` on every authorization check.
    address private immutable _AGENT_REGISTRY;

    /// @dev Next id to mint. Starts at 1 so `reviewId == 0` can mean "no review" everywhere.
    uint256 private _nextReviewId = 1;
    /// @dev Review storage. Existence is `timestamp != 0`.
    mapping(uint256 => Review) private _reviews;
    /// @dev Oracle-path replay guard: `agentId => nonce => used`. Nonces are agent-chosen and
    ///      need not be sequential; a nonce is burned even if the review is later never read.
    mapping(uint256 => mapping(uint256 => bool)) private _usedNonces;
    /// @dev Agent-direct-path replay guard: one review per escrow id, ever.
    mapping(uint256 => bool) private _usedEscrowIds;

    /// @param par   ProtocolAddressRegistry. `AGENT_REGISTRY` must already be set on it.
    /// @param admin Receives `DEFAULT_ADMIN_ROLE` (grants/revokes `ORACLE_ROLE`).
    constructor(address par, address admin) EIP712("ReviewRegistry", "1") {
        IProtocolAddressRegistry protocol = IProtocolAddressRegistry(par);
        _PROTOCOL = protocol;
        _AGENT_REGISTRY = protocol.getAddress(protocol.AGENT_REGISTRY());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =========================================================================
    // Oracle — write
    // =========================================================================

    /// @inheritdoc IReviewRegistry
    /// @dev Oracle-relayed publication. Check order, cheapest first:
    ///        1. `proofType != InSystemPurchase` — that type is reserved for the escrow-proof path
    ///           so an oracle cannot mint an "in-system purchase" review without an escrow.
    ///        2. `expiry` not passed.
    ///        3. Nonce unused for this agent.
    ///        4. Agent exists (`_agentOwner` reverts `AgentNotRegistered` otherwise).
    ///        5. Signature recovers to the NFT owner, OR to the configured `agentWallet` when one
    ///           is set. `ECDSA.recover` itself reverts on a malformed/zero signature, so a bogus
    ///           signature never reaches the comparison as `address(0)`.
    ///        6. Product active (folds in merchant active/suspended).
    ///      Only then is the nonce burned and the review minted. No funds move; no reentrancy
    ///      surface beyond view calls into the identity and product registries.
    ///      `Sig` is a struct (nonce, expiry, agentSignature) purely to stay under the stack limit.
    function publishReview(
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        ProofType proofType,
        Sig memory eip712Sig
    ) external onlyRole(ORACLE_ROLE) returns (uint256 reviewId) {
        if (proofType == ProofType.InSystemPurchase) revert InvalidProofTypeForPath(proofType);
        if (block.timestamp > eip712Sig.expiry) revert SignatureExpired(eip712Sig.expiry, block.timestamp);
        if (_usedNonces[agentId][eip712Sig.nonce]) revert NonceAlreadyUsed(agentId, eip712Sig.nonce);

        address agentOwner = _agentOwner(agentId);

        // Domain separator binds chainId + this contract, so a commitment signed for another
        // deployment or chain cannot be replayed here.
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _REVIEW_COMMITMENT_TYPEHASH,
                    agentId,
                    merchantId,
                    productId,
                    contentHash,
                    eip712Sig.nonce,
                    eip712Sig.expiry
                )
            )
        );
        address recovered = ECDSA.recover(digest, eip712Sig.agentSignature);
        if (recovered != agentOwner) {
            // Fallback: the agent may have delegated signing to a hot `agentWallet`.
            address wallet = IIdentityRegistry(_AGENT_REGISTRY).getAgentWallet(agentId);
            if (wallet == address(0) || recovered != wallet) {
                revert InvalidAgentSignature(agentId, recovered, agentOwner, wallet);
            }
        }

        _requireProductActive(merchantId, productId);
        _usedNonces[agentId][eip712Sig.nonce] = true;

        return _mintReview(agentId, merchantId, productId, contentHash, proofType);
    }

    // =========================================================================
    // Agent-direct — write
    // =========================================================================

    /// @inheritdoc IReviewRegistry
    /// @dev Signature-less publication authorized by `msg.sender` + an escrow record.
    ///        - Caller must control `agentId` (NFT owner or configured `agentWallet`). An unminted
    ///          agent id, including `SENTINEL_BUYER`, reverts `AgentNotRegistered` inside
    ///          `_isAgentCaller`, so an unbound agent-less buyer cannot use this path until it
    ///          has called `CommissionEscrow.bind`.
    ///        - The escrow is fetched live from the current PAR `ESCROW`; `getEscrow` reverts
    ///          `EscrowNotFound` for an unknown id.
    ///        - `record.buyerAgentId` must equal `agentId` — the reviewer of the purchase cannot
    ///          claim the buyer's review slot, and vice versa.
    ///        - Each escrow id backs exactly one review. Mismatch and reuse both revert with the
    ///          same `EscrowMismatch(escrowId)` so a caller cannot probe which escrows are spent.
    ///        - Merchant/product are taken from the escrow record, not from calldata, so the
    ///          review is pinned to what was actually bought.
    ///      Escrow state (Holding/Settled) is NOT checked: a buyer may publish after settlement;
    ///      whether cashback is still releasable is the escrow's concern.
    function publishReviewWithEscrowProof(uint256 agentId, bytes32 contentHash, uint256 escrowId)
        external
        returns (uint256 reviewId)
    {
        if (!_isAgentCaller(agentId, msg.sender)) revert CallerNotAgentOwner(agentId, msg.sender);

        address escrowAddr = _PROTOCOL.getAddress(_PROTOCOL.ESCROW());
        ICommissionEscrow.EscrowRecord memory record = ICommissionEscrow(escrowAddr).getEscrow(escrowId);

        if (record.buyerAgentId != agentId) revert EscrowMismatch(escrowId);

        if (_usedEscrowIds[escrowId]) revert EscrowMismatch(escrowId);
        _usedEscrowIds[escrowId] = true;

        uint256 merchantId = record.merchantId;
        bytes32 productId = record.productId;

        reviewId = _mintReview(agentId, merchantId, productId, contentHash, ProofType.InSystemPurchase);

        // cashback is NOT released here. Release is centralized on the oracle
        // (CommissionEscrow.releaseCashback, ORACLE_ROLE) so it can be gated on votes.
        // Publishing the review only records it; the backend triggers release after sync.
    }

    // =========================================================================
    // Agent-direct — edit
    // =========================================================================

    /// @inheritdoc IReviewRegistry
    /// @dev Only `InSystemPurchase` reviews (the agent-direct path) are editable; oracle-path
    ///      reviews carry a signed commitment to a specific `contentHash` and are immutable.
    ///      Authorization is re-evaluated live against the CURRENT owner/agentWallet, so an
    ///      agent NFT transferred within the window hands edit rights to the new owner.
    ///      The window is anchored on the original `timestamp`, never on `editedAt`. Any number
    ///      of edits are allowed inside the window; each overwrites `contentHash` and `editedAt`.
    ///      Product active state is NOT re-checked on edit.
    function updateReviewContent(uint256 reviewId, bytes32 newContentHash) external {
        _requireExists(reviewId);
        Review storage r = _reviews[reviewId];
        if (r.proofType != ProofType.InSystemPurchase) revert NotEditablePath(reviewId);
        if (!_isAgentCaller(r.agentId, msg.sender)) revert CallerNotAgentOwner(r.agentId, msg.sender);
        if (block.timestamp > uint256(r.timestamp) + EDIT_WINDOW) revert EditWindowClosed(reviewId);
        r.contentHash = newContentHash;
        r.editedAt = uint40(block.timestamp);
        emit ReviewContentUpdated(reviewId, newContentHash, r.editedAt);
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc IReviewRegistry
    /// @dev Reverts `ReviewNotFound` for an unknown id. `SplitRouter._settleAndDeposit` depends
    ///      on this revert: an attribution naming a non-existent `reviewId` fails settlement
    ///      instead of paying commission to agent 0.
    function getReview(uint256 reviewId) external view returns (Review memory) {
        _requireExists(reviewId);
        return _reviews[reviewId];
    }

    /// @inheritdoc IReviewRegistry
    /// @dev Non-reverting existence probe (`timestamp != 0`).
    function exists(uint256 reviewId) external view returns (bool) {
        return _reviews[reviewId].timestamp != 0;
    }

    /// @inheritdoc IReviewRegistry
    /// @dev Equals the highest minted id, since ids are dense from 1.
    function totalReviews() external view returns (uint256) {
        return _nextReviewId - 1;
    }

    /// @inheritdoc IReviewRegistry
    /// @dev Lets the backend pick an unused nonce without trial submission.
    function isNonceUsed(uint256 agentId, uint256 nonce) external view returns (bool) {
        return _usedNonces[agentId][nonce];
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Existence check via the `timestamp != 0` convention.
    function _requireExists(uint256 reviewId) internal view {
        if (_reviews[reviewId].timestamp == 0) revert ReviewNotFound(reviewId);
    }

    /// @dev Owner lookup doubling as an existence check. ERC-721 `ownerOf` reverts for an
    ///      unminted token; the try/catch maps that (and any other registry revert) to
    ///      `AgentNotRegistered`.
    function _agentOwner(uint256 agentId) internal view returns (address owner) {
        try IERC721(_AGENT_REGISTRY).ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            revert AgentNotRegistered(agentId);
        }
    }

    // Returns true if caller is the NFT owner OR the configured agentWallet (if non-zero).
    // _agentOwner() reverts AgentNotRegistered before this check if the agent does not exist.
    // Same rule as CommissionEscrow.bind and the payout resolution in _resolveWallet on the
    // escrow/router, so "who controls an agent" has one definition protocol-wide.
    function _isAgentCaller(uint256 agentId, address caller) internal view returns (bool) {
        address owner = _agentOwner(agentId);
        if (caller == owner) return true;
        address wallet = IIdentityRegistry(_AGENT_REGISTRY).getAgentWallet(agentId);
        return wallet != address(0) && caller == wallet;
    }

    /// @dev Merchant first, so an inactive or suspended merchant reverts `MerchantNotActive` (as
    ///      in `SplitRouter`) rather than the `ProductNotActive` that `isProductActive` would
    ///      also produce. Both registries are resolved live via PAR. `isProductActive` never
    ///      reverts; `isActive` does, with `MerchantNotFound`, for an id that was never minted —
    ///      the same raw error `SplitRouter` surfaces for that case.
    function _requireProductActive(uint256 merchantId, bytes32 productId) internal view {
        if (!IMerchantRegistry(_PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY())).isActive(merchantId)) {
            revert MerchantNotActive(merchantId);
        }
        if (!IProductRegistry(_PROTOCOL.getAddress(_PROTOCOL.PRODUCT_REGISTRY()))
                .isProductActive(merchantId, productId)) {
            revert ProductNotActive(merchantId, productId);
        }
    }

    /// @dev Shared mint for both paths. Assigns the next dense id, stamps `block.timestamp`
    ///      (uint40 — safe until year ~36812) and emits `ReviewPublished`. `editedAt` starts at 0
    ///      so "never edited" is distinguishable from "edited in the publication block".
    function _mintReview(
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        ProofType proofType
    ) internal returns (uint256 reviewId) {
        reviewId = _nextReviewId++;
        uint40 ts = uint40(block.timestamp);
        _reviews[reviewId] = Review({
            agentId: agentId,
            merchantId: merchantId,
            productId: productId,
            contentHash: contentHash,
            proofType: proofType,
            timestamp: ts,
            editedAt: 0
        });
        emit ReviewPublished(reviewId, agentId, merchantId, productId, contentHash, proofType, ts);
    }
}
