pragma solidity ^0.4.23;


import "kuende-token/contracts/KuendeToken.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";


/**
 * @title KuendeCrowdsale
 * @dev Inspired by: https://github.com/OpenZeppelin/zeppelin-solidity/tree/master/contracts/crowdsale
 */
contract KuendeCrowdsale is Ownable {
  using SafeMath for uint256;

  /**
   * @dev event for change wallet address logging
   * @param newWallet address that got set
   * @param oldWallet address that was changed from
   */
  event ChangedWalletAddress(address indexed newWallet, address indexed oldWallet);
  
  /**
   * @dev event for token purchase logging
   * @param investor who purchased tokens
   * @param value weis paid for purchase
   * @param amount of tokens purchased
   */
  event TokenPurchase(address indexed investor, uint256 value, uint256 amount);

  // definition of an Investor
  struct Investor {
    uint256 weiBalance;    // Amount of invested wei (0 for PreInvestors)
    uint256 tokenBalance;  // Amount of owned tokens
    bool whitelisted;      // Flag for marking an investor as whitelisted
    bool purchasing;       // Lock flag
  }

  // start and end timestamps where investments are allowed (both inclusive)
  uint256 public startTime;
  uint256 public endTime;

  // address that can whitelist new investors
  address public registrar;

  // wei to token exchange rate
  uint256 public exchangeRate;

  // address where funds are collected
  address public wallet;

  // token contract
  KuendeToken public token;

  // crowdsale sale cap
  uint256 public cap;

  // crowdsale investor cap
  uint256 public investorCap;

  // minimum investment
  uint256 public constant minInvestment = 100 finney;

  // gas price limit. 100 gwei.
  uint256 public constant gasPriceLimit = 1e11 wei;

  // amount of raised money in wei
  uint256 public weiRaised;

  // storage for the investors repository
  uint256 public numInvestors;
  mapping (address => Investor) public investors;

  /**
   * @dev Create a new instance of the KuendeCrowdsale contract
   * @param _startTime     uint256 Crowdsale start time timestamp in unix format.
   * @param _endTime       uint256 Crowdsale end time timestamp in unix format.
   * @param _cap           uint256 Hard cap in wei.
   * @param _exchangeRate  uint256 1 token value in wei.
   * @param _registrar     address Address that can whitelist investors.
   * @param _wallet        address Address of the wallet that will collect the funds.
   * @param _token         address Token smart contract address.
   */
  constructor (
    uint256 _startTime,
    uint256 _endTime,
    uint256 _cap,
    uint256 _exchangeRate,
    address _registrar,
    address _wallet,
    address _token
  )
    public
  {
    // validate parameters
    require(_startTime > now);
    require(_endTime > _startTime);
    require(_cap > 0);
    require(_exchangeRate > 0);
    require(_registrar != address(0));
    require(_wallet != address(0));
    require(_token != address(0));

    // update storage
    startTime = _startTime;
    endTime = _endTime;
    cap = _cap;
    exchangeRate = _exchangeRate;
    registrar = _registrar;
    wallet = _wallet;
    token = KuendeToken(_token);
  }

  /**
   * @dev Ensure the crowdsale is not started
   */
  modifier notStarted() { 
    require(now < startTime);
    _;
  }

  /**
   * @dev Ensure the crowdsale is not notEnded
   */
  modifier notEnded() { 
    require(now < endTime);
    _;
  }
  
  /**
   * @dev Fallback function can be used to buy tokens
   */
  function () external payable {
    buyTokens();
  }

  /**
   * @dev Change the wallet address
   * @param _wallet address
   */
  function changeWalletAddress(address _wallet) external notStarted onlyOwner {
    // validate call against the rules
    require(_wallet != address(0));
    require(_wallet != wallet);

    // update storage
    address _oldWallet = wallet;
    wallet = _wallet;

    // trigger event
    emit ChangedWalletAddress(_wallet, _oldWallet);
  }

  /**
   * @dev Whitelist multiple investors at once
   * @param addrs address[]
   */
  function whitelistInvestors(address[] addrs) external {
    require(addrs.length > 0 && addrs.length <= 30);
    for (uint i = 0; i < addrs.length; i++) {
      whitelistInvestor(addrs[i]);
    }
  }

  /**
   * @dev Whitelist a new investor
   * @param addr address
   */
  function whitelistInvestor(address addr) public notEnded {
    require((msg.sender == registrar || msg.sender == owner) && !limited());
    if (!investors[addr].whitelisted && addr != address(0)) {
      investors[addr].whitelisted = true;
      numInvestors++;
    }
  }

  /**
   * @dev Low level token purchase function
   */
  function buyTokens() public payable {
    // update investor cap.
    updateInvestorCap();

    address investor = msg.sender;

    // validate purchase    
    validPurchase();

    // lock investor account
    investors[investor].purchasing = true;

    // get the msg wei amount
    uint256 weiAmount = msg.value.sub(refundExcess());

    // value after refunds should be greater or equal to minimum investment
    require(weiAmount > 0);

    // calculate token amount to be sold
    uint256 tokens = weiAmount.mul(1 ether).div(exchangeRate);

    // update storage
    weiRaised = weiRaised.add(weiAmount);
    investors[investor].weiBalance = investors[investor].weiBalance.add(weiAmount);
    investors[investor].tokenBalance = investors[investor].tokenBalance.add(tokens);

    // transfer tokens
    require(transfer(investor, tokens));

    // trigger event
    emit TokenPurchase(msg.sender, weiAmount, tokens);

    // forward funds
    wallet.transfer(weiAmount);

    // unlock investor account
    investors[investor].purchasing = false;
  }

  /**
  * @dev Update the investor cap.
  */
  function updateInvestorCap() internal {
    require(now >= startTime);

    if (investorCap == 0) {
      investorCap = cap.div(numInvestors);
    }
  }

  /**
   * @dev Wrapper over token's transferFrom function. Ensures the call is valid.
   * @param  to    address
   * @param  value uint256
   * @return bool
   */
  function transfer(address to, uint256 value) internal returns (bool) {
    if (!(
      token.allowance(owner, address(this)) >= value &&
      token.balanceOf(owner) >= value &&
      token.crowdsale() == address(this)
    )) {
      return false;
    }
    return token.transferFrom(owner, to, value);
  }
  
  /**
   * @dev Refund the excess weiAmount back to the investor so the caps aren't reached
   * @return uint256 the weiAmount after refund
   */
  function refundExcess() internal returns (uint256 excess) {
    uint256 weiAmount = msg.value;
    address investor = msg.sender;

    // calculate excess for investorCap
    if (limited() && !withinInvestorCap(investor, weiAmount)) {
      excess = investors[investor].weiBalance.add(weiAmount).sub(investorCap);
      weiAmount = msg.value.sub(excess);
    }

    // calculate excess for crowdsale cap
    if (!withinCap(weiAmount)) {
      excess = excess.add(weiRaised.add(weiAmount).sub(cap));
      weiAmount = msg.value.sub(excess);
    }
    
    // refund and update weiAmount
    if (excess > 0) {
      investor.transfer(excess);
    }
  }

  /**
   * @dev Validate the purchase. Reverts if purchase is invalid
   */
  function validPurchase() internal view {
    require (msg.sender != address(0));           // valid investor address
    require (tx.gasprice <= gasPriceLimit);       // tx gas price doesn't exceed limit
    require (!investors[msg.sender].purchasing);  // investor not already purchasing
    require (startTime <= now && now <= endTime); // within crowdsale period
    require (investorCap != 0);                   // investor cap initialized
    require (msg.value >= minInvestment);         // value should exceed or be equal to minimum investment
    require (whitelisted(msg.sender));            // check if investor is whitelisted
    require (withinCap(0));                       // check if purchase is within cap
    require (withinInvestorCap(msg.sender, 0));   // check if purchase is within investor cap
  }

  /**
   * @dev Check if by adding the provided _weiAmomunt the cap is not exceeded
   * @param weiAmount uint256
   * @return bool
   */
  function withinCap(uint256 weiAmount) internal view returns (bool) {
    return weiRaised.add(weiAmount) <= cap;
  }

  /**
   * @dev Check if by adding the provided weiAmount to investor's account the investor
   *      cap is not excedeed
   * @param investor  address
   * @param weiAmount uint256
   * @return bool
   */
  function withinInvestorCap(address investor, uint256 weiAmount) internal view returns (bool) {
    return limited() ? investors[investor].weiBalance.add(weiAmount) <= investorCap : true;
  }

  /**
   * @dev Check if the given address is whitelisted for token purchases
   * @param investor address
   * @return bool
   */
  function whitelisted(address investor) internal view returns (bool) {
    return investors[investor].whitelisted;
  }

  /**
   * @dev Check if the crowdsale is limited
   * @return bool
   */
  function limited() internal view returns (bool) {
    return  startTime <= now && now < startTime.add(1 days);
  }
}
