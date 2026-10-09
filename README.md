# XTO Protocol

Official smart contracts, ABIs, deployment references, and developer integration documentation for XTO Protocol on Robinhood Chain.

## Network

- Network: Robinhood Chain Mainnet
- Chain ID: `4663`
- Protocol: XTO
- DEX Integration: Uniswap V4

## Mainnet Contracts

| Contract | Address |
|---|---|
| XTOFactoryV4 | `0x8fA9EDF9316F6DF55fd74F3529899C7De80D51fC` |
| XTOSwapRouter | `0xF9eDd945BC45B39CADe6Dfd704653dfe369BCB74` |
| XTOFeeHook | `0x26B9A961FFF3AECf951eFb6FB4aD21cA50BE60Cc` |
| XTOFeeAccounting | `0x6AC0115dF2485a00F34EB88625A5229720983711` |
| XTOGraduationExecutor | `0xf884d689a1978cA0Fc57F88f79B670C230f3ec54` |

## Repository Contents

- `src/` — XTO Solidity contract sources
- `abi/` — Contract ABIs for external integrations
- `deployments/` — Mainnet deployment addresses
- `docs/` — Developer integration documentation

## External Trading Bot Integration

XTO supports a factory-based token launch architecture in which each newly launched token has its own bonding curve market.

External trading bot developers can use the Factory contract to discover token launches and identify their associated markets.

For integration details, see:

[External Trading Bot Integration Guide](docs/external-bot-integration.md)

The integration guide covers token discovery, bonding curve trading, graduation detection, and Uniswap V4 integration.

## Important

Integration implementations must be validated against the deployed contract ABIs and on-chain behavior before production use.

## Official GitHub

https://github.com/XTO-Terminal/xto-protocol
