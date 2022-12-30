// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {ILpPositionMinter} from "./interface/ILpPositionMinter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PerpPositionMinter} from "./positions/PerpPositionMinter.sol";
import {OptionPositionMinter} from "./positions/OptionPositionMinter.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IGmxRouter} from "./interface/IGmxRouter.sol";
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";

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
// - 2 pools - eth / usdc  - single-sided liquidity. Lower liquidity side earns more fees. Incentivizes re-balancing to 50/50 target.
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

  ILpPositionMinter public quoteLpPositionMinter;
  ILpPositionMinter public baseLpPositionMinter;
  PerpPositionMinter public perpPositionMinter;
  OptionPositionMinter public optionPositionMinter;

  IGmxRouter public gmxRouter;
  IUniswapV3Router public uniV3Router;
  
  int public expiry;
  int public epoch;

  uint public withdrawalRequestsCounter;

  mapping (bool => EpochLPData) public epochLpData;
  mapping (uint => PerpPosition) public perpPositions;
  mapping (uint => OptionPosition) public optionPositions;
  mapping (uint => PendingWithdrawal) public pendingWithdrawals;

  // epoch => expiryPrice
  mapping (int => int) public expiryPrices;

  int public divisor                = 1e8;
  int public minFundingRate         = 3650000000; // 36.5% annualized (0.1% a day)
  int public maxFundingRate         = 365000000000; // 365% annualized (1% a day)
  int public feeOpenPosition        = 5000000; // 0.05%
  int public feeClosePosition       = 5000000; // 0.05%
  int public feeLiquidation         = 50000000; // 0.5%
  int public liquidationThreshold   = 500000000; // 5%

  uint internal constant MAX_UINT = 2**256 - 1;

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

  struct PerpPosition {
    // Is position open
    bool isOpen;
    // Is short position
    bool isShort;
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
    // Opened at timestamp
    uint openedAt;
  }

  struct PendingWithdrawal {
    // lp token amount
    int amountIn;
    // min amount of underlying token accepted after fees
    int minAmountOut;
    // is quote?
    bool isQuote;
    // percentage of amountOut paid to bot which fullfil the request
    int priorityFee;
    // user who withdraws
    address user;
  }

  struct OptionPosition {
    // Is position open
    bool isOpen;
    // Is put
    bool isPut;
    // Total amount
    int amount;
    // Strike price
    int strike;
  }

  event Deposit(
    bool isQuote,
    uint amountIn,
    uint amountOut,
    address indexed user
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

  event ReduceCollateralToPosition(
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

  event Withdraw(
    int amountIn,
    int amountOut,
    bool isQuote,
    int amountOutFees,
    address resolver,
    address indexed user
  );

   event RequestWithdraw(
    uint indexed id,
    int amountIn,
    bool isQuote,
    int minAmountOut,
    int priorityFee,
    address indexed user
  );

  constructor(
    address _base,
    address _quote,
    address _optionPricing,
    address _volatilityOracle,
    address _priceOracle,
    address _gmxRouter,
    address _uniV3Router,
    address _quoteLpPositionMinter,
    address _baseLpPositionMinter,
    int _expiry
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
    uniV3Router = IUniswapV3Router(_uniV3Router);
    gmxRouter = IGmxRouter(_gmxRouter);
    expiry = _expiry;

    quoteLpPositionMinter = ILpPositionMinter(_quoteLpPositionMinter);
    baseLpPositionMinter = ILpPositionMinter(_baseLpPositionMinter);
    perpPositionMinter = new PerpPositionMinter();
    optionPositionMinter = new OptionPositionMinter();

    base.approve(_gmxRouter, MAX_UINT);
    base.approve(_uniV3Router, MAX_UINT);
  }

  function _swapUsingUniV3ExactIn(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut,
        uint24 fees
    ) internal returns (uint256 amountOut) {
      IUniswapV3Router.ExactInputSingleParams
          memory swapParams = IUniswapV3Router.ExactInputSingleParams(
              from,
              to,
              fees,
              address(this),
              block.timestamp,
              amountIn,
              minAmountOut,
              0
          );

      amountOut = uniV3Router.exactInputSingle(swapParams);
  }

  function _swapUsingUniV3ExactOut(
        address from,
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint24 fees
    ) internal returns (uint256 amountIn) {
      IUniswapV3Router.ExactOutputSingleParams
          memory swapParams = IUniswapV3Router.ExactOutputSingleParams(
              from,
              to,
              fees,
              address(this),
              block.timestamp,
              amountOut,
              maxAmountIn,
              0
          );

      amountIn = uniV3Router.exactOutputSingle(swapParams);
  }

  function _getTotalSupply(bool isQuote) internal view returns (int totalSupply) {
    totalSupply = int(isQuote ? quoteLpPositionMinter.totalSupply() : baseLpPositionMinter.totalSupply());
  }

  function deposit(
    bool isQuote,
    uint amountIn
  ) external {
    uint amountOut = _safeConvertToUint(_calcLpAmount(isQuote, int(amountIn)));
    epochLpData[isQuote].totalDeposits += int(amountIn);

    console.log('TOTAL DEPOSIT NOW');
    console.logInt(epochLpData[isQuote].totalDeposits);

    console.log("AMOUNT OUT");
    console.log(amountOut);

    if (isQuote) {
      quote.transferFrom(msg.sender, address(this), amountIn);
      quoteLpPositionMinter.mintFromOptionPerp(msg.sender, amountOut);
    } else {
      base.transferFrom(msg.sender, address(this), amountIn);
      baseLpPositionMinter.mintFromOptionPerp(msg.sender, amountOut);
    }

    emit Deposit(
      isQuote,
      amountIn,
      amountOut,
      msg.sender
    );
  }

  // Initiate withdrawal request
  function openWithdrawalRequest(
    bool isQuote,
    int amountIn,
    int minAmountOut,
    int priorityFee
  ) public returns (uint id)
  {
    uint lpAmount;

    if (isQuote) {
      lpAmount = quoteLpPositionMinter.balanceOf(msg.sender);
    } else {
      lpAmount = baseLpPositionMinter.balanceOf(msg.sender);
    }

    require(lpAmount >= _safeConvertToUint(amountIn), "Insufficient LP token amount");

    console.log("LP AMOUNT");
    console.log(lpAmount);
    console.log("AMOUNT IN");
    console.logInt(amountIn);

    pendingWithdrawals[withdrawalRequestsCounter] = PendingWithdrawal({
      amountIn: amountIn,
      minAmountOut: minAmountOut,
      isQuote: isQuote,
      priorityFee: priorityFee,
      user: msg.sender
    });

    emit RequestWithdraw(
      withdrawalRequestsCounter,
      amountIn,
      isQuote,
      minAmountOut,
      priorityFee,
      msg.sender
    );

    withdrawalRequestsCounter += 1;

    id = withdrawalRequestsCounter - 1;

    console.log('ID TO WITHDRAW');
    console.log(id);
  }

  // Fulfill withdrawal request
  function completeWithdrawalRequest(
    uint id
  ) public returns (int amountOut, int amountOutFees)
  {
    PendingWithdrawal memory pendingWithdrawal = pendingWithdrawals[id];

    require(pendingWithdrawal.user != address(0), "Invalid id");

    int available = epochLpData[pendingWithdrawal.isQuote].totalDeposits - epochLpData[pendingWithdrawal.isQuote].activeDeposits;

    int totalSupply = _getTotalSupply(pendingWithdrawal.isQuote);

    console.log("AMOUNT TO BURN");
    console.logInt(pendingWithdrawal.amountIn);

    if (pendingWithdrawal.isQuote) {
      quoteLpPositionMinter.burnFromOptionPerp(pendingWithdrawal.user, _safeConvertToUint(pendingWithdrawal.amountIn));

      console.log('IS QUOTE');
      console.log('AMOUNT IN');
      console.logInt(pendingWithdrawal.amountIn);
      console.log('AVAILABLE');
      console.logInt(available);
      console.log('TOTAL SUPPLY');
      console.logInt(_getTotalSupply(pendingWithdrawal.isQuote));

      amountOut = (pendingWithdrawal.amountIn * epochLpData[pendingWithdrawal.isQuote].totalDeposits) / totalSupply;
      require(amountOut <= available, "Insufficient liquidity");

      quote.transfer(pendingWithdrawal.user, _safeConvertToUint(amountOut - pendingWithdrawal.priorityFee));
      quote.transfer(msg.sender, _safeConvertToUint(pendingWithdrawal.priorityFee));
    } else {
      baseLpPositionMinter.burnFromOptionPerp(pendingWithdrawal.user, _safeConvertToUint(pendingWithdrawal.amountIn));

      console.log('AMOUNT IN');
      console.logInt(pendingWithdrawal.amountIn);
      console.log('AVAILABLE');
      console.logInt(available);
      console.log('TOTAL SUPPLY');
      console.logInt(_getTotalSupply(pendingWithdrawal.isQuote));

      amountOut = (pendingWithdrawal.amountIn * epochLpData[pendingWithdrawal.isQuote].totalDeposits) / totalSupply;
      require(amountOut <= available, "Insufficient liquidity");

      base.transfer(pendingWithdrawal.user, _safeConvertToUint(amountOut - pendingWithdrawal.priorityFee));
      base.transfer(msg.sender, _safeConvertToUint(pendingWithdrawal.priorityFee));
    }

    require(amountOut - pendingWithdrawal.priorityFee >= pendingWithdrawal.minAmountOut, "Insufficient amount out");

    console.log('AMOUNT OUT');
    console.logInt(amountOut);

    amountOutFees = pendingWithdrawal.priorityFee;

    delete pendingWithdrawals[id];

    emit Withdraw(
      pendingWithdrawal.amountIn,
      amountOut - pendingWithdrawal.priorityFee,
      pendingWithdrawal.isQuote,
      pendingWithdrawal.priorityFee,
      msg.sender,
      pendingWithdrawal.user
    );
  }

  // Open withdrawal request and fullfill it immediately
  function withdraw(
    bool isQuote,
    int amountIn,
    int minAmountOut
  ) external returns (int amountOut)
  {
    uint id = openWithdrawalRequest(isQuote, amountIn, minAmountOut, 0);
    (amountOut, ) = completeWithdrawalRequest(id);
  }

  // Safe convert to uint without overflow
  function _safeConvertToUint(int amountIn)
  private
  view
  returns (uint amountOut) {
    require(amountIn >= 0, "Overflow");
    amountOut = uint(amountIn);
  }

  function _calcLpAmount(
  bool isQuote,
  int amountIn
  )
  private
  view
  returns (int amountOut)
  {
    int currentPrice = _getMarkPrice();

    // unrealizedPnl is ie6
    int unrealizedPnl = ((currentPrice - epochLpData[isQuote].averageOpenPrice) * (epochLpData[isQuote].positions / 10 ** 2)) / divisor;

    // totalDeposits is ie6
    int deposits = epochLpData[isQuote].totalDeposits - unrealizedPnl;

    console.log('Total Deposits');
    console.logInt(epochLpData[isQuote].totalDeposits);

    console.log('Unrealized pnl');
    console.logInt(unrealizedPnl);

    console.log('Deposits');
    console.logInt(deposits);

    console.log('Amount in');
    console.logInt(amountIn);

    console.log('Total supply');
    console.logInt(_getTotalSupply(isQuote));

    if (deposits == 0) amountOut = amountIn;
    else amountOut = (amountIn * _getTotalSupply(isQuote)) / (epochLpData[isQuote].totalDeposits);

    console.log('Amount out');
    console.logInt(amountOut);
  }

  // Update expiry and epoch
  function updateEpoch(
    int nextExpiryTimestamp
  )
  external
  onlyOwner {
    require(int(block.timestamp) <= expiry, "Too soon");

    expiry = nextExpiryTimestamp;
    expiryPrices[epoch] = _getMarkPrice();
    epoch += 1;
  }

  // Open a new position
  // Long  - long call, short put.
  // Short - long put, short call.
  function openPosition(
    bool _isShort,
    int _size, // in USD (1e8)
    int _collateralAmount // in USD (1e6) collateral used to cover premium + funding + fees and write option
  ) public returns (uint id) {
    int _sizeInBase = _size * int(10 ** base.decimals()) / _getMarkPrice();
    // Check if enough liquidity is available to open position
    require(
      (epochLpData[_isShort].totalDeposits -
      epochLpData[_isShort].activeDeposits) >=
      (_isShort ? _size / 10 ** 2 : _sizeInBase),
      "Not enough liquidity to open position"
    );

    // Calculate premium for ATM option in USD
    // If is short, premium is in quote.decimals(). if long, base.decimals();
    int premium = _calcPremium(_getMarkPrice(), _size);

    // Calculate opening fees in USD
    int openingFees = _calcFees(true, _size / 10 ** 2);
    console.log('Opening fees');
    console.logInt(openingFees);

    // Calculate closing fees in USD
    int closingFees = _calcFees(false, _size / 10 ** 2);
    console.log('Closing fees');
    console.logInt(closingFees);

    // Calculate minimum collateral in USD
    int minCollateral = (premium * 2) + openingFees + closingFees;
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
    epochLpData[_isShort].margin            += _collateralAmount;
    epochLpData[_isShort].oi                += _size;
    epochLpData[_isShort].premium           += premium;
    epochLpData[_isShort].openingFees       += openingFees;
    epochLpData[_isShort].activeDeposits    += _size / 10 ** 2;
    epochLpData[_isShort].positions         += positions;

    // epochLpData[_isShort].longDelta   += (int)(size);
    // epochLpData[!_isShort].shortDelta += (int)(size);

    if (epochLpData[_isShort].averageOpenPrice == 0)
      epochLpData[_isShort].averageOpenPrice  = _getMarkPrice();
    else
      epochLpData[_isShort].averageOpenPrice  =
        epochLpData[_isShort].oi /
        epochLpData[_isShort].positions;

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
      size: _size,
      averageOpenPrice: _getMarkPrice(),
      margin: _collateralAmount,
      premium: premium,
      openingFees: openingFees,
      closingFees: 0,
      funding: 0,
      pnl: 0,
      openedAt: block.timestamp
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

  // Update position size maintaining same side, can be used to increase or decrease
  function changePositionSize(
    uint id,
    int _size, // in USD (1e8)
    int _collateralAmount, // in USD (1e6) collateral used to cover premium + funding + fees and write option
    uint _minAmountOut // to avoid frontrunning
  ) external returns (uint amountOut) {
    bool isShort = perpPositions[id].isShort;
    int originalSize = perpPositions[id].size;
    amountOut = closePosition(id, _minAmountOut);

    openPosition(isShort, _size, _collateralAmount);
  }

  // Calculate premium for longing an ATM option
  function _calcPremium(
    int _strike,
    int _size
  )
  internal
  returns (int premium) {
    premium = (int(optionPricing.getOptionPrice(
        false, // ATM options: does not matter if call or put
        _safeConvertToUint(expiry),
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
        _safeConvertToUint(_strike)
      ));
  }

  // Calculate fees for opening a perp position
  function _calcFees(
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
    epochLpData[perpPositions[id].isShort].margin += collateralAmount;
    perpPositions[id].margin += collateralAmount;
    // Move collateral
    IERC20(quote).transferFrom(
      msg.sender,
      address(this),
      _safeConvertToUint(collateralAmount)
    );
    emit AddCollateralToPosition(
      id,
      collateralAmount,
      msg.sender
    );
  }

  // Reduce collateral from an existing position
  function reduceCollateral(
    uint id,
    int collateralAmount
  ) external {
    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    epochLpData[perpPositions[id].isShort].margin -= collateralAmount;
    perpPositions[id].margin -= collateralAmount;

    require(_isPositionCollateralized(id), "Amount to withdraw is too big");

    // Move collateral
    IERC20(quote).transfer(
       msg.sender,
      _safeConvertToUint(collateralAmount)
    );

    emit ReduceCollateralToPosition(
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

  // Get funding of an open perp position (1e6)
  function _getPositionFunding(uint id)
  public
  view
  returns (int funding) {
    int markPrice = _getMarkPrice() / 10 ** 2;
    int shortOiInUsd = epochLpData[true].oi * markPrice / divisor; // ie6
    int longOiInUsd = epochLpData[false].oi * markPrice / divisor; // ie6

    int fundingRate = minFundingRate;

    if (shortOiInUsd > 0) {
      int longShortRatio = divisor * longOiInUsd / shortOiInUsd;
      int longFunding;

      if (longShortRatio > divisor) longFunding = maxFundingRate;
      else longFunding = ((maxFundingRate - minFundingRate) * (longShortRatio)) / (divisor);

      fundingRate = perpPositions[id].isShort ? -1 * longFunding :  longFunding;
    }

    // size is ie8
    // margin is ie6
    // _borrowed is ie6
    int _borrowed = perpPositions[id].size / 10 ** 2 - perpPositions[id].margin;
    funding = ((_borrowed * fundingRate / (divisor * 100)) * int(block.timestamp - perpPositions[id].openedAt)) / 365 days;
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
    int closingFees = _calcFees(false, ((perpPositions[id].size / 10 ** 2) + _getPositionPnl(id)));
    value = perpPositions[id].margin - perpPositions[id].premium - perpPositions[id].openingFees - closingFees - _getPositionFunding(id);
  }

  // Get liquidation price (1e8)
  function _getPositionLiquidationPrice(uint id)
  public
  view
  returns (int price) {
    int netMargin = _getPositionNetMargin(id);
    netMargin -= netMargin * liquidationThreshold / (divisor * 100);

    if (perpPositions[id].isShort) {
      price = (divisor * (perpPositions[id].size) / perpPositions[id].positions) + (divisor * (netMargin * 10 ** 2) / perpPositions[id].positions);
    } else {
      price = (divisor * (perpPositions[id].size) / perpPositions[id].positions) - (divisor * (netMargin * 10 ** 2) / perpPositions[id].positions);
    }
  }

  // Checks whether a position is sufficiently collateralized
  function _isPositionCollateralized(uint id)
  public
  view
  returns (bool isCollateralized) {
    int pnl = _getPositionPnl(id);
    int netMargin = _getPositionNetMargin(id);
    netMargin -= netMargin * liquidationThreshold / (divisor * 100);
    isCollateralized = netMargin + pnl >= 0;
  }

  // Close an existing position
  function closePosition(
    uint id,
    uint minAmountOut
  ) public returns (uint amountOut) {
    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    // Sender must be owner of position
    require(perpPositionMinter.ownerOf(id) == msg.sender, "Invalid sender");
    // Position must be sufficiently collateralized
    require(_isPositionCollateralized(id), "Position is not collateralized");

    // Calculate pnl
    int pnl = _getPositionPnl(id);
    // Settle option positions
    bool isShort = perpPositions[id].isShort;
    // Calculate funding
    int funding = _getPositionFunding(id);
    // Calculate closing fees
    int closingFees = _calcFees(false, ((perpPositions[id].size / 10 ** 2) + pnl));

    epochLpData[isShort].margin -= perpPositions[id].margin;
    epochLpData[isShort].activeDeposits -= perpPositions[id].size / 10 ** 2;

    console.logInt(epochLpData[isShort].totalDeposits);
    epochLpData[isShort].totalDeposits += - pnl + funding + closingFees;

    epochLpData[isShort].oi -= perpPositions[id].size;

    epochLpData[isShort].averageOpenPrice  =
      epochLpData[isShort].oi /
      epochLpData[isShort].positions;

    epochLpData[isShort].positions -= perpPositions[id].positions;

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = pnl;
    perpPositions[id].funding = funding;
    perpPositions[id].closingFees = closingFees;

    int toTransfer = perpPositions[id].margin + pnl - perpPositions[id].premium - perpPositions[id].openingFees - perpPositions[id].closingFees - perpPositions[id].funding;

    if (toTransfer > 0) {
      amountOut = _safeConvertToUint(toTransfer);
      require(amountOut >= minAmountOut, "Amount out is not enough");

      if (!perpPositions[id].isShort) {
        // Convert collateral + PNL to quote and send to user
        _swapUsingUniV3ExactOut(address(base), address(quote), amountOut, MAX_UINT, 500);
      }

      quote.transfer(perpPositionMinter.ownerOf(id), amountOut);
    }

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

    epochLpData[isShort].margin -= perpPositions[id].margin;
    epochLpData[isShort].activeDeposits -= perpPositions[id].size;
    epochLpData[isShort].totalDeposits += perpPositions[id].size + perpPositions[id].margin - liquidationFee;
    epochLpData[isShort].oi -= perpPositions[id].size;
    epochLpData[isShort].positions -= perpPositions[id].positions;

    epochLpData[isShort].averageOpenPrice  =
      epochLpData[isShort].oi /
      epochLpData[isShort].positions;

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = -1 * perpPositions[id].margin;

    // Transfer liquidation fee to sender
    IERC20(perpPositions[id].isShort ? quote : base).
      transfer(
        msg.sender,
        _safeConvertToUint(liquidationFee)
      );

    // Mint option for liquidated user
    // PUT if isShort, CALL if not
    id = optionPositionMinter.mint(optionPositionMinter.ownerOf(id));
    optionPositions[id] = OptionPosition({
      isOpen: true,
      isPut: isShort,
      amount: perpPositions[id].positions,
      strike: perpPositions[id].averageOpenPrice
    });

    emit LiquidatePosition(
      id,
      perpPositions[id].margin,
      _getMarkPrice(),
      liquidationFee,
      msg.sender
    );
  }
}
