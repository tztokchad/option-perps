const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option Perp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let priceOracle;
  let volatilityOracle;
  let optionPricing;
  let lpPositionMinter;
  let perpPositionMinter;
  let uniswapFactory;
  let wethUsdcPair;
  let uniswapRouter;
  let optionPerp;

  const MAX_UINT =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";
  const oneWeek = 7 * 24 * 60 * 60;

  const toEther = val =>
    BigNumber.from(10)
      .pow(18)
      .mul(val);

  const toDecimals = (val, decimals) =>
    BigNumber.from(10)
      .pow(decimals)
      .mul(val);

  const getTime = () => Math.floor(new Date().getTime() / 1000);

  const timeTravel = async seconds => {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine", []);
  };

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
  });

  it("should deploy option perp", async function() {
    // USDC
    const USDC = await ethers.getContractFactory("USDC");
    usdc = await USDC.deploy();
    // WETH
    const WETH = await ethers.getContractFactory("WETH");
    weth = await WETH.deploy();
    // Price oracle
    const PriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await PriceOracle.deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory(
      "MockVolatilityOracle"
    );
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("MockOptionPricing");
    optionPricing = await OptionPricing.deploy();
    // LP position minter
    const LPPositionMinter = await ethers.getContractFactory(
      "LPPositionMinter"
    );
    lpPositionMinter = await LPPositionMinter.deploy();
    // Perp position minter
    const PerpPositionMinter = await ethers.getContractFactory(
      "PerpPositionMinter"
    );
    perpPositionMinter = await PerpPositionMinter.deploy();
    // Uniswap factory
    const UniswapFactory = await ethers.getContractFactory("UniswapV2Factory");
    uniswapFactory = await UniswapFactory.deploy(owner.address);
    await uniswapFactory.createPair(weth.address, usdc.address);
    // WETH-USDC pair
    const wethUsdcPairAddress = await uniswapFactory.getPair(
      weth.address,
      usdc.address
    );
    const WethUsdcPair = await ethers.getContractFactory("UniswapV2Pair");
    wethUsdcPair = WethUsdcPair.attach(wethUsdcPairAddress);

    // Uniswap router
    const UniswapRouter = await ethers.getContractFactory("UniswapV2Router02");
    uniswapRouter = await UniswapRouter.deploy(
      uniswapFactory.address,
      weth.address
    );
    // Option Perp
    const OptionPerp = await ethers.getContractFactory("OptionPerp");
    optionPerp = await OptionPerp.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address
    );
    console.log("deployed option perp:", optionPerp.address);
    await lpPositionMinter.setOptionPerpContract(optionPerp.address);
    await perpPositionMinter.setOptionPerpContract(optionPerp.address);

    await weth.approve(uniswapRouter.address, MAX_UINT);
    await usdc.approve(uniswapRouter.address, MAX_UINT);

    await uniswapRouter.addLiquidity(
      weth.address,
      usdc.address,
      toEther(10_000),
      toDecimals(10_000_000, 6),
      0,
      0,
      owner.address,
      (await ethers.provider.getBlock("latest")).timestamp + 10
    );
  });

  it("should not be able to deposit quote without sufficient usd balance", async () => {
    const amount = 10000 * 10 ** 6;
    await usdc.connect(user1).approve(optionPerp.address, MAX_UINT);
    await expect(
      optionPerp.connect(user1).deposit(true, amount)
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should deposit quote successfully", async () => {
    const amount = 10000 * 10 ** 6;
    await usdc.approve(optionPerp.address, MAX_UINT);
    await optionPerp.deposit(true, amount);
    expect((await optionPerp.epochLpData(1, true)).totalDeposits).equals(
      amount
    );
    const lpPosition = await optionPerp.lpPositions(0);
    expect(lpPosition.amount.toString()).equals(amount.toString());
    expect(lpPosition.owner).equals(owner.address);
  });

  it("should not be able to deposit base without sufficient weth balance", async () => {
    const amount = 10 * 10 ** 6;
    await weth.connect(user1).approve(optionPerp.address, MAX_UINT);
    await expect(
      optionPerp.connect(user1).deposit(false, amount)
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should deposit base successfully", async () => {
    const amount = (10 * 10 ** 18).toString();
    await weth.approve(optionPerp.address, MAX_UINT);
    await optionPerp.deposit(false, amount);
    expect((await optionPerp.epochLpData(1, false)).totalDeposits).equals(
      amount
    );
    const lpPosition = await optionPerp.lpPositions(1);
    expect(lpPosition.amount.toString()).equals(amount.toString());
    expect(lpPosition.owner).equals(owner.address);
  });

  it("should be able to immediately initialize a withdraw, even before first bootstrap", async () => {
    const amount = (10 * 10 ** 18).toString();
    await optionPerp.initWithdraw(false, amount, 1);
  });

  it("should not be able to immediately withdraw", async () => {
    await expect(optionPerp.withdraw(1)).to.be.revertedWith('To withdraw epoch must be prior to current epoch');
  });

  it("should not be able to open position at epoch 0", async () => {
    await expect(
      optionPerp.openPosition(false, toDecimals(1000, 8), toDecimals(500, 8))
    ).to.be.revertedWith("Invalid epoch");
  });

  it("should bootstrap successfully", async () => {
    const oneWeekFromNow = getTime() + oneWeek;
    await optionPerp.expireAndBootstrap(oneWeekFromNow);
    expect(await optionPerp.currentEpoch()).equals(1);
  });

  it("should not bootstrap if current epoch hasn't expired", async () => {
    const oneWeekFromNow = getTime() + oneWeek;
    await expect(
      optionPerp.expireAndBootstrap(oneWeekFromNow)
    ).to.be.revertedWith(
      "Cannot bootstrap before the current epoch was expired"
    );
  });

  it("should not be able to open position if liquidity is insufficient", async () => {
    await expect(
      optionPerp.openPosition(false, toDecimals(100000, 8), toDecimals(500, 6))
    ).to.be.revertedWith("Not enough liquidity to open position");
  });

  it("should not be able to open position if user doesn't have enough funds", async () => {
    await expect(
      optionPerp
        .connect(user1)
        .openPosition(false, toDecimals(1000, 8), toDecimals(500, 6))
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should open position successfully", async () => {
    await usdc.transfer(user1.address, toDecimals(10_000, 6));
    console.log(
      "user1 balance:",
      (await usdc.balanceOf(user1.address)).toString()
    );
    await optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(1000, 8), toDecimals(500, 6));
    const { size } = await optionPerp.perpPositions(0);
    expect(size).equal(toDecimals(1000, 8));
    expect(await usdc.balanceOf(user1.address)).equals(
      BigNumber.from(toDecimals(10_000, 6)).sub(toDecimals(500, 6))
    );
  });

  it("should not be able to withdraw even if correctly initialized before first bootstrap if final lp amount is 0", async () => {
    await expect(optionPerp.withdraw(1)).to.be.revertedWith('Invalid final lp amount');
  });
});
