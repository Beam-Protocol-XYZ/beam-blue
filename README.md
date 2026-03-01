# Headen Finance

Headen Finance is an advanced decentralized finance protocol acting as a sophisticated layer on top of [Morpho Blue](https://morpho.org/). At its core, Headen Finance extends Morpho Blue's lending capabilities to provide **uncollateralized lending to authorized parties**. This powerful primitive unlocks a vast ecosystem of modular financial products built on top of it.

By leveraging Morpho Blue's trustless, efficient, and flexible base layer, Headen Finance provides permissionless risk management and high capital efficiency for a wide array of DeFi and TradFi use cases.

---

## The Headen Ecosystem (Features)

By offering uncollateralized borrowing power to authorized smart contracts and institutions, Headen Finance enables the following distinct features and modules:

### 1. Intent-Based Lending (`IntentLending.sol`)
A customized **Intent-Based Lending** protocol for institutional lenders and borrowers, featuring powerful on-chain permissionless matching.
- **Lenders and Borrowers** can explicitly define their exact credit requirements or limits (LTV, rate, duration, acceptable collaterals).
- Intents are matched on-chain, creating isolated, fully transparent debt positions that can be independently liquidated if they become unhealthy.

### 2. Leveraged Margin Engine (`MarginEngine.sol`)
The **Margin Engine** enables heavily leveraged margin trading utilizing the underlying uncollateralized lending primitive.
- Users can deposit collateral and heavily borrow an asset to open a leveraged position.
- Borrowed assets are seamlessly deployed into whitelisted yield-bearing strategies (e.g., Morpho Market Strategies).
- Highly granular configurations for max leverage and liquidation limits, backed by Morpho's exact health and liquidation formulas.

### 3. Cross-Chain Lending & Interoperability (`PositionManager.sol`, `LayerZeroAdapter.sol`)
Robust cross-chain infrastructure leveraging **LayerZero V2** to enable seamless cross-chain state management.
- Enables users to manage positions, supply collateral, and execute complex borrowing strategies across multiple EVM-compatible networks seamlessly.

### 4. Decentralized Exchange (DEX)
Headen Finance taps into its uncollateralized liquidity pools to help facilitate efficient on-chain spot trading and asset swapping with optimized routing and reduced capital overhead.

### 5. Redemption Facility for RWAs
A dedicated facility to handle Real World Assets (RWAs), bridging the gap between tokenized traditional assets and on-chain permissionless liquidity.

### 6. Cross-Platform Lending (`CrossPlatformLending.sol`, `CrossPlatformFactory.sol`)
A factory-deployed, per-partner smart contract system bridging DeFi and TradFi directly. Each onboarded entity (bank, loan provider) receives a dedicated smart contract that borrows uncollateralized from Morpho.

**Flow A — Off-Chain to On-Chain (Partner disburses crypto):**
- The partner collects real-world collateral documents from a user off-chain.
- The partner calls `disburseCryptoLoan` to borrow from Morpho and send crypto directly to the user.
- The partner later collects repayment off-chain and repays Morpho via `repayCryptoLoan`.

**Flow B — On-Chain to Off-Chain (User locks crypto for fiat loan):**
- The user calls `requestOffchainLoan` to escrow an approved token as on-chain collateral.
- The partner reviews and calls `acceptOffchainLoan`, setting the on-chain repayment amount and providing the fiat loan off-chain.
- **User can cancel** the request any time before the partner accepts, getting collateral back.
- **On-chain repayment:** The user calls `repayOffchainLoanOnchain` — funds are routed to the Morpho lending market and collateral is automatically released.
- **Off-chain repayment:** The partner calls `releaseCollateral` to return collateral after receiving payment off-chain.
- **Seizure:** The partner can call `initiateSeizure` at any time, starting a configurable grace period (24–48 hours). During this window, the user can repay on-chain to avoid seizure. After the delay, the partner can execute `seizeCollateral` to claim the collateral.

---

## Repository Structure

- [`src/intent/`](./src/intent): Core contracts for Intent-based lending logic and intent matching.
- [`src/margin/`](./src/margin): Core contracts for Leveraged Margin trading and automated Morpho strategies.
- [`src/crossplatform/`](./src/crossplatform): Cross-Platform Lending factory and per-partner contracts bridging DeFi/TradFi.
- [`src/crosschain/`](./src/crosschain): LayerZero V2 cross-chain routers, remote executors, and position managers.
- [`src/interfaces/`](./src/interfaces): Essential interfaces for Headen Finance modules.
- [`src/libraries/`](./src/libraries): Complex mathematical helper libraries (MathLib, SharesMathLib).
- [`test/`](./test): Foundry-based integration, invariant, and fuzz testing directory structure.

## Developers

Compilation, testing and formatting is handled natively via [Foundry / forge](https://book.getfoundry.sh/getting-started/installation).

```bash
# Install dependencies
forge install

# Compile contracts
forge build

# Run comprehensive fuzz and invariant test suites
forge test
```

## Licenses

Most fundamental Headen Finance explicit components are licensed under the Business Source License 1.1 (`BUSL-1.1`), with specific generic sub-directories optionally licensed under `GPL-2.0-or-later`. (Always check the explicit SPDX headers of individual files).
