const { expect } = require("chai");
const { ethers } = require("hardhat");

async function getPermitSignature(token, owner, spender, value, deadline) {
  // Get chainId from provider.
  const { chainId } = await ethers.provider.getNetwork();
  // Get the current nonce for the owner.
  const nonce = await token.nonces(owner.address);
  const name = await token.name();

  const domain = {
    name: name,
    version: "1",
    chainId: chainId,
    verifyingContract: token.address,
  };

  const types = {
    Permit: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };

  const message = {
    owner: owner.address,
    spender: spender,
    value: value,
    nonce: nonce.toNumber(),
    deadline: deadline,
  };

  const signature = await owner._signTypedData(domain, types, message);
  return ethers.utils.splitSignature(signature);
}

describe("PerpEngine", function () {
  let PerpEngine, perpEngine, TestToken, testToken;
  let owner, solver, user, other;
  const globalFee = 50; // 50 basis points: i.e. 0.5%

  beforeEach(async function () {
    [owner, solver, user, other] = await ethers.getSigners();

    // Deploy TestToken (ERC20 with permit features)
    const TestTokenFactory = await ethers.getContractFactory("TestToken");
    testToken = await TestTokenFactory.deploy();
    await testToken.deployed();

    // Transfer some tokens to 'user' for testing deposits.
    await testToken.transfer(user.address, ethers.utils.parseEther("1000"));

    // Deploy the PerpEngine contract.
    const PerpEngineFactory = await ethers.getContractFactory("PerpEngine");
    perpEngine = await PerpEngineFactory.deploy(globalFee);
    await perpEngine.deployed();
  });

  describe("Deployment", function () {
    it("should set the owner correctly", async function () {
      expect(await perpEngine.owner()).to.equal(owner.address);
    });

    it("should set the global fee correctly", async function () {
      expect(await perpEngine.globalFee()).to.equal(globalFee);
    });
  });

  describe("Deposit Flow", function () {
    it("should allow a user to create an intent via token deposit using permit", async function () {
      const amount = ethers.utils.parseEther("100");
      const deadline = Math.floor(Date.now() / 1000) + 3600; // valid for 1 hour

      // Generate permit signature for the user.
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);

      // Call createIntent from the user account.
      await expect(
        perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s)
      )
        .to.emit(perpEngine, "IntentCreated")
        .withArgs(0, user.address, testToken.address, amount);

      // The tokens should now be held in the PerpEngine contract.
      expect(await testToken.balanceOf(perpEngine.address)).to.equal(amount);

      // Check that the intent state is Active (enum index 1).
      const intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(1);
    });

    it("should only allow an approved solver to register a deposit", async function () {
      const amount = ethers.utils.parseEther("100");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      // Attempting to call registerDeposit from a non-approved solver should revert.
      await expect(
        perpEngine.connect(other).registerDeposit(0)
      ).to.be.revertedWith("Not an approved solver");

      // Approve the solver.
      await perpEngine.connect(owner).approveSolver(solver.address);

      // Now the approved solver can register deposit.
      await expect(perpEngine.connect(solver).registerDeposit(0))
        .to.emit(perpEngine, "IntentFulfilled")
        .withArgs(0);

      // The intent state should now be Fulfilled (enum index 4).
      const intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(4);
    });

    it("should allow a solver to settle an intent and correctly pay fees", async function () {
      const amount = ethers.utils.parseEther("100");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      // Approve the solver and proceed with deposit registration.
      await perpEngine.connect(owner).approveSolver(solver.address);
      await perpEngine.connect(solver).registerDeposit(0);

      // Record initial token balances for the solver and the user.
      const solverInitialBalance = await testToken.balanceOf(solver.address);
      const userInitialBalance = await testToken.balanceOf(user.address);

      // Call settle as the solver.
      await expect(perpEngine.connect(solver).settle(0))
        .to.emit(perpEngine, "IntentSettled")
        .withArgs(0);

      // The intent state should now be Settled (enum index 5).
      const intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(5);

      // Calculate fee: fee = (amount * globalFee) / 10000.
      const fee = amount.mul(globalFee).div(10000);
      const expectedSolverBalance = solverInitialBalance.add(fee);
      const expectedUserBalance = userInitialBalance.add(amount.sub(fee));

      expect(await testToken.balanceOf(solver.address)).to.equal(expectedSolverBalance);
      expect(await testToken.balanceOf(user.address)).to.equal(expectedUserBalance);
    });
  });

  describe("Abort Flow", function () {
    it("should allow a user to request an abort and then abort the intent, returning funds", async function () {
      const amount = ethers.utils.parseEther("50");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      // User requests an abort.
      await perpEngine.connect(user).requestAbort(0);
      let intent = await perpEngine.intents(0);
      // The state should now be RequestedAbort (enum index 2).
      expect(intent.state).to.equal(2);

      // Execute abortIntent to return funds to the user.
      await expect(perpEngine.connect(user).abortIntent(0))
        .to.emit(perpEngine, "IntentAborted")
        .withArgs(0);

      // The intent state should now be Aborted (enum index 3).
      intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(3);

      // Check that the user's token balance is returned.
      // The user initially had 1000 tokens, then deposited 50.
      expect(await testToken.balanceOf(user.address)).to.equal(ethers.utils.parseEther("1000"));
    });
  });

  describe("Withdraw Flow", function () {
    it("should allow a user to request a withdrawal (stub function)", async function () {
      const amount = ethers.utils.parseEther("80");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      // Call the withdraw stub. It currently only checks that the intent is Active.
      await expect(perpEngine.connect(user).requestWithdraw(0)).not.to.be.reverted;
    });
  });

  describe("Solver Management", function () {
    it("should allow the owner to approve and revoke solvers", async function () {
      await expect(perpEngine.connect(owner).approveSolver(solver.address)).to.not.be.reverted;
      expect(await perpEngine.approvedSolvers(solver.address)).to.equal(true);

      await expect(perpEngine.connect(owner).revokeSolver(solver.address)).to.not.be.reverted;
      expect(await perpEngine.approvedSolvers(solver.address)).to.equal(false);
    });

    it("should revert when a non-owner tries to approve or revoke solvers", async function () {
      await expect(perpEngine.connect(user).approveSolver(solver.address)).to.be.revertedWith("Not the owner");
      await expect(perpEngine.connect(user).revokeSolver(solver.address)).to.be.revertedWith("Not the owner");
    });
  });

  describe("Garbage Collection", function () {
    it("should mark a settled intent as Deleted", async function () {
      const amount = ethers.utils.parseEther("60");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      await perpEngine.connect(owner).approveSolver(solver.address);
      await perpEngine.connect(solver).registerDeposit(0);
      await perpEngine.connect(solver).settle(0);

      // Use garbageCollect to mark the Settled intent as Deleted.
      await expect(perpEngine.connect(owner).garbageCollect([0]))
        .to.emit(perpEngine, "IntentDeleted")
        .withArgs(0);

      const intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(6); // Deleted
    });

    it("should mark an aborted intent as Deleted", async function () {
      const amount = ethers.utils.parseEther("70");
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const { v, r, s } = await getPermitSignature(testToken, user, perpEngine.address, amount, deadline);
      await perpEngine.connect(user).createIntent(testToken.address, amount, deadline, v, r, s);

      await perpEngine.connect(user).requestAbort(0);
      await perpEngine.connect(user).abortIntent(0);

      // Garbage collect the aborted intent.
      await expect(perpEngine.connect(owner).garbageCollect([0]))
        .to.emit(perpEngine, "IntentDeleted")
        .withArgs(0);

      const intent = await perpEngine.intents(0);
      expect(intent.state).to.equal(6);
    });
  });
}); 