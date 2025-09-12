const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Escrow", function () {
  it("Should deposit funds", async function () {
    const Escrow = await ethers.getContractFactory("Escrow");
    const escrow = await Escrow.deploy();
    await escrow.deployed();

    const [owner] = await ethers.getSigners();
    const amount = ethers.utils.parseEther("1.0");

    await escrow.createProject(1);
    await escrow.deposit(1, { value: amount });

    expect(await ethers.provider.getBalance(escrow.address)).to.equal(amount);
  });
});