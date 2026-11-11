// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IReviewRegistry
/// @notice On-chain proof of every published review.
///         Stores the content hash, attributed agent, product reference, timestamp,
///         and proof tier. Full review text and structured fields live in Supabase —
///         this contract is the immutable on-chain anchor.
///
///         Two write paths exist:
///           (a) Oracle path (publishReview): for external or admin-approved proof of usage.
///               The oracle submits an agent-signed EIP-712 payload and pays gas.
///           (b) Agent-direct path (publishReviewWithEscrowProof): for agents with a verified
///               in-system purchase in CommissionEscrow. Agent calls directly and pays gas.
///               No oracle involvement — the escrow record is the on-chain proof.
///
///         Content hash construction (must be deterministic):
///           keccak256(abi.encode(agentId, merchantId, productId, contentJSON))
///         Timestamp is excluded — EIP-712 nonce (oracle path) or escrow record
///         (agent-direct path) provides sufficient replay resistance.
///
/// @dev    Access control via OpenZeppelin AccessControl:
///           ORACLE_ROLE: publishReview
///           DEFAULT_ADMIN_ROLE: grantRole / revokeRole for ORACLE_ROLE
///         ERC-8004 AgentRegistry address is cached as an immutable at construction.
///         All other peer addresses (ProductRegistry, CommissionEscrow) are resolved
///         lazily via ProtocolAddressRegistry at call time — never cached — so that
///         contract upgrades require only a single PAR address update.
interface IReviewRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice The tier of proof used to verify the reviewer's prior usage of the product.
    ///         Stored on-chain so it is permanently visible alongside every review.
    ///         InSystemPurchase is the stronger tier — the contract verifies its own escrow
    ///         record, with no operator attesting to anything.
    ///         AdminApproved is the weaker tier. It is not a bootstrapping measure: it is the
    ///         permanent path for every purchase made outside the protocol.
    enum ProofType {
        /// @dev The reviewer bought the product outside this protocol — an x402 payment to a
        ///      merchant that has not integrated, a card payment, an invoice — then submitted
        ///      off-chain evidence of that purchase, which an operator approved by hand.
        AdminApproved,
        /// @dev The reviewer purchased the product through this protocol. A CommissionEscrow
        ///      record with buyerAgentId == agentId exists on-chain. Fully trustless — verified
        ///      by the contract directly, no oracle required.
        InSystemPurchase
    }

    /// @notice Full on-chain record for a published review.
    struct Review {
        /// @dev AgentRegistry token ID of the reviewer.
        uint256 agentId;
        /// @dev MerchantRegistry token ID.
        uint256 merchantId;
        /// @dev ProductRegistry product identifier.
        bytes32 productId;
        /// @dev keccak256(abi.encode(agentId, merchantId, productId, contentJSON)).
        ///      Timestamp excluded — EIP-712 nonce (oracle path) / escrow record (direct path)
        ///      provide replay resistance; block.timestamp is unknowable at agent signing time.
        ///      Anyone can verify this against the off-chain content in Supabase.
        ///      Mutable for InSystemPurchase reviews within EDIT_WINDOW via updateReviewContent.
        bytes32 contentHash;
        /// @dev Proof tier — permanently visible. See ProofType.
        ProofType proofType;
        /// @dev Block timestamp of publication.
        uint40 timestamp;
        /// @dev Block timestamp of last content edit; 0 if never edited.
        ///      Packs into the same storage slot as proofType + timestamp (11 bytes total).
        uint40 editedAt;
    }

    struct Sig {
        uint256 nonce;
        uint256 expiry;
        bytes agentSignature;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new review is published on-chain.
    /// @param reviewId   The auto-incremented review identifier. Included in the ref link payload.
    /// @param agentId    The reviewer's AgentRegistry token ID.
    /// @param merchantId The MerchantRegistry token ID.
    /// @param productId  The ProductRegistry product identifier.
    /// @param contentHash The keccak256 content hash verifiable against Supabase.
    /// @param proofType  The proof tier used to verify prior usage.
    /// @param timestamp  The block timestamp of publication.
    event ReviewPublished(
        uint256 indexed reviewId,
        uint256 indexed agentId,
        uint256 indexed merchantId,
        bytes32 productId,
        bytes32 contentHash,
        ProofType proofType,
        uint40 timestamp
    );

    /// @notice Emitted when an InSystemPurchase review's content hash is updated within the edit window.
    /// @param reviewId    The review identifier.
    /// @param contentHash The new keccak256 content hash.
    /// @param editedAt    Block timestamp of the edit.
    event ReviewContentUpdated(uint256 indexed reviewId, bytes32 indexed contentHash, uint40 editedAt);

    // =========================================================================
    // Oracle — write
    // =========================================================================

    /// @notice Publishes a new review on-chain. Called by the oracle backend after the
    ///         Go API server has validated the review (proof of usage, quality checks,
    ///         agent registration, flagging status).
    ///         The reviewId assigned here is included in the ref link payload that the
    ///         backend generates immediately after this call succeeds.
    /// @dev    Caller must hold ORACLE_ROLE.
    ///         On-chain EIP-712 verification: the contract recovers the signer from
    ///         `agentSignature` over a `ReviewCommitment` struct and asserts it equals
    ///         `AgentRegistry.ownerOf(agentId)`. A compromised oracle key cannot fabricate
    ///         a review attributed to an agent without that agent's signing key.
    ///
    ///         EIP-712 typed-data struct (domain: name="ReviewRegistry", version="1"):
    ///           ReviewCommitment(uint256 agentId, uint256 merchantId, bytes32 productId,
    ///                            bytes32 contentHash, uint256 nonce, uint256 expiry)
    ///
    ///         Reverts if agentId is not registered in AgentRegistry.
    ///         Reverts if productId is not active in ProductRegistry.
    ///         Reverts if eip712sig.nonce has already been used for this agentId.
    ///         Reverts if block.timestamp > eip712sig.expiry.
    ///         Reverts if recovered signer is neither AgentRegistry.ownerOf(agentId)
    ///         nor the agentWallet configured on that NFT (if non-zero).
    ///         Emits ReviewPublished.
    /// @param agentId        The AgentRegistry token ID of the reviewer.
    /// @param merchantId     The MerchantRegistry token ID.
    /// @param productId      The ProductRegistry product identifier.
    /// @param contentHash    keccak256(abi.encode(agentId, merchantId, productId, contentJSON)).
    /// @param proofType  The proof tier establishing prior usage. Must be AdminApproved;
    ///                   InSystemPurchase is reserved for publishReviewWithEscrowProof.
    /// @param eip712sig  Struct containing:
    ///                     nonce          — per-agent nonce, must be unused for this agentId.
    ///                     expiry         — unix timestamp after which the signature is invalid.
    ///                     agentSignature — EIP-712 signature over ReviewCommitment.
    /// @return reviewId  The auto-incremented ID of the newly published review.
    function publishReview(
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        ProofType proofType,
        Sig memory eip712sig
    ) external returns (uint256 reviewId);

    /// @notice Publishes a new review on-chain using an in-system purchase as proof of usage.
    ///         The caller must be the current owner of the agentId NFT in AgentRegistry, OR
    ///         the agentWallet configured on that NFT (if non-zero).
    ///         merchantId and productId are read directly from the escrow record; proofType
    ///         is set to InSystemPurchase.
    /// @dev    Reverts if msg.sender is neither AgentRegistry.ownerOf(agentId) nor the
    ///         configured agentWallet.
    ///         Reverts if escrow record does not exist or buyerAgentId != agentId.
    ///         Reverts if productId is not active in ProductRegistry.
    ///         Emits ReviewPublished.
    /// @param agentId     The AgentRegistry token ID of the reviewer. Must equal the escrow's buyerAgentId.
    /// @param contentHash keccak256(abi.encode(agentId, merchantId, productId, contentJSON)).
    ///                    merchantId and productId must match the values in the escrow record.
    /// @param escrowId    The CommissionEscrow record ID proving in-system purchase.
    /// @return reviewId   The auto-incremented ID of the newly published review.
    function publishReviewWithEscrowProof(uint256 agentId, bytes32 contentHash, uint256 escrowId)
        external
        returns (uint256 reviewId);

    // =========================================================================
    // Agent-direct — edit
    // =========================================================================

    /// @notice Updates the content hash of an InSystemPurchase review within the 7-day edit window.
    ///         The caller must be the current owner of the agentId NFT, OR the agentWallet
    ///         configured on that NFT (if non-zero).
    ///         Only reviews with proofType == InSystemPurchase are editable; oracle-path
    ///         AdminApproved reviews are immutable by design.
    /// @dev    Reverts if reviewId does not exist.
    ///         Reverts if proofType != InSystemPurchase.
    ///         Reverts if msg.sender != AgentRegistry.ownerOf(agentId).
    ///         Reverts if block.timestamp > review.timestamp + EDIT_WINDOW.
    ///         Emits ReviewContentUpdated.
    /// @param reviewId      The review identifier to update.
    /// @param newContentHash keccak256(abi.encode(agentId, merchantId, productId, newContentJSON)).
    function updateReviewContent(uint256 reviewId, bytes32 newContentHash) external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns the full on-chain record for a review.
    /// @param reviewId The review identifier.
    /// @return The Review struct with all stored fields.
    function getReview(uint256 reviewId) external view returns (Review memory);

    /// @notice Returns true if the review exists (has been published).
    /// @param reviewId The review identifier.
    function exists(uint256 reviewId) external view returns (bool);

    /// @notice Returns the total number of reviews published on-chain.
    function totalReviews() external view returns (uint256);

    /// @notice Returns true if the given nonce has already been used for the given agentId.
    /// @param agentId The AgentRegistry token ID.
    /// @param nonce   The nonce to query.
    function isNonceUsed(uint256 agentId, uint256 nonce) external view returns (bool);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when publishReview is called for an agent that is not registered
    ///         in the AgentRegistry (ownerOf reverts).
    error AgentNotRegistered(uint256 agentId);

    /// @notice Thrown when publishReview is called for a product that is not active.
    error ProductNotActive(uint256 merchantId, bytes32 productId);

    /// @notice Thrown when a review is published for a merchant that is inactive or suspended.
    error MerchantNotActive(uint256 merchantId);

    /// @notice Thrown when an operation targets a reviewId that does not exist.
    error ReviewNotFound(uint256 reviewId);

    /// @notice Thrown when publishReview is called with block.timestamp > expiry.
    error SignatureExpired(uint256 expiry, uint256 blockTimestamp);

    /// @notice Thrown when publishReview is called with a nonce already used for this agentId.
    error NonceAlreadyUsed(uint256 agentId, uint256 nonce);

    /// @notice Thrown when the EIP-712 signature in publishReview does not recover to
    ///         the NFT owner or the configured agentWallet for agentId.
    ///         Both expected anchors are surfaced: agentOwner is the NFT owner (primary
    ///         identity), agentWallet is the configured operational wallet — or address(0)
    ///         when none is set. A zero agentWallet distinguishes the "no wallet configured"
    ///         case from a "wrong wallet key" failure.
    error InvalidAgentSignature(uint256 agentId, address recovered, address agentOwner, address agentWallet);

    /// @notice Thrown when publishReview (oracle path) is called with proofType == InSystemPurchase.
    error InvalidProofTypeForPath(ProofType proofType);

    /// @notice Thrown when publishReviewWithEscrowProof or updateReviewContent is called by an
    ///         address that is neither the NFT owner nor the configured agentWallet for agentId.
    error CallerNotAgentOwner(uint256 agentId, address caller);

    /// @notice Thrown when the CommissionEscrow record at escrowId does not have
    ///         buyerAgentId == agentId, or the escrowId has already been used.
    error EscrowMismatch(uint256 escrowId);

    /// @notice Thrown when updateReviewContent is called on a review whose proofType is not
    ///         InSystemPurchase. Only buyer reviews (agent-direct path) are editable.
    error NotEditablePath(uint256 reviewId);

    /// @notice Thrown when updateReviewContent is called after the 7-day edit window has closed.
    error EditWindowClosed(uint256 reviewId);
}
