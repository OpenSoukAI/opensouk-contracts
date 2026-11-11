// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";

/// @dev Minimal ERC-721 + IIdentityRegistry stub for testing.
///      Supports configurable agentWallet per tokenId.
///      mint() assigns a token to an address. setWallet() overrides the payment wallet.
contract MockAgentRegistry is ERC721, IIdentityRegistry {
    uint256 private _nextId = 1;
    mapping(uint256 => address) private _wallets;

    constructor() ERC721("MockAgent", "MAGENT") {}

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function mint(address to) external returns (uint256 id) {
        id = _nextId++;
        _mint(to, id);
    }

    function setWallet(uint256 agentId, address wallet) external {
        _wallets[agentId] = wallet;
    }

    // -------------------------------------------------------------------------
    // IIdentityRegistry
    // -------------------------------------------------------------------------

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _wallets[agentId];
    }

    function register() external returns (uint256 agentId) {}

    function register(string calldata) external returns (uint256 agentId) {}

    function register(string calldata, MetadataEntry[] calldata) external returns (uint256 agentId) {}

    function getMetadata(uint256, string calldata) external pure returns (bytes memory) {
        return "";
    }

    function setMetadata(uint256, string calldata, bytes calldata) external {}

    function setAgentURI(uint256, string calldata) external {}

    function setAgentWallet(uint256, address, uint256, bytes calldata) external {}

    function unsetAgentWallet(uint256) external {}

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        return ownerOf(agentId) == spender;
    }

    function getVersion() external pure returns (string memory) {
        return "mock-1";
    }
}
