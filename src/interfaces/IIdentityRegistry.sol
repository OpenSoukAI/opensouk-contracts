// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @title IIdentityRegistry
/// @notice ERC-8004 Identity Registry — ERC-721-based registry where each agent mints exactly
///         one NFT. Stores an off-chain metadata pointer, arbitrary key-value metadata, and
///         an EIP-712-authenticated payment-wallet binding.
///
/// @dev    Implements the UUPS upgradeable pattern. Storage layout is namespaced per ERC-7201
///         to prevent upgrade collisions. Token IDs auto-increment from 1.
///         Each address may hold at most one token.
interface IIdentityRegistry is IERC721, IERC721Metadata {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Key-value pair passed during registration to attach initial metadata.
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new agent identity NFT is minted.
    /// @param agentId  The token ID assigned to the new agent.
    /// @param agentURI The URI set at registration (empty string if not provided).
    /// @param owner    The address that registered and owns the NFT.
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    /// @notice Emitted when a metadata key-value pair is written for an agent.
    /// @param agentId             The agent whose metadata was updated.
    /// @param indexedMetadataKey  The metadata key (indexed for log filtering).
    /// @param metadataKey         The metadata key (unindexed copy for ABI decoding).
    /// @param metadataValue       The new value bytes.
    event MetadataSet(
        uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue
    );

    /// @notice Emitted when the token URI for an agent is updated.
    /// @param agentId   The agent whose URI changed.
    /// @param newURI    The new URI value.
    /// @param updatedBy The address that performed the update.
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    // =========================================================================
    // Registration
    // =========================================================================

    /// @notice Registers the caller as a new agent and mints their identity NFT.
    ///         No URI or metadata attached.
    /// @dev    Mints to msg.sender. Emits Registered.
    /// @return agentId The token ID assigned to the new agent.
    function register() external returns (uint256 agentId);

    /// @notice Registers the caller with an off-chain metadata URI.
    /// @dev    Emits Registered.
    /// @param agentURI URI pointing to the agent metadata JSON (IPFS CID or HTTPS).
    /// @return agentId The token ID assigned to the new agent.
    function register(string calldata agentURI) external returns (uint256 agentId);

    /// @notice Registers the caller with a URI and initial metadata entries.
    /// @dev    Emits Registered and one MetadataSet per entry.
    ///         Reverts if any entry uses the reserved "agentWallet" key.
    /// @param agentURI The URI pointing to the agent metadata JSON.
    /// @param metadata Array of key-value pairs to attach at registration.
    /// @return agentId The token ID assigned to the new agent.
    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId);

    // =========================================================================
    // Metadata management
    // =========================================================================

    /// @notice Returns the metadata bytes stored under the given key for an agent.
    /// @param agentId     The agent token ID to query.
    /// @param metadataKey The key to look up.
    /// @return            Stored bytes; empty if the key has never been set.
    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory);

    /// @notice Stores a metadata value for the given agent.
    ///         Callable by the token owner or an approved operator.
    ///         The "agentWallet" key is reserved and cannot be set via this function.
    /// @dev    Emits MetadataSet.
    /// @param agentId       The agent token ID to update.
    /// @param metadataKey   The key to set. Must not be "agentWallet".
    /// @param metadataValue The bytes value to store.
    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external;

    /// @notice Updates the token URI for the agent.
    ///         Callable by the token owner or an approved operator.
    /// @dev    Emits URIUpdated.
    /// @param agentId The agent token ID to update.
    /// @param newURI  The new URI value.
    function setAgentURI(uint256 agentId, string calldata newURI) external;

    // =========================================================================
    // Agent wallet management
    // =========================================================================

    /// @notice Returns the EIP-712-verified payment wallet bound to an agent.
    ///         Returns address(0) if no wallet is currently set.
    /// @param agentId The agent token ID to query.
    function getAgentWallet(uint256 agentId) external view returns (address);

    /// @notice Binds a payment wallet to the agent, authenticated by an EIP-712 signature
    ///         from the target wallet. Supports EOA (ECDSA) and smart-contract wallets (ERC-1271).
    /// @dev    The deadline must be within 5 minutes of block.timestamp.
    ///         Writes the "agentWallet" metadata key internally. Emits MetadataSet.
    ///         Typed-data domain: AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)
    /// @param agentId   The agent token ID.
    /// @param newWallet The wallet address to bind.
    /// @param deadline  Unix timestamp after which the signature is invalid.
    /// @param signature EIP-712 signature over AgentWalletSet typed data, signed by newWallet.
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;

    /// @notice Removes the payment wallet binding for the agent.
    ///         Callable by the token owner or an approved operator.
    /// @dev    Clears the "agentWallet" metadata key. Emits MetadataSet.
    /// @param agentId The agent token ID.
    function unsetAgentWallet(uint256 agentId) external;

    // =========================================================================
    // Authorization — read
    // =========================================================================

    /// @notice Returns true if the spender is the owner of or approved for the agent NFT.
    /// @dev    Reverts with ERC721NonexistentToken if the token does not exist.
    /// @param spender The address to check.
    /// @param agentId The agent token ID.
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);

    // =========================================================================
    // Versioning
    // =========================================================================

    /// @notice Returns the semantic version string of this implementation.
    function getVersion() external pure returns (string memory);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when an address that already holds an agent NFT attempts to register again.
    error AlreadyRegistered(address account);

    /// @notice Thrown when a write is attempted by an address that is not the owner or approved operator.
    error NotAuthorised(uint256 agentId, address caller);

    /// @notice Thrown when setMetadata is called with the reserved "agentWallet" key.
    error ReservedMetadataKey(string key);

    /// @notice Thrown when the deadline in setAgentWallet has passed or exceeds the 5-minute window.
    error DeadlineExpired(uint256 deadline, uint256 blockTimestamp);

    /// @notice Thrown when the EIP-712 signature in setAgentWallet cannot be verified.
    error InvalidSignature();

    /// @notice Thrown when a query or operation targets an agentId that does not exist.
    error AgentNotFound(uint256 agentId);
}
