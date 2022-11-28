// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

import "interface/ILPPositionMinter.sol";
import "interface/IPerpPositionMinter.sol";

import "hardhat/console.sol";

// On LP deposit: 
// - select ETH or USDC, adds to LP for current epoch

// User opens long:
// - Purchase options from ETH LP and sell option into USDC LP
// - If position size is 1 ETH, max leverage = abs(atm delta) * mark price * amount/(atm premium + fees + funding until expiry)
// - User selects amount of leverage on UI upto max leverage and required collateral is calculated and passed to openPosition()
// - On openPosition(), position is opened and recorded in struct. NFT representing position is transferred to user
// - ETH + USD LP records total position size, collateral and delta of position
// - PNL and delta are retrieved by querying position NFTs for user and total position size + delta for LP
// - Liquidation price is calculated by opening price - (margin / delta)

// User tops up collateral:
// - Collateral is added to open position
// - NFT'd position is updated with added margin
// - LPs record added margin

// User closes position:
// - Both long call and short put are closed
// - PNL is settled on both ETH and USD LPs
// - Fees and funding are deducted from final settlement

// User hits liquidation price:
// - Margin from position is credited to LP
// - Call option is still open since option premium is seized from margin

// User holds option until expiry:
// - Options are settled as per SSOV from either LP depending on whether they're calls/puts

// On expiry:
// - LPs are auto-rolled over to next epoch
// - Options are auto-settled vs LP
// - LP Withdraws from previous epoch are now withdrawable
// - Next epoch is now bootstrapped

// Notes:
// - 2 pools - eth / usdc  - single-sided liquidity. Lower liquidity side earns more fees. Incentivizes re-balancing to 50/50 target
// - Max leverage for opening long/short = mark price/((atm premium * 2) + fees + funding until expiry)
//   Max leverage: 1000 / ((90 * 2) + (90 * 0.25 * 0.01) + (1000 * 0.03))
// - Margin for opening long/short = (atm premium * max leverage / target leverage) + fees + funding until expiry
// - On closing, If pnl is +ve, payoff is removed from eth LP if long, USD lp if short. 
// - If pnl is -ve, OTM option is returned to pool + premium
// - Liquidation price = opening price - (margin / delta)

contract OptionPerp is Ownable {

  IERC20 base;
  IERC20 quote;

  ILPPositionMinter lpPositionMinter;
  IPerpPositionMinter perpPositionMinter;

  uint currentEpoch;

  // mapping (epoch => (isQuote => epoch lp data))
  mapping (uint => mapping (bool => EpochLPData)) public epochLpData;
  mapping (uint => LPPosition) public lpPositions;

  struct (uint => EpochData) public epochData;

  struct EpochLPData {
    // Total asset deposits
    uint totalDeposits;
    // Active deposits for option writes
    uint activeDeposits;
    // Average price of all positions taken by LP
    uint averageOpenPrice;
    // Open position count (in base asset)
    uint positions;
    // Margin deposited for write positions by users selling into LP
    uint margin;
    // Premium collected for option purchases from the pool
    uint premium;
    // Fees collected from positions
    uint fees;
    // Funding collected from positions
    uint funding;
    // Total open interest (in asset)
    uint oi;
    // Total long delta
    int longDelta;
    // Total short delta
    int shortDelta;
    // End of epoch PNL
    int pnl;
    // Amount withdrawn
    uint withdrawn;
  }

  struct EpochData {
    // Epoch expiry
    uint expiry;
    // Average open price
    uint averageOpenPrice;
    // Open Interest
    uint oi;
    // Price at expiry
    uint expiryPrice;
  }

  struct PerpPosition {
    // Is short positionn
    bool isShort;
    // Epoch
    uint epoch;
    // Total size in asset
    uint size;
    // Average open price
    uint averageOpenPrice;
    // Margin provided
    uint margin;
    // Premium for position
    uint premium;
    // Fees for position
    uint fees;
    // Funding for position
    uint funding;
    // Delta for open position
    int delta;
  }

  struct LPPosition {
    // Is quote asset
    bool isQuote;
    // Amount of asset
    uint amount;
    // Epoch
    uint epoch;
    // Is position set for withdraw. False if it's to be rolled over
    bool toWithdraw;
    // Epoch number if set to withdraw
    uint toWithdrawEpoch;
    // If withdrawn, true
    bool hasWithdrawn;
  }

  event Deposit(
    bool isQuote,
    uint amount,
    uint epoch,
    address indexed user,
    uint id
  );

  event InitWithdraw(
    uint id,
    address indexed user
  );

  event Withdraw(
    uint id,
    address indexed user,
    uint finalSettleAmount
  );

  constructor(
    address _base,
    address _quote
  ) {
    lpPositionMinter   = new ILPPositionMinter();
    perpPositionMinter = new IPerpPositionMinter();
  }

  // Deposits are auto-rolled over to the next epoch unless withdraw is called
  function deposit(
    bool isQuote,
    uint amount
  ) external 
  {
    uint nextEpoch = currentEpoch + 1;
    epochLpData[nextEpoch][isQuote].totalDeposits += amount;

    if (isQuote) 
      quote.transferFrom(msg.sender, address(this), amount);
    else
      base.transferFrom(msg.sender, address(this), amount);
    
    uint id = lpPositionMinter.mint(msg.sender);
    lpPositions[id] = LPPosition({
      isQuote: isQuote,
      amount: amount,
      epoch: nextEpoch
    });
    emit Deposit(
      isQuote,
      amount,
      nextEpoch,
      msg.sender,
      id
    );
  }

  // Inititate a withdrawal for end of epoch
  function initWithdraw(
    bool isQuote,
    uint amount,
    uint id
  ) external 
  {
    require(IERC721(lpPositionMinter).ownerOf(id) == msg.sender, "Invalid owner");
    require(!lpPositions[id].toWithdraw, "Already set for withdraw");
    require(!lpPositions[id].hasWithdrawn, "Already withdrawn");

    lpPositions[id].toWithdraw = true;
    
    emit InitWithdraw(
      id,
      msg.sender
    );
  }

  // Withdraw from epoch
  function withdraw(
    uint id
  ) external 
  {
    require(IERC721(lpPositionMinter).ownerOf(id) == msg.sender, "Invalid owner");
    require(lpPositions[id].toWithdraw, "Position not set for withdraw");
    require(!lpPositions[id].hasWithdrawn, "Already withdrawn");

    require(
      lpPositions[id].toWithdrawEpoch < currentEpoch, 
      "To withdraw epoch must be prior to current epoch"
    );

    // Calculate LP pnl, transfer out and burn
    uint finalLpAmountToWithdraw = _calcFinalLpAmount(id);

    IERC20(lpPositions[id].isQuote ? quote : base).transfer(msg.sender, finalLpAmountToWithdraw);

    // Update epoch LP data
    epochLpData[toWithdrawEpoch][lpPositions[id].isQuote].withdrawn += finalLpAmountToWithdraw;

    emit Withdraw(
      id,
      finalLpAmountToWithdraw,
      msg.sender
    );
  }

  // Calculates final LP amount for a LP position after accounting for PNL in an epoch
  function _calcFinalLpAmount(id) 
  private
  returns (uint finalLpAmount) 
  {
    // LP PNL for an epoch = 
    uint isQuote = lpPositions[id].isQuote;
    uint epoch = lpPositions[id].toWithdrawEpoch;
    uint amount = lpPositions[id].amount;
    uint totalDeposits = epochLpData[epoch][isQuote].totalDeposits;
    int pnl = epochLpData[epoch][isQuote].pnl;
    finalLpAmount = amount * (uint)(totalDeposits + pnl) / totalDeposits;
  }

  // Expires an epoch and bootstraps the next epoch
  function expireEpoch(
    uint nextExpiryTimestamp
  ) external {
    require(epochData[currentEpoch].expiry < block.timestamp, "Time must be after expiry");
    require(nextExpiryTimestamp > epochData[currentEpoch].expiry, "Invalid next expiry timestamp");
    uint nextEpoch = currentEpoch + 1;
    epochData[nextEpoch].expiry = nextExpiryTimestamp;

    // Get expiry price
    uint expiryPrice; // = _getCurrentPrice();
    epochData[currentEpoch].expiryPrice = expiryPrice;

    // long: long call, short put
    // short: long put, short call
    // Base LP: Call liquidity
    // Quote LP: Put liquidity

    // Calculate short LP payout from OI in quote asset
    // If expiry price > average open price, put writers have to pay out nothing
    // else, put writers pnl = (exp - avg. open price) * oi/avg. open price
    // for example, exp: 500, avgOpen: 1000, oi: 1000 
    // (500 - 1000) * 1000/500
    int quoteLpPayout = 
      expiryPrice > epochLpData[currentEpoch][true].averageOpenPrice ? 0 :
      (expiryPrice - epochLpData[currentEpoch][true].averageOpenPrice) *
      oi/epochLpData[currentEpoch][true].averageOpenPrice;
    // Calculate long LP payout from OI in base asset
    int baseLpPayout = 
      epochLpData[currentEpoch][false].averageOpenPrice > expiryPrice ? 0 :
      ((epochLpData[currentEpoch][false].averageOpenPrice - expiryPrice) * oi/expiryPrice)/expiryPrice;
      // exp: 500, avgOpen: 1000, oi: 1000, (1000 - 500) * 1000/500

    // Calculate quote pnl in quote asset
    epochLpData[currentEpoch][true].pnl = 
      quoteLpPayout + epochLpData[currentEpoch][true].premium + 
      epochLpData[currentEpoch][true].fees + 
      epochLpData[currentEpoch][true].funding;

    // Calculate base pnl in base asset
    epochLpData[currentEpoch][false].pnl = 
      baseLpPayout + epochLpData[currentEpoch][false].premium + 
      epochLpData[currentEpoch][false].fees + 
      epochLpData[currentEpoch][false].funding;
    
  }

  // Open a new position
  function openPosition(
    bool isShort,
    uint size,
    uint collateralAmount
  ) external returns (uint id) {
    // Check for expiry
    require(epochData[currentEpoch].expiry < block.timestamp, "Time must be before expiry");

    // Check if enough liquidity is available to open position
    require(
      epochLpData[currentEpoch][isShort].totalDeposits - epochLpData[currentEpoch][isShort].activeDeposits >= size,
      "Not enough liquidity to open position" 
    );

    // Calculate premium for ATM option
    uint premium = _calculatePremium(size);

    // Calculate funding
    uint funding = _calculateFunding(isShort, size);

    // Calculate fees
    uint fees = _calculateFees(size, premium, funding);

    // Calculate minimum collateral
    uint minCollateral = _getMarkPrice() / ((premium * 2) + fees + funding);
    
    // Check if collateral amount is sufficient for short side of trade and long premium
    require(
      collateralAmount >= minCollateral,
      "Collateral must be greater than min. collateral"
    );

    // Update epoch LP data
    epochLpData[currentEpoch][isShort].margin            += collateralAmount;
    epochLpData[currentEpoch][isShort].oi                += size;
    epochLpData[currentEpoch][isShort].premium           += premium;
    epochLpData[currentEpoch][isShort].funding           += funding;
    epochLpData[currentEpoch][isShort].fees              += fees;
    epochLpData[currentEpoch][isShort].activeDeposits    += size;
    epochLpData[currentEpoch][isShort].positions         += size / _getMarkPrice();

    epochLpData[currentEpoch][isShort].longDelta += size;
    epochLpData[currentEpoch][!isShort].shortDelta += size;

    if (epochLpData[currentEpoch][isShort].averageOpenPrice == 0) 
      epochLpData[currentEpoch][isShort].averageOpenPrice  = _getMarkPrice();
    else
      epochLpData[currentEpoch][isShort].averageOpenPrice  = 
        epochLpData[currentEpoch][isShort].size / 
        epochLpData[currentEpoch][isShort].positions;

    // 


  }

  // Calculate premium for longing an ATM option
  function _calculatePremium(
    uint size
  ) internal 
  returns (uint premium) {

  }

  // Calculate funding for opening a position until expiry
  function _calculateFunding(
    uint size,
    uint premium,
    uint funding
  ) internal 
  returns (uint premium) {

  }

  // Calculate fees for opening a perp position
  function _calculateFees(
    uint premium,
    uint funding,
    uint size
  ) internal 
  returns (uint premium) {

  }

  // Returns price of base asset from oracle
  function _getMarkPrice()
  external
  returns (uint price) {

  }

  // Add collateral to an existing position
  function addCollateral(
    uint id,
    uint collateralAmount
  ) external {

  }

  // Close an existing position
  function closePosition(
    uint id
  ) external {

  }

  // Liquidate a position passed the liquidation threshold
  function liquidate(
    uint id
  ) external {

  }

}
