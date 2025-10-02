import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { parseEther, getAddress } from "viem";

describe("Escrow", async function () {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  // Get wallet clients
  const [
    owner,
    creator,
    investor1,
    investor2,
    validator,
    resolver,
    feeRecipient,
  ] = await viem.getWalletClients();

  // Deploy a mock ERC20 token for testing
  const mockToken = await viem.deployContract("MockERC20", [
    "Test Token",
    "TT",
    parseEther("1000000"),
  ]);

  // Deploy the Escrow contract
  const enhancedEscrow = await viem.deployContract("Escrow", [
    feeRecipient.account.address,
  ]);

  // Grant roles
  await enhancedEscrow.write.grantRole([
    await enhancedEscrow.read.RESOLVER_ROLE(),
    resolver.account.address,
  ]);
  await enhancedEscrow.write.grantRole([
    await enhancedEscrow.read.VALIDATOR_ROLE(),
    validator.account.address,
  ]);

  // Mint tokens to investors
  await mockToken.write.mint([investor1.account.address, parseEther("1000")]);
  await mockToken.write.mint([investor2.account.address, parseEther("1000")]);
  await mockToken.write.mint([creator.account.address, parseEther("1000")]);

  // Approve token spending
  await mockToken.write.approve([enhancedEscrow.address, parseEther("1000")], {
    account: investor1.account,
  });
  await mockToken.write.approve([enhancedEscrow.address, parseEther("1000")], {
    account: investor2.account,
  });

  it("Should create a new project successfully", async function () {
    const nextId: bigint = await enhancedEscrow.read.projectCounter();
    const title = "Test Project";
    const description = "A test project for crowdfunding";
    const targetAmount = parseEther("10");
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60); // 30 days from now

    const hash = await enhancedEscrow.write.createProject(
      [
        title,
        description,
        targetAmount,
        deadline,
        "0x0000000000000000000000000000000000000000", // ETH project
      ],
      {
        account: creator.account,
      }
    );

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    // Check event emission using viem assertions
    await viem.assertions.emitWithArgs(hash, enhancedEscrow, "ProjectCreated", [
      nextId,
      getAddress(creator.account.address),
      title,
      targetAmount,
    ]);

    const project = await enhancedEscrow.read.getProject([nextId]);
    assert.equal(getAddress(project[0]), getAddress(creator.account.address));
    assert.equal(project[1], title);
    assert.equal(project[3], targetAmount);
    assert.equal(Number(project[6]), 0); // ProjectStatus.Active
  });

  it("Should reject project creation with empty title", async function () {
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);

    await assert.rejects(
      () =>
        enhancedEscrow.write.createProject(
          [
            "",
            "Description",
            parseEther("10"),
            deadline,
            "0x0000000000000000000000000000000000000000",
          ],
          {
            account: creator.account,
          }
        ),
      /Title required/
    );
  });

  it("Should reject project creation with empty description", async function () {
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);

    await assert.rejects(
      () =>
        enhancedEscrow.write.createProject(
          [
            "Title",
            "",
            parseEther("10"),
            deadline,
            "0x0000000000000000000000000000000000000000",
          ],
          {
            account: creator.account,
          }
        ),
      /Description required/
    );
  });

  it("Should reject project creation with zero target amount", async function () {
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);

    await assert.rejects(
      () =>
        enhancedEscrow.write.createProject(
          [
            "Title",
            "Description",
            0n,
            deadline,
            "0x0000000000000000000000000000000000000000",
          ],
          {
            account: creator.account,
          }
        ),
      /Invalid target amount/
    );
  });

  it("Should create a milestone successfully", async function () {
    // First create a project
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const amount = parseEther("5");
    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60); // 14 days from now
    const title = "First Milestone";
    const description = "Complete the first phase";
    const requiredApprovals = 2n;

    const hash = await enhancedEscrow.write.createMilestone(
      [
        projectId, // projectId
        amount,
        dueDate,
        title,
        description,
        requiredApprovals,
      ],
      {
        account: creator.account,
      }
    );

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    // Check event emission using viem assertions
    await viem.assertions.emitWithArgs(
      hash,
      enhancedEscrow,
      "MilestoneCreated",
      [projectId, 0n, amount, dueDate]
    );

    const milestone = await enhancedEscrow.read.getMilestone([projectId, 0n]);
    assert.equal(milestone[0], amount);
    assert.equal(milestone[2], title);
    assert.equal(milestone[6], requiredApprovals);
    assert.equal(Number(milestone[4]), 0); // MilestoneStatus.Pending
  });

  it("Should reject milestone creation with zero amount", async function () {
    // First create a project
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60);

    await assert.rejects(
      () =>
        enhancedEscrow.write.createMilestone(
          [
            0n, // projectId
            0n, // amount
            dueDate,
            "Title",
            "Description",
            2n,
          ],
          {
            account: creator.account,
          }
        ),
      /Invalid amount/
    );
  });

  it("Should allow ETH deposits", async function () {
    // First create a project
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const depositAmount = parseEther("2");

    const hash = await enhancedEscrow.write.deposit(
      [projectId, depositAmount],
      {
        account: investor1.account,
        value: depositAmount,
      }
    );

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    // Check event emission using viem assertions
    await viem.assertions.emitWithArgs(hash, enhancedEscrow, "FundsDeposited", [
      projectId,
      getAddress(investor1.account.address),
      depositAmount,
      getAddress("0x0000000000000000000000000000000000000000"),
    ]);

    const project = await enhancedEscrow.read.getProject([projectId]);
    assert.equal(project[4], depositAmount);

    const investment = await enhancedEscrow.read.getUserInvestment([
      projectId,
      getAddress(investor1.account.address),
    ]);
    assert.equal(investment[0], depositAmount);
  });

  it("Should allow ERC20 token deposits", async function () {
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    await enhancedEscrow.write.createProject(
      [
        "Token Project",
        "A token project",
        parseEther("10"),
        deadline,
        mockToken.address,
      ],
      {
        account: creator.account,
      }
    );

    const depositAmount = parseEther("2");

    const hash = await enhancedEscrow.write.deposit(
      [projectId, depositAmount],
      {
        account: investor1.account,
      }
    );

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    // Check event emission using viem assertions
    await viem.assertions.emitWithArgs(hash, enhancedEscrow, "FundsDeposited", [
      projectId,
      getAddress(investor1.account.address),
      depositAmount,
      getAddress(mockToken.address),
    ]);

    const project = await enhancedEscrow.read.getProject([projectId]);
    assert.equal(project[4], depositAmount);
  });

  it("Should complete project when target amount is reached", async function () {
    // First create a project
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const depositAmount = parseEther("10");

    const hash = await enhancedEscrow.write.deposit(
      [projectId, depositAmount],
      {
        account: investor1.account,
        value: depositAmount,
      }
    );

    await viem.assertions.emitWithArgs(
      hash,
      enhancedEscrow,
      "ProjectStatusChanged",
      [projectId, 1]
    );

    const project = await enhancedEscrow.read.getProject([projectId]);
    assert.equal(Number(project[6]), 1); // ProjectStatus.Completed
  });

  it("Should allow creator to submit milestone evidence", async function () {
    // First create a project and milestone
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60);
    await enhancedEscrow.write.createMilestone(
      [
        projectId, // projectId
        parseEther("5"),
        dueDate,
        "First Milestone",
        "Description",
        1n, // Only 1 approval needed for testing
      ],
      {
        account: creator.account,
      }
    );

    // Fund the project
    await enhancedEscrow.write.deposit([projectId, parseEther("5")], {
      account: investor1.account,
      value: parseEther("5"),
    });

    const evidenceURI = "https://example.com/evidence";

    const hash = await enhancedEscrow.write.submitMilestone(
      [
        projectId, // projectId
        0n, // milestoneId
        evidenceURI,
      ],
      {
        account: creator.account,
      }
    );

    await viem.assertions.emit(hash, enhancedEscrow, "MilestoneSubmitted");

    const milestone = await enhancedEscrow.read.getMilestone([projectId, 0n]);
    assert.equal(milestone[3], evidenceURI);
    assert.equal(Number(milestone[4]), 1); // MilestoneStatus.Submitted
  });

  it("Should allow validators to approve milestones", async function () {
    // First create a project and milestone
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60);
    await enhancedEscrow.write.createMilestone(
      [
        projectId, // projectId
        parseEther("5"),
        dueDate,
        "First Milestone",
        "Description",
        1n, // Only 1 approval needed for testing
      ],
      {
        account: creator.account,
      }
    );

    // Fund the project
    await enhancedEscrow.write.deposit([projectId, parseEther("5")], {
      account: investor1.account,
      value: parseEther("5"),
    });

    // Submit milestone first
    await enhancedEscrow.write.submitMilestone(
      [
        projectId, // projectId
        0n, // milestoneId
        "https://example.com/evidence",
      ],
      {
        account: creator.account,
      }
    );

    // Approve milestone
    const hash = await enhancedEscrow.write.approveMilestone(
      [
        projectId, // projectId
        0n, // milestoneId
      ],
      {
        account: validator.account,
      }
    );

    await viem.assertions.emit(hash, enhancedEscrow, "MilestoneApproved");

    const milestone = await enhancedEscrow.read.getMilestone([projectId, 0n]);
    assert.equal(milestone[5], 1n); // approvalsCount
  });

  it("Should allow investors to raise disputes", async function () {
    // First create a project and milestone
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60);
    await enhancedEscrow.write.createMilestone(
      [
        projectId, // projectId
        parseEther("5"),
        dueDate,
        "First Milestone",
        "Description",
        2n,
      ],
      {
        account: creator.account,
      }
    );

    // Fund the project
    await enhancedEscrow.write.deposit([projectId, parseEther("5")], {
      account: investor1.account,
      value: parseEther("5"),
    });

    const hash = await enhancedEscrow.write.raiseDispute(
      [
        projectId, // projectId
        0n, // milestoneId
        "Poor quality work",
      ],
      {
        account: investor1.account,
      }
    );

    await viem.assertions.emit(hash, enhancedEscrow, "DisputeRaised");

    const milestone = await enhancedEscrow.read.getMilestone([projectId, 0n]);
    // Dispute status is not exposed in getMilestone; check status only
    assert.equal(Number(milestone[4]), 3); // MilestoneStatus.Disputed
  });

  it("Should allow resolvers to resolve disputes", async function () {
    // First create a project and milestone
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    const dueDate =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(14 * 24 * 60 * 60);
    await enhancedEscrow.write.createMilestone(
      [
        projectId, // projectId
        parseEther("5"),
        dueDate,
        "First Milestone",
        "Description",
        2n,
      ],
      {
        account: creator.account,
      }
    );

    // Fund the project
    await enhancedEscrow.write.deposit([projectId, parseEther("5")], {
      account: investor1.account,
      value: parseEther("5"),
    });

    // Raise dispute first
    await enhancedEscrow.write.raiseDispute(
      [
        projectId, // projectId
        0n, // milestoneId
        "Poor quality work",
      ],
      {
        account: investor1.account,
      }
    );

    // Resolve dispute in favor of creator
    const hash = await enhancedEscrow.write.resolveDispute(
      [
        projectId, // projectId
        0n, // milestoneId
        true,
      ],
      {
        account: resolver.account,
      }
    );

    await viem.assertions.emit(hash, enhancedEscrow, "DisputeResolved");

    const milestone = await enhancedEscrow.read.getMilestone([projectId, 0n]);
    // After resolving in favor of creator, funds are released
    assert.equal(Number(milestone[4]), 4); // MilestoneStatus.Released
  });

  it("Should allow admin to trigger emergency withdrawal", async function () {
    // First create a project
    const projectId: bigint = await enhancedEscrow.read.projectCounter();
    const deadline =
      BigInt(Math.floor(Date.now() / 1000)) + BigInt(30 * 24 * 60 * 60);
    await enhancedEscrow.write.createProject(
      [
        "Test Project",
        "A test project",
        parseEther("10"),
        deadline,
        "0x0000000000000000000000000000000000000000",
      ],
      {
        account: creator.account,
      }
    );

    // Fund the project
    await enhancedEscrow.write.deposit([projectId, parseEther("5")], {
      account: investor1.account,
      value: parseEther("5"),
    });

    const hash = await enhancedEscrow.write.triggerEmergencyWithdraw(
      [projectId],
      {
        account: owner.account,
      }
    );

    await viem.assertions.emit(
      hash,
      enhancedEscrow,
      "EmergencyWithdrawTriggered"
    );

    const project = await enhancedEscrow.read.getProject([projectId]);
    assert.equal(Number(project[6]), 2); // ProjectStatus.Cancelled
  });

  it("Should only allow admin to pause/unpause", async function () {
    await assert.rejects(
      () =>
        enhancedEscrow.write.pause([], {
          account: creator.account,
        }),
      /AccessControlUnauthorizedAccount/
    );

    await enhancedEscrow.write.pause([], {
      account: owner.account,
    });
    assert.equal(await enhancedEscrow.read.paused(), true);

    await enhancedEscrow.write.unpause([], {
      account: owner.account,
    });
    assert.equal(await enhancedEscrow.read.paused(), false);
  });

  it("Should only allow admin to set platform fee", async function () {
    await assert.rejects(
      () =>
        enhancedEscrow.write.setPlatformFee([500n], {
          account: creator.account,
        }),
      /AccessControlUnauthorizedAccount/
    );

    await enhancedEscrow.write.setPlatformFee([500n], {
      account: owner.account,
    });
    assert.equal(await enhancedEscrow.read.platformFeePercentage(), 500n);
  });

  it("Should reject invalid platform fee", async function () {
    await assert.rejects(
      () =>
        enhancedEscrow.write.setPlatformFee([1001n], {
          account: owner.account,
        }),
      /Fee too high/
    );
  });
});
