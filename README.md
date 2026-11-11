# OpenSouk Contracts

Smart contracts for the OpenSouk protocol: merchant, product and review registries, the
x402 / MPP payment split router, and the commission escrow. Written in Solidity 0.8.37 and
built with [Foundry](https://book.getfoundry.sh/).

## Deployments

### Base mainnet (chain id 8453)

Deployed at block [53504323](https://basescan.org/block/53504323).

| Contract                | Address                                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| ProtocolAddressRegistry | [`0x6e3DCD1e6E40Ee8d3014F882c79e73D6c4F50487`](https://basescan.org/address/0x6e3DCD1e6E40Ee8d3014F882c79e73D6c4F50487) |
| MerchantRegistry        | [`0x5bCB26A402aC5430381266F8516872D1610A413e`](https://basescan.org/address/0x5bCB26A402aC5430381266F8516872D1610A413e) |
| ProductRegistry         | [`0x541B7BB6D7B9C067CD70462A736f21079aBb48cE`](https://basescan.org/address/0x541B7BB6D7B9C067CD70462A736f21079aBb48cE) |
| ReviewRegistry          | [`0x46B03Ecbe6711A1CbF200d700731dD5296Ba152b`](https://basescan.org/address/0x46B03Ecbe6711A1CbF200d700731dD5296Ba152b) |
| CommissionEscrow        | [`0x672f9e44b7AB65bdE0285Cc7a4F1d22559bfE0Cb`](https://basescan.org/address/0x672f9e44b7AB65bdE0285Cc7a4F1d22559bfE0Cb) |
| SplitRouter             | [`0x6EE905BF1086918EB735205fDB06d4ae293eFefb`](https://basescan.org/address/0x6EE905BF1086918EB735205fDB06d4ae293eFefb) |

`ProtocolAddressRegistry` is the source of truth for the other addresses: read them with
`getAddress(keccak256("MERCHANT_REGISTRY"))` and so on. Agent identities come from the
canonical ERC-8004 IdentityRegistry at
[`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`](https://basescan.org/address/0x8004A169FB4a3325136EB29fA0ceB6D2e539a432).
The protocol is administered by a Safe multisig at
[`0x807890a725f8E6ad6D44a7917AF53Ae7494E1c74`](https://basescan.org/address/0x807890a725f8E6ad6D44a7917AF53Ae7494E1c74).

## Audit

The contracts were audited by Sherlock. The final report (2026-10-06) is in [`audit/`](audit/).

## Usage

```sh
git clone --recursive https://github.com/OpenSoukAI/opensouk-contracts.git
cd opensouk-contracts
forge build
forge test
```

`test/fork/` runs against real USDC on a Base mainnet fork. Set `BASE_FORK_RPC_URL` to an
archive RPC, or set `SKIP_FORK_TESTS=true` to skip it.

## Layout

- `src/` contracts, interfaces and libraries
- `test/` unit, integration, fuzz, invariant and fork tests
- `script/Deploy.s.sol` deployment script
- `audit/` audit report

## License

[MIT](LICENSE)
