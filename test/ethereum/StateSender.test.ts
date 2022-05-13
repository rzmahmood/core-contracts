import { expect } from "chai";
import { ethers } from "hardhat";
import { BytesLike, utils } from "ethers";
import { StateSender } from "../../typechain";

describe("StateSender", () => {
  let stateSender: StateSender, accounts: any[]; // we use any so we can access address directly from object

  before(async () => {
    accounts = await ethers.getSigners();
    const StateSenderFactory = await ethers.getContractFactory("StateSender");

    stateSender = await StateSenderFactory.deploy();
    await stateSender.deployed();
  });

  it("should set initial params properly", async () => {
    expect(await stateSender.counter()).to.equal(0);
  });

  it("should check data length", async () => {
    const dataMaxLength = (await stateSender.MAX_LENGTH()).toNumber();
    const moreThanMaxData = "0x" + "00".repeat(dataMaxLength + 1); // notice `+ 1` here (it creates more than max data)
    const receiver = accounts[2].address;

    await expect(
      stateSender.syncState(receiver, moreThanMaxData)
    ).to.be.revertedWith("EXCEEDS_MAX_LENGTH");
  });

  it("should emit event properly", async () => {
    const dataMaxLength = (await stateSender.MAX_LENGTH()).toNumber();
    const maxData = "0x" + "00".repeat(dataMaxLength);
    const sender = accounts[0].address;
    const receiver = accounts[1].address;

    const tx = await stateSender.syncState(receiver, maxData);
    const receipt = await tx.wait();
    expect(receipt.events?.length).to.equals(1);

    const event = receipt.events?.find((log) => log.event === "StateSynced");
    expect(event?.args?.id).to.equal(1);
    expect(event?.args?.sender).to.equal(sender);
    expect(event?.args?.receiver).to.equal(receiver);
    expect(event?.args?.data).to.equal(maxData);
  });

  it("should increase counter properly", async () => {
    const dataMaxLength = (await stateSender.MAX_LENGTH()).toNumber();
    const maxData = "0x" + "00".repeat(dataMaxLength);
    const moreThanMaxData = "0x" + "00".repeat(dataMaxLength + 1);
    const receiver = accounts[1].address;

    const initialCounter = (await stateSender.counter()).toNumber();
    expect(await stateSender.counter()).to.equal(initialCounter);

    await stateSender.syncState(receiver, maxData);
    await stateSender.syncState(receiver, maxData);
    await expect(
      stateSender.syncState(receiver, moreThanMaxData)
    ).to.be.revertedWith("EXCEEDS_MAX_LENGTH");
    await stateSender.syncState(receiver, maxData);
    await expect(
      stateSender.syncState(receiver, moreThanMaxData)
    ).to.be.revertedWith("EXCEEDS_MAX_LENGTH");

    expect(await stateSender.counter()).to.equal(initialCounter + 3);
  });
});