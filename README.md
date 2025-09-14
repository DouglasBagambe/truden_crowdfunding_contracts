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
   npm install
   ```

2. **Compile contracts**

   ```bash
   npx hardhat compile
   ```

3. **Run tests**

   - All tests: `npx hardhat test`
   - Solidity unit tests: `npx hardhat test solidity`
   - Node.js + Viem integration tests: `npx hardhat test nodejs`

4. **Deploy contracts**
   - Local: `npx hardhat ignition deploy ignition/modules/Crowdfunding.ts`
   - Sepolia testnet:
     - Fund your account with Sepolia ETH
     - Set your private key: `npx hardhat keystore set SEPOLIA_PRIVATE_KEY`
     - Deploy: `npx hardhat ignition deploy --network sepolia ignition/modules/Crowdfunding.ts`

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
