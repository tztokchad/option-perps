// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LPPositionMinter} from "./positions/LPPositionMinter.sol";
import {PerpPositionMinter} from "./positions/PerpPositionMinter.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IGmxRouter} from "./interface/IGmxRouter.sol";

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

  IERC20 public base;
  IERC20 public quote;

  IOptionPricing public optionPricing;
  IVolatilityOracle public volatilityOracle;
  IPriceOracle public priceOracle;

  LPPositionMinter public lpPositionMinter;
  PerpPositionMinter public perpPositionMinter;

  IGmxRouter public gmxRouter;

  uint public currentEpoch;

  // mapping (epoch => (isQuote => epoch lp data))
  mapping (uint => mapping (bool => EpochLPData)) public epochLpData;
  mapping (uint => LPPosition) public lpPositions;
  mapping (uint => PerpPosition) public perpPositions;

  mapping (uint => EpochData) public epochData;

  int public divisor                = 1e8;
  int public fundingRate            = 3650000000; // 36.5% annualized (0.1% a day)
  int public feeOpenPosition        = 5000000; // 0.05%
  int public feeClosePosition       = 5000000; // 0.05%
  int public feeLiquidation         = 50000000; // 0.5%
  int public liquidationThreshold   = 500000000; // 5%

  uint internal constant POSITION_PRECISION = 1e8;
  uint internal constant OPTIONS_PRECISION = 1e18;

  struct EpochLPData {
    // Starting asset deposits
    int startingDeposits;
    // Total asset deposits
    int totalDeposits;
    // Active deposits for option writes
    int activeDeposits;
    // Average price of all positions taken by LP
    int averageOpenPrice;
    // Open position count (in base asset)
    int positions;
    // Margin deposited for write positions by users selling into LP
    int margin;
    // Premium collected for option purchases from the pool
    int premium;
    // Opening fees collected from positions
    int openingFees;
    // Closing fees collected from positions
    int closingFees;
    // Funding collected from positions
    int funding;
    // Total open interest (in asset)
    int oi;
    // // Total long delta
    // int longDelta;
    // // Total short delta
    // int shortDelta;
    // End of epoch PNL
    int pnl;
    // Queued withdrawals
    int withdrawalQueue;
    // Amount withdrawn
    int withdrawn;
  }

  struct EpochData {
    // Epoch expiry
    int expiry;
    // Average open price
    int averageOpenPrice;
    // Open Interest
    int oi;
    // Price at expiry
    int expiryPrice;
  }

  struct PerpPosition {
    // Is position open
    bool isOpen;
    // Is short position
    bool isShort;
    // Epoch
    uint epoch;
    // Open position count (in base asset)
    int positions;
    // Total size in asset
    int size;
    // Average open price
    int averageOpenPrice;
    // Margin provided
    int margin;
    // Premium for position
    int premium;
    // Fees for opening position
    int openingFees;
    // Fees for closing position
    int closingFees;
    // Funding for position
    int funding;
    // Final PNL of position
    int pnl;
    // Owner of perp position
    address owner;
  }

  struct LPPosition {
    // Is quote asset
    bool isQuote;
    // Amount of asset
    int amount;
    // Epoch
    uint epoch;
    // Is position set for withdraw. False if it's to be rolled over
    bool toWithdraw;
    // Epoch number if set to withdraw
    uint toWithdrawEpoch;
    // If withdrawn, true
    bool hasWithdrawn;
    // Owner of LP position
    address owner;
  }

  event Deposit(
    bool isQuote,
    int amount,
    uint epoch,
    address indexed user,
    uint indexed id
  );

  event OpenPerpPosition(
    bool isShort,
    int size,
    int collateralAmount,
    address indexed user,
    uint indexed id
  );

  event AddCollateralToPosition(
    uint indexed id,
    int amount,
    address indexed sender
  );

  event ClosePerpPosition(
    uint indexed id,
    int size,
    int pnl,
    address indexed user
  );

  event LiquidatePosition(
    uint indexed id,
    int margin,
    int price,
    int liquidationFee,
    address indexed liquidator
  );

  event InitWithdraw(
    uint id,
    address indexed user
  );

  event Withdraw(
    uint id,
    int finalSettleAmount,
    address indexed user
  );

  event ExpireEpoch(
    uint epoch,
    int expiryPrice
  );

  event Bootstrap(
    uint epoch,
    int expiryTimestamp
  );

  constructor(
    address _base,
    address _quote,
    address _optionPricing,
    address _volatilityOracle,
    address _priceOracle,
    address _gmxRouter
  ) {
    require(_base != address(0), "Invalid base token");
    require(_quote != address(0), "Invalid quote token");
    require(_optionPricing != address(0), "Invalid option pricing");
    require(_volatilityOracle != address(0), "Invalid volatility oracle");
    require(_priceOracle != address(0), "Invalid price oracle");
    base = IERC20(_base);
    quote = IERC20(_quote);
    optionPricing = IOptionPricing(_optionPricing);
    volatilityOracle = IVolatilityOracle(_volatilityOracle);
    priceOracle = IPriceOracle(_priceOracle);
    gmxRouter = IGmxRouter(_gmxRouter);

    lpPositionMinter   = new LPPositionMinter();
    perpPositionMinter = new PerpPositionMinter();

    base.approve(_gmxRouter, 2**256 - 1);
  }

  // Deposits are auto-rolled over to the next epoch unless withdraw is called
  function deposit(
    bool isQuote,
    uint amount
  ) external {
    uint nextEpoch = currentEpoch + 1;
    epochLpData[nextEpoch][isQuote].totalDeposits += int(amount);

    if (isQuote)
      quote.transferFrom(msg.sender, address(this), amount);
    else
      base.transferFrom(msg.sender, address(this), amount);

    uint id = lpPositionMinter.mint(msg.sender);

    lpPositions[id] = LPPosition({
      isQuote: isQuote,
      amount: int(amount),
      epoch: nextEpoch,
      toWithdraw: false,
      toWithdrawEpoch: 0,
      hasWithdrawn: false,
      owner: msg.sender
    });
    emit Deposit(
      isQuote,
      int(amount),
      nextEpoch,
      msg.sender,
      id
    );
  }

  // Inititate a withdrawal for end of epoch
  function initWithdraw(
    bool isQuote,
    int amount,
    uint id
  ) external
  {
    require(IERC721(lpPositionMinter).ownerOf(id) == msg.sender, "Invalid owner");
    require(!lpPositions[id].toWithdraw, "Already set for withdraw");
    require(!lpPositions[id].hasWithdrawn, "Already withdrawn");

    lpPositions[id].toWithdraw = true;

    epochLpData[currentEpoch + 1][isQuote].withdrawalQueue += amount;

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
    int finalLpAmountToWithdraw = _calcFinalLpAmount(id);
    require(finalLpAmountToWithdraw > 0);

    IERC20(lpPositions[id].isQuote ? quote : base).transfer(msg.sender, uint(finalLpAmountToWithdraw));

    // Update epoch LP data
    epochLpData[lpPositions[id].toWithdrawEpoch][lpPositions[id].isQuote].withdrawn += finalLpAmountToWithdraw;

    emit Withdraw(
      id,
      finalLpAmountToWithdraw,
      msg.sender
    );
  }

  // Safe convert to uint without overflow
  function _safeConvertToUint(int amountIn)
  private
  view
  returns (uint amountOut) {
    require(amountIn >= 0, "Overflow");
    amountOut = uint(amountIn);
  }

  // Calculates final LP amount for a LP position after accounting for PNL in an epoch
  function _calcFinalLpAmount(uint id)
  private
  view
  returns (int finalLpAmount)
  {
    // LP PNL for an epoch =
    bool isQuote = lpPositions[id].isQuote;
    uint epoch = lpPositions[id].toWithdrawEpoch;
    int amount = lpPositions[id].amount;
    int totalDeposits = epochLpData[epoch][isQuote].totalDeposits;
    int startingDeposits = epochLpData[epoch][isQuote].startingDeposits;

    require(startingDeposits > 0, "Invalid final lp amount");

    finalLpAmount = amount * totalDeposits / startingDeposits;
  }

  // Expires an epoch and bootstraps the next epoch
  function expireAndBootstrap(
    int nextExpiryTimestamp
  )
  external
  onlyOwner {
    uint nextEpoch = currentEpoch + 1;
    epochData[nextEpoch].expiry = nextExpiryTimestamp;
    if (currentEpoch > 0) {
      require(
        epochData[currentEpoch].expiry < int(block.timestamp),
        "Cannot bootstrap before the current epoch was expired"
      );
      require(
        nextExpiryTimestamp > epochData[currentEpoch].expiry,
        "Invalid next expiry timestamp"
      );

      // Get expiry price
      int expiryPrice = _getMarkPrice();
      epochData[currentEpoch].expiryPrice = expiryPrice;

      // long: long call, short put
      // short: long put, short call
      // Base LP: Call liquidity
      // Quote LP: Put liquidity

      // Calculate short LP payout from OI in quote asset for remaining positions
      // If expiry price > average open price, put writers have to pay out nothing
      // else, put writers payout = (avg. open price - exp) * oi/avg. open price
      // for example, exp: 500, avgOpen: 1000, oi: 1000
      // (1000 - 500) * 1000/500
      int quoteLpPayout;
      int baseLpPayout;

      if (expiryPrice > epochLpData[currentEpoch][true].averageOpenPrice) {
        quoteLpPayout = (epochLpData[currentEpoch][true].averageOpenPrice - expiryPrice) * epochLpData[currentEpoch][true].oi / epochLpData[currentEpoch][true].averageOpenPrice;
      }

      // Calculate long LP payout from OI in base asset for remaining positions
      if (epochLpData[currentEpoch][false].averageOpenPrice > expiryPrice) {
        baseLpPayout = (expiryPrice - epochLpData[currentEpoch][false].averageOpenPrice) / expiryPrice;
      }

      // exp: 1500, avgOpen: 1000, oi: 1000, (1500 - 1000) * 1500

      epochLpData[currentEpoch][true].pnl  -= baseLpPayout;
      epochLpData[currentEpoch][false].pnl -= quoteLpPayout;

      epochLpData[currentEpoch][true].totalDeposits  -= baseLpPayout;
      epochLpData[currentEpoch][false].totalDeposits -= quoteLpPayout;

      int nextEpochStartingDeposits = epochLpData[currentEpoch][true].totalDeposits -
      ( epochLpData[currentEpoch][true].withdrawalQueue *
        epochLpData[currentEpoch][true].totalDeposits /
        epochLpData[currentEpoch][true].startingDeposits
      );

      epochLpData[currentEpoch + 1][true].totalDeposits   += nextEpochStartingDeposits;
      epochLpData[currentEpoch + 1][true].startingDeposits = nextEpochStartingDeposits;

      epochLpData[currentEpoch + 1][false].totalDeposits   += nextEpochStartingDeposits;
      epochLpData[currentEpoch + 1][false].startingDeposits = nextEpochStartingDeposits;

      emit ExpireEpoch(
        currentEpoch,
        expiryPrice
      );
    }

    currentEpoch += 1;

    emit Bootstrap(
      currentEpoch,
      nextExpiryTimestamp
    );
  }

  // Open a new position
  // Long  - long call, short put.
  // Short - long put, short call.
  function openPosition(
    bool _isShort,
    int _size, // in USD (1e8)
    int _collateralAmount // in USD (1e6) collateral used to cover premium + funding + fees and write option
  ) external returns (uint id) {
    // Must not be epoch 0
    require(currentEpoch > 0, "Invalid epoch");
    // Check for expiry
    require(epochData[currentEpoch].expiry > int(block.timestamp), "Time must be before expiry");
    int _sizeInBase = _size * int(10 ** base.decimals()) / _getMarkPrice();
    console.log('Size in base');
    console.logInt(_sizeInBase);
    // Check if enough liquidity is available to open position
    require(
      (epochLpData[currentEpoch][_isShort].totalDeposits -
      epochLpData[currentEpoch][_isShort].activeDeposits) >=
      (_isShort ? _size : _sizeInBase),
      "Not enough liquidity to open position"
    );

    // Calculate premium for ATM option in USD
    // If is short, premium is in quote.decimals(). if long, base.decimals();
    int premium = _calculatePremium(_getMarkPrice(), _size);
    console.log('Premium');
    console.logInt(premium);

    // Calculate funding in USD
    int funding = _calculateFunding(_size, _collateralAmount);
    console.log('Funding');
    console.logInt(funding);

    // Calculate opening fees in USD
    int openingFees = _calculateFees(true, _size / 10 ** 2);
    console.log('Opening fees');
    console.logInt(openingFees);

    // Calculate closing fees in USD
    int closingFees = _calculateFees(false, _size / 10 ** 2);
    console.log('Closing fees');
    console.logInt(closingFees);

    // Calculate minimum collateral in USD
    int minCollateral = (premium * 2) + openingFees + closingFees + funding;
    console.log('Min collateral');
    console.logInt(minCollateral);

    // Check if collateral amount is sufficient for short side of trade and long premium
    require(
      _collateralAmount >= minCollateral,
      "Collateral must be greater than min. collateral"
    );

    // Number of positions (in 8 decimals)
    int positions = _size * divisor / _getMarkPrice();
    console.log('Positions');
    console.logInt(positions);

    // Update epoch LP data
    epochLpData[currentEpoch][_isShort].margin            += _collateralAmount;
    epochLpData[currentEpoch][_isShort].oi                += _size;
    epochLpData[currentEpoch][_isShort].premium           += premium;
    epochLpData[currentEpoch][_isShort].funding           += funding;
    epochLpData[currentEpoch][_isShort].openingFees       += openingFees;
    epochLpData[currentEpoch][_isShort].activeDeposits    += _size;
    epochLpData[currentEpoch][_isShort].positions         += positions;

    // epochLpData[currentEpoch][_isShort].longDelta   += (int)(size);
    // epochLpData[currentEpoch][!_isShort].shortDelta += (int)(size);

    if (epochLpData[currentEpoch][_isShort].averageOpenPrice == 0)
      epochLpData[currentEpoch][_isShort].averageOpenPrice  = _getMarkPrice();
    else
      epochLpData[currentEpoch][_isShort].averageOpenPrice  =
        epochLpData[currentEpoch][_isShort].oi /
        epochLpData[currentEpoch][_isShort].positions;

    // Transfer collateral from user
    quote.transferFrom(
        msg.sender,
        address(this),
        _safeConvertToUint(_collateralAmount)
      );

    // Generate perp position NFT
    id = perpPositionMinter.mint(msg.sender);
    perpPositions[id] = PerpPosition({
      isOpen: true,
      isShort: _isShort,
      positions: positions,
      epoch: currentEpoch,
      size: _size,
      averageOpenPrice: _getMarkPrice(),
      margin: _collateralAmount,
      premium: premium,
      openingFees: openingFees,
      closingFees: 0,
      funding: funding,
      pnl: 0,
      owner: msg.sender
    });

    // Emit open perp position event
    emit OpenPerpPosition(
      _isShort,
      _size,
      _collateralAmount,
      msg.sender,
      id
    );
  }

  // Calculate premium for longing an ATM option
  function _calculatePremium(
    int _strike,
    int _size
  )
  internal
  returns (int premium) {
    premium = (int(optionPricing.getOptionPrice(
        false, // ATM options: does not matter if call or put
        _safeConvertToUint(epochData[currentEpoch].expiry),
        _safeConvertToUint(_strike),
        _safeConvertToUint(_strike),
        _safeConvertToUint(getVolatility(_strike))
    )) * (_size / _strike));
    premium =
      premium / (divisor / int(10 ** quote.decimals()));
  }

  // Returns the volatility from the volatility oracle
  function getVolatility(int _strike)
  public
  view
  returns (int volatility) {
    volatility =
      int(volatilityOracle.getVolatility(
        uint(_strike)
      ));
  }

  // Calculate funding for opening a position until expiry
  function _calculateFunding(
    int _size, // in USD (1e8)
    int _collateralAmount // (ie6) in collateral used to write option. long = usd, short = eth
  )
  internal
  returns (int funding) {
    if (_collateralAmount > _size / 10 ** 2) {
      funding = 0;
    } else {
      int _borrowed = _size / 10 ** 2 - _collateralAmount;
      funding = ((_borrowed * fundingRate / (divisor * 100)) * (epochData[currentEpoch].expiry - int(block.timestamp))) / 365 days;
    }
  }

  // Calculate fees for opening a perp position
  function _calculateFees(
    bool _openingPosition,
    int _amount
  )
  internal
  view
  returns (int fees) {
    fees = (_amount * (_openingPosition ? feeOpenPosition : feeClosePosition)) / (100 * divisor);
  }

  // Returns price of base asset from oracle
  function _getMarkPrice()
  public
  view
  returns (int price) {
    price = int(priceOracle.getUnderlyingPrice());
  }

  // Add collateral to an existing position
  function addCollateral(
    uint id,
    int collateralAmount
  ) external {
    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    // Check if position is in current epoch
    require(perpPositions[id].epoch == currentEpoch, "Invalid epoch");
    epochLpData[currentEpoch][perpPositions[id].isShort].margin += collateralAmount;
    perpPositions[id].margin += collateralAmount;
    // Move collateral
    IERC20(quote).transferFrom(
      msg.sender,
      address(this),
      uint(collateralAmount)
    );
    emit AddCollateralToPosition(
      id,
      collateralAmount,
      msg.sender
    );
  }

  // Get value of an open perp position (1e6)
  function _getPositionValue(uint id)
  public
  view
  returns (int value) {
    value = perpPositions[id].positions * _getMarkPrice() / (divisor * 100);
  }

  // Get Pnl of an open perp position (1e6)
  function _getPositionPnl(uint id)
  public
  view
  returns (int value) {
    int positionValue = _getPositionValue(id);

    value = perpPositions[id].isShort ?
      (perpPositions[id].size / 10 ** 2) - positionValue :
      positionValue - (perpPositions[id].size / 10 ** 2);
  }

  // Get net margin of an open perp position (1e6)
  function _getPositionNetMargin(uint id)
  public
  view
  returns (int value) {
    int closingFees = _calculateFees(false, ((perpPositions[id].size / 10 ** 2) + _getPositionPnl(id)));
    value = perpPositions[id].margin - perpPositions[id].premium - perpPositions[id].openingFees - closingFees;
  }

  // Checks whether a position is sufficiently collateralized
  function _isPositionCollateralized(uint id)
  public
  returns (bool isCollateralized) {
    int pnl = _getPositionPnl(id);
    if (pnl > 0) isCollateralized = true;
    else {
      int netMargin = _getPositionNetMargin(id);
      netMargin -= netMargin * liquidationThreshold / (divisor * 100);
      isCollateralized = netMargin + pnl >= 0;
    }
  }

  // Close an existing position
  function closePosition(
    uint id,
    uint minAmountOut
  ) external {
    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    // Sender must be owner of position
    require(perpPositions[id].owner == msg.sender, "Invalid sender");
    // Check if position is in current epoch
    require(perpPositions[id].epoch == currentEpoch, "Invalid epoch");
    // Position must be sufficiently collateralized
    require(_isPositionCollateralized(id), "Position is not collateralized");

    // Calculate pnl
    int pnl = _getPositionPnl(id);
    // Settle option positions
    bool isShort = perpPositions[id].isShort;

    epochLpData[currentEpoch][isShort].margin -= perpPositions[id].margin;
    epochLpData[currentEpoch][isShort].activeDeposits -= perpPositions[id].size;
    epochLpData[currentEpoch][isShort].totalDeposits += perpPositions[id].size - pnl;
    epochLpData[currentEpoch][isShort].pnl -= pnl;
    epochLpData[currentEpoch][isShort].oi -= perpPositions[id].size;

    epochLpData[currentEpoch][isShort].averageOpenPrice  =
      epochLpData[currentEpoch][isShort].oi /
      epochLpData[currentEpoch][isShort].positions;

    epochLpData[currentEpoch][isShort].positions -= perpPositions[id].positions;

    // epochLpData[currentEpoch][isShort].longDelta -= (int)(perpPositions[id].size);
    // epochLpData[currentEpoch][!isShort].shortDelta -= (int)(perpPositions[id].size);

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = pnl;

    uint amountOut;

    // Transfer collateral + PNL to user
    if (perpPositions[id].isShort) {
      amountOut = uint(perpPositions[id].margin + pnl);
      require(amountOut >= minAmountOut, "Amount out is not enough");
    } else {
      // Convert collateral + PNL to quote and send to user
      int amountIn = perpPositions[id].margin + pnl;
      address[] memory path;

      path = new address[](2);
      path[0] = address(base);
      path[1] = address(quote);

      uint initialAmountOut = quote.balanceOf(address(this));
      gmxRouter.swap(path, uint(amountIn), minAmountOut, address(this));
      amountOut = quote.balanceOf(address(this)) - initialAmountOut;
    }

    IERC20(quote).
        transfer(
          perpPositions[id].owner,
          amountOut
        );

    emit ClosePerpPosition(
      id,
      perpPositions[id].size,
      pnl,
      msg.sender
    );
  }

  // Liquidate a position passed the liquidation threshold
  function liquidate(
    uint id
  ) external {
    // Check if position is not sufficiently collateralized
    require(!_isPositionCollateralized(id), "Position has enough collateral");

    bool isShort = perpPositions[id].isShort;
    int liquidationFee = perpPositions[id].margin * feeLiquidation / divisor;

    epochLpData[currentEpoch][isShort].margin -= perpPositions[id].margin;
    epochLpData[currentEpoch][isShort].activeDeposits -= perpPositions[id].size;
    epochLpData[currentEpoch][isShort].totalDeposits += perpPositions[id].size + perpPositions[id].margin - liquidationFee;
    epochLpData[currentEpoch][isShort].oi -= perpPositions[id].size;
    epochLpData[currentEpoch][isShort].positions -= perpPositions[id].positions;

    epochLpData[currentEpoch][isShort].averageOpenPrice  =
      epochLpData[currentEpoch][isShort].oi /
      epochLpData[currentEpoch][isShort].positions;

    // epochLpData[currentEpoch][isShort].longDelta -= (int)(perpPositions[id].size);
    // epochLpData[currentEpoch][!isShort].shortDelta -= (int)(perpPositions[id].size);

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = -1 * perpPositions[id].margin;

    // Transfer liquidation fee to sender
    IERC20(perpPositions[id].isShort ? quote : base).
      transfer(
        msg.sender,
        uint(liquidationFee)
      );

    emit LiquidatePosition(
      id,
      perpPositions[id].margin,
      _getMarkPrice(),
      liquidationFee,
      msg.sender
    );
  }

}
