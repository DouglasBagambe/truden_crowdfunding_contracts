import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress } from "viem";

describe("DealRoom", async function () {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  const [admin, innovator, investorA, investorB] =
    await viem.getWalletClients();

  // Deploy contract (constructor grants DEFAULT_ADMIN_ROLE to deployer)
  const dealRoom = await viem.deployContract("DealRoom");

  it("creates a deal room and stores fields", async function () {
    const nextId: bigint = await dealRoom.read.dealRoomCounter();

    const projectId = 42n;
    const title = "Private DD";
    const description = "Due diligence room for Project 42";
    const expiryDate =
      BigInt(Math.floor(Date.now() / 1000)) + 60n * 60n * 24n * 30n; // ~30 days
    const kycRequired = false;
    const minIntent = 10_000n; // arbitrary units

    const tx = await dealRoom.write.createDealRoom(
      [projectId, title, description, expiryDate, kycRequired, minIntent],
      { account: innovator.account }
    );

    await viem.assertions.emitWithArgs(tx, dealRoom, "DealRoomCreated", [
      nextId,
      projectId,
      getAddress(innovator.account.address),
      title,
    ]);

    const info = await dealRoom.read.getDealRoom([nextId]);
    // tuple: projectId, innovator, title, description, creationDate, expiryDate, status, kycRequired, minInvestmentIntent
    assert.equal(info[0], projectId);
    assert.equal(getAddress(info[1]), getAddress(innovator.account.address));
    assert.equal(info[2], title);
    assert.equal(info[3], description);
    assert.equal(info[5], expiryDate);
    assert.equal(Number(info[6]), 0); // DealRoomStatus.Active
    assert.equal(info[7], kycRequired);
    assert.equal(info[8], minIntent);
  });

  it("investor can request access when KYC not required", async function () {
    const id: bigint = await dealRoom.read.dealRoomCounter();
    const expiry = BigInt(Math.floor(Date.now() / 1000)) + 7n * 24n * 60n * 60n;
    await dealRoom.write.createDealRoom(
      [1n, "Room A", "Desc", expiry, false, 100n],
      { account: innovator.account }
    );

    const req = await dealRoom.write.requestAccess([id, 200n, "Interested"], {
      account: investorA.account,
    });
    await viem.assertions.emitWithArgs(req, dealRoom, "AccessRequested", [
      id,
      getAddress(investorA.account.address),
      200n,
    ]);

    // hasAccess should be false until granted
    const hasAccess = await dealRoom.read.hasAccess([
      id,
      investorA.account.address,
    ]);
    assert.equal(hasAccess, false);
  });

  it("enforces min intent and KYC if required", async function () {
    const id: bigint = await dealRoom.read.dealRoomCounter();
    const expiry =
      BigInt(Math.floor(Date.now() / 1000)) + 30n * 24n * 60n * 60n;
    await dealRoom.write.createDealRoom(
      [2n, "KYC Room", "Desc", expiry, true, 1_000n],
      { account: innovator.account }
    );

    // Too low intent
    await assert.rejects(
      () =>
        dealRoom.write.requestAccess([id, 999n, "too low"], {
          account: investorA.account,
        }),
      /Investment intent too low/
    );

    // Missing KYC
    await assert.rejects(
      () =>
        dealRoom.write.requestAccess([id, 1_000n, "ok"], {
          account: investorA.account,
        }),
      /KYC verification required/
    );

    // Admin updates KYC
    const future = BigInt(Math.floor(Date.now() / 1000)) + 60n * 60n * 24n;
    // KYCStatus.Verified = 1
    await dealRoom.write.updateKYCStatus(
      [investorA.account.address, 1, future],
      {
        account: admin.account,
      }
    );

    // Now request succeeds
    const ok = await dealRoom.write.requestAccess([id, 1_000n, "ok"], {
      account: investorA.account,
    });
    await viem.assertions.emit(ok, dealRoom, "AccessRequested");
  });

  it("innovator grants and revokes access", async function () {
    const id: bigint = await dealRoom.read.dealRoomCounter();
    const expiry =
      BigInt(Math.floor(Date.now() / 1000)) + 30n * 24n * 60n * 60n;
    await dealRoom.write.createDealRoom(
      [3n, "Grant Room", "Desc", expiry, false, 10n],
      { account: innovator.account }
    );

    await dealRoom.write.requestAccess([id, 10n, "pls"], {
      account: investorB.account,
    });

    const grantTx = await dealRoom.write.grantAccess(
      [id, investorB.account.address],
      {
        account: innovator.account,
      }
    );
    await viem.assertions.emitWithArgs(grantTx, dealRoom, "AccessGranted", [
      id,
      getAddress(investorB.account.address),
      getAddress(innovator.account.address),
    ]);

    assert.equal(
      await dealRoom.read.hasAccess([id, investorB.account.address]),
      true
    );

    const revokeTx = await dealRoom.write.revokeAccess(
      [id, investorB.account.address, "breach"],
      {
        account: innovator.account,
      }
    );
    await viem.assertions.emitWithArgs(revokeTx, dealRoom, "AccessRevoked", [
      id,
      getAddress(investorB.account.address),
      "breach",
    ]);

    assert.equal(
      await dealRoom.read.hasAccess([id, investorB.account.address]),
      false
    );
  });

  it("document management and viewing with audit trail", async function () {
    const id: bigint = await dealRoom.read.dealRoomCounter();
    const expiry =
      BigInt(Math.floor(Date.now() / 1000)) + 30n * 24n * 60n * 60n;
    await dealRoom.write.createDealRoom(
      [4n, "Docs", "Desc", expiry, false, 1n],
      { account: innovator.account }
    );

    // Only innovator can add
    await assert.rejects(
      () =>
        dealRoom.write.addDocument([id, "QmHash1"], {
          account: investorA.account,
        }),
      /Only innovator can add documents/
    );

    const add = await dealRoom.write.addDocument([id, "QmHash1"], {
      account: innovator.account,
    });
    await viem.assertions.emitWithArgs(add, dealRoom, "DocumentAdded", [
      id,
      "QmHash1",
      getAddress(innovator.account.address),
    ]);

    // Unauthorized cannot read documents
    await assert.rejects(
      () =>
        dealRoom.read.getDealRoomDocuments([id], {
          account: investorA.account,
        }),
      /Access denied/
    );

    // Request + grant access
    await dealRoom.write.requestAccess([id, 1n, "pls"], {
      account: investorA.account,
    });
    await dealRoom.write.grantAccess([id, investorA.account.address], {
      account: innovator.account,
    });

    // Now investor can view list
    const docs = await dealRoom.read.getDealRoomDocuments([id], {
      account: investorA.account,
    });
    assert.equal(Array.isArray(docs), true);
    assert.equal(docs.length, 1);

    // Viewing creates audit trail
    const viewTx = await dealRoom.write.viewDocument([id, "QmHash1"], {
      account: investorA.account,
    });
    await viem.assertions.emitWithArgs(viewTx, dealRoom, "DocumentViewed", [
      id,
      getAddress(investorA.account.address),
      "QmHash1",
    ]);

    // Investor can query their own access info
    const access = await dealRoom.read.getInvestorAccess(
      [id, investorA.account.address],
      {
        account: investorA.account,
      }
    );
    // tuple: hasAccess, grantedDate, intent, documentsViewed, lastAccessDate
    assert.equal(access[0], true);
    assert.equal(access[2], 1n);
    assert.equal(access[3], 1n);
  });

  it("close room and block further actions; admin pause/unpause and set duration", async function () {
    const id: bigint = await dealRoom.read.dealRoomCounter();
    const expiry =
      BigInt(Math.floor(Date.now() / 1000)) + 30n * 24n * 60n * 60n;
    await dealRoom.write.createDealRoom(
      [5n, "Lifecycle", "Desc", expiry, false, 1n],
      { account: innovator.account }
    );

    const closeTx = await dealRoom.write.closeDealRoom([id], {
      account: innovator.account,
    });
    await viem.assertions.emit(closeTx, dealRoom, "DealRoomClosed");

    // Now add/grant should revert due to not active
    await assert.rejects(
      () =>
        dealRoom.write.addDocument([id, "X"], { account: innovator.account }),
      /Deal room not active/
    );
    await assert.rejects(
      () =>
        dealRoom.write.grantAccess([id, investorB.account.address], {
          account: innovator.account,
        }),
      /Deal room not active/
    );

    // Admin can pause / unpause
    await dealRoom.write.pause([], { account: admin.account });
    await dealRoom.write.unpause([], { account: admin.account });

    // Admin can set default expiry duration
    await dealRoom.write.setDefaultExpiryDuration([1234n], {
      account: admin.account,
    });
  });
});
