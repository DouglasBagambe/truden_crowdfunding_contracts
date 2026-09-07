# Crowdfunding Contracts – RWA Tokenization Platform

This repository contains the **smart contracts and development environment** for the Crowdfunding dApp—a blockchain platform empowering underrepresented entrepreneurs to raise funds globally via **escrow-managed contributions, NFT-backed investments, and DAO governance**.

Contracts are written in **Solidity**, built with **Hardhat 3 Beta**, and tested using the **Node.js test runner (`node:test`)** and **`viem`** for Ethereum interactions.

---

## 📌 Features

- **Escrow Contract** – Locks investor funds, releases only on verified milestones or DAO consensus.
- **Project Factory & Project Contracts** – Create and manage individual fundraising campaigns.
- **NFT Registry** – Issues **ERC-721 tokens** for each investment (tradable, transferable, dynamically valued).
- **DAO Governance** – Token-weighted or quadratic voting for treasury proposals, milestone releases, and disputes.
- **Treasury** – Holds platform fees and DAO-controlled funds for community projects.
- **Dispute Manager** – Handles conflicts with arbitration (off-chain evidence + on-chain enforcement).

---

## 🛠️ Tech Stack

- **Language:** Solidity ^0.8.x
- **Framework:** Hardhat 3 Beta
- **Testing:** Node.js `node:test` runner + Viem
- **Deployment:** Hardhat Ignition modules
- **Libraries:** OpenZeppelin (ERC-721, AccessControl, Timelock, SafeERC20), Hardhat Plugins
- **Storage:** IPFS for metadata, PostgreSQL/MongoDB for off-chain indexing

---

## 📂 Project Structure

```text
contracts/
    core/           # Main contracts (Escrow, Project, NFTRegistry, Governance, Treasury, DisputeManager)
    interfaces/     # Interfaces (IProject, IEscrow, INFTRegistry, IGovernance, ITreasury)
    libs/           # Shared libraries (math helpers, oracle adapters)
    utils/          # Access control, pausable modules
scripts/
deploy/           # Deployment scripts (Hardhat Ignition)
tests/
    unit/           # Unit tests for each contract
    integration/    # Full flow tests (invest → NFT → escrow → milestone → release)
docs/
ABIs/             # ABI outputs
specs/            # Contract design docs
hardhat.config.ts
package.json
README.md
```

---

## 🚀 Setup

1. **Install dependencies**

   ```bash
   npm ci
   ```

2. **Compile contracts**

   ```bash
   npm run compile
   ```

3. **Run tests**

   - All tests: `npm test`
   - Node.js + Viem integration tests: `npm run test:node`
   - Coverage: `npm run coverage`

4. **Run the non-deploying CI verification**

   ```bash
   npm run verify:ci
   ```

   This uses Node 22 and a frozen install, then runs compile, strict TypeScript,
   tests, coverage, invariant/property scenarios, and deployed-bytecode size
   checks. It does not require keys, contact a chain, or deploy contracts.

5. **Deploy contracts**
   - Local: `npx hardhat ignition deploy ignition/modules/Crowdfunding.ts`
   - Sepolia testnet:
     - Fund your account with Sepolia ETH
     - Set your private key: `npx hardhat keystore set SEPOLIA_PRIVATE_KEY`
     - Deploy: `npx hardhat ignition deploy --network sepolia ignition/modules/Crowdfunding.ts`

   Deployment is a separate, explicitly approved operation. A production
   container must be immutable, non-root, health-checked, gracefully stopped,
   observably logged, and resource-limited. Chain IDs, RPC URLs, verified
   addresses, multisig or managed-signer policy, and explorer evidence must be
   supplied by deployment configuration; never bake keys or provider values
   into the image.

---

## 🧪 Testing Philosophy

- **Unit tests:** Validate each contract in isolation (Escrow, NFT, Governance).
- **Integration tests:** Full workflow (create project → invest → NFT minted → escrow locked → milestone release).
- **Edge cases:** Reentrancy, double spend, dispute resolution, oracle update failures.

---

## 🔒 Security & Best Practices

- OpenZeppelin standards
- Reentrancy guards on fund release/refund
- Role-based access control (ADMIN, ORACLE, ARBITRATOR)
- Multi-sig & timelock enforced treasury payouts
- Static analysis with Slither/MythX before deploy
- External audit before mainnet

---

## 📊 Roadmap

- ✅ ProjectFactory, Escrow, NFTRegistry base implementation
- 🔄 Governance & Treasury integration
- 🔄 Oracle adapter for dynamic NFT valuations
- 🔄 Integration with KYC/AML provider
- 🔄 Security audit & bug bounty program
- 🚀 Mainnet + L2 deployment

---
