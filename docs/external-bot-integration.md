# XTO External Trading Bot Integration Specification

**Status:** DRAFT v0.1 — for engineering review; not a final executable API reference  
**Project:** XTO REBUILD V3  
**Network:** Robinhood Chain Mainnet  
**Chain ID:** `4663`  
**Audience:** External trading bot teams (Sigma, BaseBot, Maestro and others), wallet integrators, indexers and market-data providers.

> **Integration principle:** The Factory is the stable entry point for discovering new XTO launches. A creator launch generates its own token and market/curve address. Integrators must discover the actual per-launch trading contract, rather than assuming a single universal bonding-curve address. Exact event signatures and trading method signatures must be taken from verified production ABIs.

## 1. Objectives and integration scope

Enable third-party bots to:

1. Discover XTO-launched tokens and their market/curve addresses automatically.
2. Track the lifecycle of each market from launch to graduation.
3. Read executable buy/sell quotations and safely submit transactions before graduation.
4. Identify graduation and stop sending trades to a retired curve.
5. Route post-graduation swaps through the applicable Uniswap V4 integration.
6. Monitor receipts, failures, taxes, slippage, and market state without privileged access.

**Out of scope:** custody services, private keys, guaranteed execution, guaranteed liquidity, third-party bot support commitments, and any grant of admin/operator privileges.

## 2. Official deployment registry

| Component | Mainnet address | Role |
|---|---|---|
| XTOFactoryV4 | `0x8fA9EDF9316F6DF55fd74F3529899C7De80D51fC` | Stable discovery entry point / market creation |
| XTOSwapRouter | `0xF9eDd945BC45B39CADe6Dfd704653dfe369BCB74` | XTO swap integration component; verify supported paths in ABI |
| XTOFeeHook | `0x26B9A961FFF3AECf951eFb6FB4aD21cA50BE60Cc` | Fee hook for the V4 integration |
| XTOFeeAccounting | `0x6AC0115dF2485a00F34EB88625A5229720983711` | Fee accounting |
| XTOGraduationExecutor | `0xf884d689a1978cA0Fc57F88f79B670C230f3ec54` | Graduation settlement |
| UniswapV4PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Uniswap V4 pool manager |

**Administrative/payment addresses (informational only, not trading targets):**

- Deployer: `0x90e0b54f6fc596755C3d90604c3Cb5dc60fe02e8`
- Protocol: `0xc7cae08ed2ca199c7ffc3664544f979270C399A2`

**Per-launch addresses:** Each creator launch has its own token address and market/curve address. These are **not** static registry entries. They must be derived from verified factory events or read methods. A dedicated globally deployed `XTOBondingCurve` address has **not** been established from the deployment registry.

**RPC:** Use a trusted Robinhood Chain mainnet RPC provider. Do not hardcode an unverified endpoint in official integration docs.

## 3. Required integration artifacts

The XTO team should publish a versioned, checksummed bundle:

- `deployments/robinhood-mainnet.json`: chain ID and production contract addresses.
- `abi/XTOFactoryV4.json`: verified ABI including creation events and lookup methods.
- `abi/<actual-market-implementation>.json`: ABI of the per-launch trading contract, confirmed from production source; use the real contract name rather than assuming an older XTOBondingCurve ABI applies.
- `abi/XTOSwapRouter.json`: verified router ABI.
- `abi/XTOFeeHook.json`, `abi/XTOGraduationExecutor.json`: only as needed for lifecycle detection and integration.
- `examples/discovery.*`: launch event indexing and token-to-market resolution.
- `examples/pre-graduation-buy.*` and `examples/pre-graduation-sell.*`: fully parameterized examples.
- `examples/post-graduation-swap.*`: verified Uniswap V4 routing example.
- `tests/integration-vectors.json`: actual deployed token/curve addresses, transaction hashes, decoded events and expected quote/trade results.
- A changelog, version number, verified contract-source links, and security notices.

**Verification gate:** Function names such as `curveOf(address)`, event names such as `MarketCreated`, and example `buy`/`sell` signatures mentioned in earlier discussions are **candidate interface details**, not certified ABI facts for this document. Confirm their exact names, argument types, return types, indexed fields and revert behavior against the deployed FactoryV4 and market contracts before publication.

## 4. Market discovery and indexing

### 4.1 Initial sync

1. Connect to Robinhood Chain mainnet (`eth_chainId` must equal `0x1237`, decimal 4663).
2. Load the production FactoryV4 ABI.
3. Identify the exact launch/market-created event from that ABI.
4. Scan FactoryV4 logs from the **verified deployment block**, in bounded ranges.
5. Decode token address, market/curve address, creator and any available metadata according to the actual event.
6. If the event does not expose a required address, use the verified FactoryV4 getter or additional creation receipt logs.
7. Persist normalized market records keyed by `(chainId, tokenAddress)` and `(chainId, marketAddress)`.
8. Cross-check that each market was created by the official factory and is the expected contract implementation.

### 4.2 Live sync

Subscribe to factory launch logs over WebSocket, with HTTP polling and historical backfill as recovery. Track block numbers, log indices and transaction hashes; deduplicate events. Handle chain reorganizations by using a configurable confirmation depth, and never rely exclusively on a transient WebSocket connection.

### 4.3 Suggested market record

```json
{
  "chainId": 4663,
  "factory": "0x8fA9EDF9316F6DF55fd74F3529899C7De80D51fC",
  "token": "<token-address-from-verified-event>",
  "market": "<market-address-from-verified-event-or-getter>",
  "creator": "<creator-address-if-exposed>",
  "launchTxHash": "<transaction-hash>",
  "launchBlock": 0,
  "phase": "CURVE | GRADUATING | V4_ACTIVE | UNKNOWN",
  "poolId": "<v4-pool-identifier-if-applicable>",
  "lastSyncedBlock": 0
}
```

This is an **illustrative indexer schema**, not a guaranteed FactoryV4 return payload.

## 5. Trading lifecycle and routing rules

| Market phase | Discovery | Trading route | Safety behavior |
|---|---|---|---|
| Newly launched / curve active | Factory event + market state | Verified per-market curve interface | Quote and simulate before sending |
| Graduation pending / in progress | Verified on-chain state and lifecycle events | Potentially restricted | Pause or re-check; do not assume curve remains tradable |
| Graduation complete / V4 active | Verified graduation state + V4 pool key/ID | Verified supported V4 swap route | Refresh pool data, approvals, quotes and gas |
| Unknown/inconsistent state | Conflicting/missing on-chain data | None | Fail closed; do not send transaction |

The source of truth is **on-chain state**, not only a frontend label, off-chain market cap, price feed, or unconfirmed event.

## 6. Pre-graduation BUY integration

The external bot must:

1. Resolve the official market address for the token.
2. Confirm that the market is active and not graduated.
3. Read the exact production quote function, its input units, and output semantics.
4. Calculate total native-asset input, applicable fees, expected token output, and slippage protection.
5. Determine the actual `to`, `value`, function selector, argument encoding and any recipient/deadline fields **from the deployed market ABI**.
6. Simulate the transaction using `eth_call` or equivalent and estimate gas.
7. Obtain explicit user authorization and submit the signed transaction.
8. Wait for receipt; decode actual token transfers/trade events and show executed amounts, fees and effective price.

**Do not assume** a function named `buy(uint256)` or a particular meaning of its parameter until verified. Confirm whether slippage limits are contract-enforced and whether a quote is net of fees. If the contract lacks enforceable min-output protection, disclose this limitation and implement conservative controls; off-chain quotes alone cannot guarantee execution price.

## 7. Pre-graduation SELL integration

1. Confirm the user owns sufficient token balance.
2. Check token allowance to the **actual spender** specified by the market architecture.
3. If approval is needed, request a limited allowance; do not require unlimited approval by default.
4. Quote the sell amount and native-asset proceeds, including sell fees.
5. Check market reserve/liquidity and graduation status.
6. Encode the verified sell call and min-proceeds parameter, if supported.
7. Simulate, estimate gas, obtain authorization and submit.
8. Decode the receipt and reconcile token input, actual native-asset output and fees.

A bot must not guess spender addresses or reuse approvals for unrelated markets.

## 8. Graduation detection and transition

The integrator must discover from production ABI/source:

- The exact state getters that indicate graduation pending, executing and complete.
- The actual events emitted during successful graduation.
- Whether the market rejects trades once graduation starts.
- The V4 pool identity: currencies, fee, tick spacing, hook, and any pool ID / PoolKey data required by the router.
- How to verify that pool liquidity is initialized and executable.

**Transition algorithm:** Re-check market state before every trade; when graduation begins, stop curve trading and await confirmed settlement. After graduation completes, resolve the verified V4 pool and router parameters, obtain a fresh quote and resume via the supported V4 route. Handle failed or reverted graduation without assuming that the pool exists.

## 9. Post-graduation Uniswap V4 integration

Do **not** treat the presence of `XTOSwapRouter` alone as proof of a standard swap interface. Integrators need:

1. The verified XTOSwapRouter ABI and supported swap entry points.
2. Exact V4 PoolKey/PoolId derivation and token ordering.
3. Currency handling, including native ETH where relevant.
4. Fee tier, tick spacing and hook address as used for the specific pool.
5. Token allowance and any Permit2 or intermediate spender requirements if applicable.
6. Quote and slippage mechanics, deadlines, recipient encoding and transaction `value` requirements.
7. Fee-hook behavior and actual net received amounts.
8. A confirmed end-to-end mainnet example using a graduated XTO market.

The FeeHook, FeeAccounting and GraduationExecutor are **not** general-purpose user swap endpoints unless their verified interfaces explicitly say otherwise.

## 10. Fees, tokenomics and display

The integration must derive current, enforceable fees from production contract state and verified specifications. The XTO economic policy discussed for the project includes a base **1% BUY / 1% SELL** fee, creator/protocol sharing of that base fee, and a configurable creator additional fee capped at **10%**. These values are **policy inputs requiring production-contract confirmation** before being represented as guaranteed behavior to third parties.

Bots should display gross input, estimated fee breakdown, minimum expected output, network gas and final net received amount. Distinguish curve fees from Uniswap V4 pool swap fees and hook fees. Do not double-count fees or assume the same method of collection across lifecycle phases without verifying contract behavior.

## 11. Bot security requirements

- **Never request or share** XTO deployer/operator private keys, seed phrases, graduation keeper credentials or admin rights.
- All user trades must be signed by the user's wallet or the bot's independently authorized custody mechanism.
- Validate chain ID, factory origin, target contract code and token/market pairing before signing.
- Restrict approvals to the verified spender and use conservative limits.
- Simulate every trade and re-validate state immediately before submission.
- Enforce user-defined slippage, transaction size and gas limits wherever supported.
- Detect honeypot-like execution failures, insufficient reserve, paused markets and unexpected fee behavior.
- Avoid relying on unverified logos, token names, social links or metadata for contract identity.
- Handle RPC failure, nonce replacement, dropped transactions, reverted receipts and reorgs.
- Never interpret an emitted event as a successful trade without a successful transaction receipt.

## 12. Suggested external API / indexer (optional)

The XTO team may later provide convenience endpoints, **not yet claimed to exist**:

```text
GET /v1/markets?chainId=4663&status=active
GET /v1/markets/{tokenAddress}
GET /v1/markets/{tokenAddress}/quote?side=buy&amount=...
GET /v1/markets/{tokenAddress}/graduation
GET /v1/deployments/4663
```

Such endpoints are optional indexing/quoting aids, not a substitute for validating on-chain addresses, state and transaction results. Do not advertise them as live until implemented and tested.

## 13. Required integration tests before public launch

- Discover a newly launched token and its distinct market address.
- Discover multiple launches from the same Factory with no manual address registration.
- Buy a curve token and reconcile actual receipt amounts.
- Sell a curve token with verified allowance and net proceeds.
- Reject a trade when slippage, reserve, approval or phase checks fail.
- Handle concurrent launch events, duplicate logs, RPC outages and reorgs.
- Detect graduation pending, completed and reverted states correctly.
- Stop using the curve after confirmed graduation.
- Resolve the correct V4 pool and execute a post-graduation buy and sell.
- Confirm creator fees, protocol fees, hook fees and swap fees against real on-chain behavior.
- Confirm the bot never needs operator/admin credentials.

Test on a controlled deployment and then with carefully limited mainnet transactions. Provide transaction hashes and receipts as evidence.

## 14. Information XTO must verify before sending to bot partners

**BLOCKING — verify from deployed source and ABIs:**

- [ ] Exact FactoryV4 launch event signature and indexed parameters.
- [ ] Exact FactoryV4 token → market getter (if available).
- [ ] Factory deployment block for historical indexing.
- [ ] Exact per-launch market implementation name, bytecode and ABI.
- [ ] Exact buy/sell/quote function signatures and payable value semantics.
- [ ] Exact market status/graduation getters and lifecycle events.
- [ ] Actual post-graduation V4 pool identity and router calldata.
- [ ] Approvals, fee calculation, slippage enforcement and deadline behavior.
- [ ] Working end-to-end test transactions for pre- and post-graduation routes.
- [ ] Verified contract source links and versioned ABI hashes.
- [ ] External bot's support for Robinhood Chain 4663 and custom curve/V4 routing.

Until these checks are complete, this document is a **partner engineering overview**, not a copy-paste implementation manual.

## 15. Suggested message to external bot teams

**Subject: XTO FactoryV4 Integration — Robinhood Chain Mainnet (4663)**

Hello team,

We would like to discuss integration of XTO-launched tokens with your trading bot on Robinhood Chain Mainnet (chain ID 4663).

XTOFactoryV4 is deployed at `0x8fA9EDF9316F6DF55fd74F3529899C7De80D51fC`. Each creator launch produces a token and its own market/curve address. We are preparing verified factory discovery interfaces, per-market trading ABIs, and post-graduation Uniswap V4 routing documentation.

The intended integration supports automatic token discovery, pre-graduation curve BUY/SELL, and post-graduation V4 swaps. No privileged contract permissions or XTO operator keys are required for ordinary user trades.

Could you confirm whether your platform supports Robinhood Chain 4663, custom per-market bonding-curve integrations, and Uniswap V4 routing? We can share the versioned technical integration package for engineering review.

Regards,  
XTO Team

---

**Document ownership:** XTO  
**Draft version:** 0.1  
**Publication status:** Public technical reference (integration validation required)  
**Next step:** Verify all ABI-dependent details against the deployed XTO REBUILD V3 source and produce a tested developer SDK/reference implementation.
