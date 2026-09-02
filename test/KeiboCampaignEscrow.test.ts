import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { parseEther, zeroHash } from "viem";

describe("KeiboCampaignEscrow", async () => {
  const { viem, networkHelpers } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [admin, creator, investor, attacker] = await viem.getWalletClients();
  const token = await viem.deployContract("MockERC20", [
    "Test",
    "TST",
    parseEther("1000000"),
  ]);
  const escrow = await viem.deployContract("KeiboCampaignEscrow", [
    admin.account.address,
    admin.account.address,
    86_400n,
  ]);
  await token.write.mint([investor.account.address, parseEther("100")]);
  await token.write.approve([escrow.address, parseEther("100")], {
    account: investor.account,
  });
  const latestTime = async () => (await publicClient.getBlock()).timestamp;

  it("enforces cap and conserves the 5% success fee", async () => {
    const now = await latestTime();
    await escrow.write.createCampaign(
      [token.address, parseEther("10"), now + 86_400n, [parseEther("10")]],
      { account: creator.account },
    );
    const feeBalanceBefore = await token.read.balanceOf([
      admin.account.address,
    ]);
    await assert.rejects(
      () =>
        escrow.write.contribute([0n, parseEther("11")], {
          account: investor.account,
        }),
      /invalid contribution/,
    );
    await escrow.write.contribute([0n, parseEther("10")], {
      account: investor.account,
    });
    await escrow.write
      .approveMilestone([0n, 0n, zeroHash], { account: admin.account })
      .catch(() => undefined);
    const evidenceHash = `0x${"11".repeat(32)}` as `0x${string}`;
    await escrow.write.approveMilestone([0n, 0n, evidenceHash], {
      account: admin.account,
    });
    await escrow.write.releaseMilestone([0n, 0n], { account: creator.account });
    assert.equal(
      await token.read.balanceOf([creator.account.address]),
      parseEther("9.5"),
    );
    assert.equal(
      (await token.read.balanceOf([admin.account.address])) - feeBalanceBefore,
      parseEther("0.5"),
    );
  });

  it("uses pull refunds and prevents replay", async () => {
    const now = await latestTime();
    await escrow.write.createCampaign(
      [token.address, parseEther("10"), now + 86_400n, [parseEther("10")]],
      { account: creator.account },
    );
    await escrow.write.contribute([1n, parseEther("1")], {
      account: investor.account,
    });
    await escrow.write.cancelCampaign([1n], { account: admin.account });
    await escrow.write.refund([1n], { account: investor.account });
    await assert.rejects(
      () => escrow.write.refund([1n], { account: investor.account }),
      /nothing to refund/,
    );
  });

  it("conserves cumulative fee dust across multiple milestones", async () => {
    const dustToken = await viem.deployContract("MockERC20", [
      "Dust",
      "DUST",
      1_000n,
    ]);
    const dustEscrow = await viem.deployContract("KeiboCampaignEscrow", [
      admin.account.address,
      admin.account.address,
      86_400n,
    ]);
    await dustToken.write.mint([investor.account.address, 20n]);
    await dustToken.write.approve([dustEscrow.address, 20n], {
      account: investor.account,
    });
    await dustEscrow.write.createCampaign(
      [dustToken.address, 20n, (await latestTime()) + 86_400n, [1n, 19n]],
      { account: creator.account },
    );
    await dustEscrow.write.contribute([0n, 20n], { account: investor.account });
    for (const milestoneId of [0n, 1n]) {
      await dustEscrow.write.approveMilestone(
        [0n, milestoneId, `0x${"22".repeat(32)}`],
        { account: admin.account },
      );
      await dustEscrow.write.releaseMilestone([0n, milestoneId], {
        account: creator.account,
      });
    }
    assert.equal(await dustEscrow.read.releasedGross([0n]), 20n);
    assert.equal(await dustEscrow.read.releasedFees([0n]), 1n);
    assert.equal(await dustToken.read.balanceOf([creator.account.address]), 19n);
  });

  it("rejects late contributions and permits pull refunds after deadline", async () => {
    const deadline = (await latestTime()) + 100n;
    await escrow.write.createCampaign(
      [token.address, parseEther("2"), deadline, [parseEther("2")]],
      { account: creator.account },
    );
    await escrow.write.contribute([2n, parseEther("1")], {
      account: investor.account,
    });
    await networkHelpers.time.increaseTo(deadline);
    await assert.rejects(
      () =>
        escrow.write.contribute([2n, 1n], {
          account: investor.account,
        }),
      /invalid contribution/,
    );
    await escrow.write.refund([2n], { account: investor.account });
  });

  it("fails closed for paused operations, role compromise, and unsafe role recovery", async () => {
    await assert.rejects(
      () => escrow.write.pause({ account: attacker.account }),
      /AccessControlUnauthorizedAccount/,
    );
    await escrow.write.pause({ account: admin.account });
    const pausedCampaignDeadline = (await latestTime()) + 86_400n;
    await assert.rejects(
      () =>
        escrow.write.createCampaign(
          [token.address, 1n, pausedCampaignDeadline, [1n]],
          { account: creator.account },
        ),
      /EnforcedPause/,
    );
    await escrow.write.unpause({ account: admin.account });
    const guardianRole = await escrow.read.GUARDIAN_ROLE();
    await escrow.write.scheduleRoleTransfer(
      [guardianRole, attacker.account.address],
      { account: admin.account },
    );
    await assert.rejects(
      () =>
        escrow.write.executeRoleTransfer([guardianRole, admin.account.address], {
          account: attacker.account,
        }),
      /not executable/,
    );
    await escrow.write.cancelRoleTransfer([guardianRole], {
      account: admin.account,
    });
    await networkHelpers.time.increase(86_400);
    await assert.rejects(
      () =>
        escrow.write.executeRoleTransfer([guardianRole, admin.account.address], {
          account: attacker.account,
        }),
      /not executable/,
    );
  });

  it("separates network-cost evidence and rejects unauthorized recording", async () => {
    const evidenceHash = `0x${"33".repeat(32)}` as `0x${string}`;
    await assert.rejects(
      () =>
        escrow.write.recordNetworkCost([0n, 10n, evidenceHash], {
          account: attacker.account,
        }),
      /AccessControlUnauthorizedAccount/,
    );
    await escrow.write.recordNetworkCost([0n, 10n, evidenceHash], {
      account: admin.account,
    });
    assert.equal(await escrow.read.recordedNetworkCosts([0n]), 10n);
  });

  it("rejects false-return tokens and reentrant contribution callbacks", async () => {
    const falseToken = await viem.deployContract("FalseReturnERC20");
    const falseEscrow = await viem.deployContract("KeiboCampaignEscrow", [
      admin.account.address,
      admin.account.address,
      86_400n,
    ]);
    await falseToken.write.approve([falseEscrow.address, 100n], {
      account: admin.account,
    });
    await falseEscrow.write.createCampaign(
      [falseToken.address, 100n, (await latestTime()) + 86_400n, [100n]],
      { account: creator.account },
    );
    await assert.rejects(
      () => falseEscrow.write.contribute([0n, 100n], { account: admin.account }),
      /SafeERC20FailedOperation/,
    );
    assert.equal((await falseEscrow.read.campaigns([0n]))[3], 0n);

    const reentrantToken = await viem.deployContract("ReentrantERC20");
    const reentrantEscrow = await viem.deployContract("KeiboCampaignEscrow", [
      admin.account.address,
      admin.account.address,
      86_400n,
    ]);
    await reentrantToken.write.approve([reentrantEscrow.address, 100n], {
      account: admin.account,
    });
    await reentrantEscrow.write.createCampaign(
      [reentrantToken.address, 100n, (await latestTime()) + 86_400n, [100n]],
      { account: creator.account },
    );
    await reentrantToken.write.configure([reentrantEscrow.address, 0n]);
    await assert.rejects(
      () =>
        reentrantEscrow.write.contribute([0n, 100n], {
          account: admin.account,
        }),
      /ReentrancyGuardReentrantCall/,
    );
    assert.equal((await reentrantEscrow.read.campaigns([0n]))[3], 0n);
  });
});
