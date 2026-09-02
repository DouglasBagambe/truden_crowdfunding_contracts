import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { keccak256, stringToHex, zeroHash } from "viem";

describe("KEIBO replacement modules", async () => {
  const { viem, networkHelpers } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [admin, investor, attacker] = await viem.getWalletClients();

  it("issues non-transferable receipts only with unexpired signed policy evidence", async () => {
    const receipt = await viem.deployContract("KeiboInvestmentReceipt", [
      "https://staging.invalid/receipts/{id}.json",
      admin.account.address,
      admin.account.address,
    ]);
    const chainId = await publicClient.getChainId();
    const expiresAt = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const policyHash = keccak256(stringToHex("eligibility-policy-v1"));
    const signature = await admin.signTypedData({
      account: admin.account,
      domain: {
        name: "KEIBO Investment Eligibility",
        version: "1",
        chainId,
        verifyingContract: receipt.address,
      },
      primaryType: "Eligibility",
      types: {
        Eligibility: [
          { name: "investor", type: "address" },
          { name: "campaignId", type: "uint256" },
          { name: "amount", type: "uint256" },
          { name: "expiresAt", type: "uint64" },
          { name: "policyHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      },
      message: {
        investor: investor.account.address,
        campaignId: 7n,
        amount: 1_000n,
        expiresAt,
        policyHash,
        nonce: 0n,
      },
    });
    await receipt.write.issue(
      [investor.account.address, 7n, 1_000n, expiresAt, policyHash, signature],
      { account: admin.account },
    );
    assert.equal(
      await receipt.read.balanceOf([investor.account.address, 7n]),
      1_000n,
    );
    await assert.rejects(
      () =>
        receipt.write.safeTransferFrom(
          [investor.account.address, attacker.account.address, 7n, 1n, "0x"],
          { account: investor.account },
        ),
      /non-transferable/,
    );
    await assert.rejects(
      () =>
        receipt.write.issue(
          [
            investor.account.address,
            7n,
            1_000n,
            expiresAt,
            policyHash,
            signature,
          ],
          { account: admin.account },
        ),
      /invalid eligibility evidence/,
    );
  });

  it("supports contract-wallet eligibility signatures and safe revocation", async () => {
    const signer = await viem.deployContract("Mock1271Signer", [
      admin.account.address,
    ]);
    const receipt = await viem.deployContract("KeiboInvestmentReceipt", [
      "https://staging.invalid/receipts/{id}.json",
      admin.account.address,
      signer.address,
    ]);
    const chainId = await publicClient.getChainId();
    const expiresAt = (await publicClient.getBlock()).timestamp + 3_600n;
    const policyHash = keccak256(stringToHex("contract-wallet-policy"));
    const signature = await admin.signTypedData({
      account: admin.account,
      domain: {
        name: "KEIBO Investment Eligibility",
        version: "1",
        chainId,
        verifyingContract: receipt.address,
      },
      primaryType: "Eligibility",
      types: {
        Eligibility: [
          { name: "investor", type: "address" },
          { name: "campaignId", type: "uint256" },
          { name: "amount", type: "uint256" },
          { name: "expiresAt", type: "uint64" },
          { name: "policyHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      },
      message: {
        investor: investor.account.address,
        campaignId: 9n,
        amount: 501n,
        expiresAt,
        policyHash,
        nonce: 0n,
      },
    });
    await receipt.write.issue(
      [investor.account.address, 9n, 501n, expiresAt, policyHash, signature],
      { account: admin.account },
    );
    await assert.rejects(
      () =>
        receipt.write.revoke(
          [investor.account.address, 9n, 1n, zeroHash],
          { account: admin.account },
        ),
      /reason required/,
    );
    await receipt.write.revoke(
      [
        investor.account.address,
        9n,
        501n,
        keccak256(stringToHex("policy reversal")),
      ],
      { account: admin.account },
    );
    assert.equal(await receipt.read.balanceOf([investor.account.address, 9n]), 0n);
  });

  it("bounds governance actions behind delay and permits challenge cancellation", async () => {
    const escrow = await viem.deployContract("KeiboCampaignEscrow", [
      admin.account.address,
      admin.account.address,
      86_400n,
    ]);
    const governance = await viem.deployContract("KeiboGovernance", [
      admin.account.address,
      escrow.address,
      86_400n,
      3_600n,
    ]);
    await escrow.write.grantRole(
      [await escrow.read.GUARDIAN_ROLE(), governance.address],
      { account: admin.account },
    );
    await governance.write.propose([0, zeroHash, attacker.account.address], {
      account: admin.account,
    });
    await assert.rejects(() => governance.write.execute([0n]));
    await governance.write.cancel([0n, keccak256(stringToHex("challenge"))], {
      account: admin.account,
    });
    await assert.rejects(() => governance.write.execute([0n]));
  });

  it("executes only the bounded escrow action after the full delay", async () => {
    const escrow = await viem.deployContract("KeiboCampaignEscrow", [
      admin.account.address,
      admin.account.address,
      86_400n,
    ]);
    const governance = await viem.deployContract("KeiboGovernance", [
      admin.account.address,
      escrow.address,
      86_400n,
      3_600n,
    ]);
    await escrow.write.grantRole(
      [await escrow.read.GUARDIAN_ROLE(), governance.address],
      { account: admin.account },
    );
    await governance.write.propose([0, zeroHash, attacker.account.address], {
      account: admin.account,
    });
    await networkHelpers.time.increase(86_400);
    await governance.write.execute([0n], { account: attacker.account });
    assert.equal(await escrow.read.paused(), true);
    await assert.rejects(
      () => governance.write.execute([0n], { account: attacker.account }),
    );
  });

  it("records hashes without granting off-chain document access", async () => {
    const evidence = await viem.deployContract("KeiboDealRoomEvidence", [
      admin.account.address,
    ]);
    const documentHash = keccak256(stringToHex("document"));
    const policyHash = keccak256(stringToHex("policy"));
    await assert.rejects(
      () =>
        evidence.write.recordDocument([1n, documentHash, policyHash], {
          account: attacker.account,
        }),
      /AccessControlUnauthorizedAccount/,
    );
    await evidence.write.recordDocument([1n, documentHash, policyHash], {
      account: admin.account,
    });
    await assert.rejects(
      () =>
        evidence.write.recordDocument([1n, documentHash, policyHash], {
          account: admin.account,
        }),
      /document already recorded/,
    );
  });
});
