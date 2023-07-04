pragma solidity ^0.8.20;
// SPDX-License-Identifier: UNLICENSED

// WEBSITE: DIGITALDUMPSTER.XYZ
// TWITTER: @TRASHCOINETH

import "./MerkleProof.sol";
import "./ReentrancyGuard.sol";
import "./SafeMath.sol";
import "./IERC20.sol";

abstract contract Context {
  function _msgSender() internal view virtual returns (address payable) {
    return payable(msg.sender);
  }

  function _msgData() internal view virtual returns (bytes memory) {
    this;
    return msg.data;
  }
}

contract Ownable is Context {
  address private _owner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  constructor() {
    address msgSender = _msgSender();
    _owner = msgSender;
    emit OwnershipTransferred(address(0), msgSender);
  }

  function owner() public view returns (address) {
    return _owner;
  }

  modifier onlyOwner() {
    require(_owner == _msgSender(), "Ownable: caller is not the owner");
    _;
  }

  function transferOwnership(address newOwner) public virtual onlyOwner {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    emit OwnershipTransferred(_owner, newOwner);
    _owner = newOwner;
  }
}

struct SaleNumbers {
  uint256 ico;
  uint256 privateRound;
}

contract DigitalDumpsterPreSale is ReentrancyGuard, Ownable {
  using SafeMath for uint256;

  mapping(address => uint256) public _contributions;
  mapping(address => uint256) public claimedTokens;
  mapping(address => uint256) public lastClaimed;

  IERC20 public _token;
  uint256 private _tokenDecimals;
  address payable public _wallet;
  uint256 public startDate;
  uint256 public startICODate;
  uint256 public _weiRaised;

  SaleNumbers public minPurchase = SaleNumbers({ ico: 0.05 ether, privateRound: 0.05 ether });
  SaleNumbers public maxPurchase = SaleNumbers({ ico: 0.5 ether, privateRound: 0.5 ether });

  uint256 public softCap = 30 ether;
  SaleNumbers public hardCap = SaleNumbers({ ico: 300 ether, privateRound: 300 ether });

  uint256 public availableTokensICO = 14000000 * (10 ** 18);
  uint256 public refundStartDate;
  uint256 public endICO;
  bool public startRefund = false;

  bool public privateRoundActive;
  bytes32 public merkleRoot;

  mapping(address => bool) public airdropRecipients;
  address[] public airdropAddresses;
  uint256 public numRecipients;

  event AirdropAdded(address indexed recipient);
  event AirdropDistributed(address indexed recipient, uint256 amount);
  event TokensPurchased(address purchaser, address beneficiary, uint256 value, uint256 amount);
  event Refund(address recipient, uint256 amount);

  modifier icoActive() {
    require(endICO > 0 && block.timestamp >= startDate && block.timestamp < endICO, "ICO must be active");
    _;
  }

  modifier icoNotActive() {
    require(endICO == 0 || block.timestamp >= endICO, "ICO must not be active");
    _;
  }

  modifier icoNotStarted() {
    require(block.timestamp < startDate || startDate == 0, "ICO must not have started");
    _;
  }

  modifier validateInputs(address beneficiary, uint256 weiAmount) {
    require(beneficiary != address(0), "Crowdsale: beneficiary is the zero address");
    require(weiAmount != 0, "Crowdsale: weiAmount is 0");
    _;
  }

  constructor(address payable wallet, address tokenAddress, uint256 tokenDecimals) {
    require(wallet != address(0), "Pre-Sale: wallet is the zero address");
    require(tokenAddress != address(0), "Pre-Sale: token is the zero address");

    _wallet = wallet;
    _token = IERC20(tokenAddress);
    _tokenDecimals = tokenDecimals;
  }

  receive() external payable {
    bytes32[] memory emptyProof;
    buyTokens(_msgSender(), emptyProof);
  }

  function startICO(uint _startDate, uint _endDate) external onlyOwner icoNotActive icoNotStarted {
    require(_startDate > block.timestamp, "start date should be in the future");
    require(_endDate > _startDate, "end date should be after start date");
    startDate = _startDate;
    endICO = _endDate;
    _weiRaised = 0;
    startRefund = false;
    refundStartDate = 0;
    availableTokensICO = _token.balanceOf(address(this));
  }

  function stopICO() external onlyOwner {
    require(endICO != 0, "ICO is already stopped");
    endICO = 0;
    if (_weiRaised >= softCap) {
      _forwardFunds();
    } else {
      startRefund = true;
      refundStartDate = block.timestamp;
    }
  }

  function buyTokens(address beneficiary, bytes32[] memory proof) public payable nonReentrant validateInputs(beneficiary, msg.value) {
    if (privateRoundActive) {
      require((_weiRaised.add(msg.value)) <= hardCap.privateRound, "Private round hard cap reached");
      require(msg.value >= minPurchase.privateRound, "have to send at least: minPurchase");
      require(_contributions[beneficiary].add(msg.value) <= maxPurchase.privateRound, "can't buy more than: maxPurchase");

      bool verify = MerkleProof.verify(proof, merkleRoot, keccak256(abi.encodePacked(_msgSender())));
      require(verify, "Not whitelisted");

      executePurchase(beneficiary, msg.value);
    } else if (isICOActive()) {
      require((_weiRaised.add(msg.value)) <= hardCap.ico, "ICO hard cap reached");
      require(msg.value >= minPurchase.ico, "have to send at least: minPurchase");
      require(_contributions[beneficiary].add(msg.value) <= maxPurchase.ico, "can't buy more than: maxPurchase");

      executePurchase(beneficiary, msg.value);
    } else {
      revert("Pre-Sale is closed");
    }
  }

  function executePurchase(address beneficiary, uint256 weiAmount) internal {
    uint256 tokens = _getTokenAmount(weiAmount);
    _weiRaised = _weiRaised.add(weiAmount);
    availableTokensICO = availableTokensICO.sub(tokens);
    _contributions[beneficiary] = _contributions[beneficiary].add(weiAmount);
    emit TokensPurchased(_msgSender(), beneficiary, weiAmount, tokens);
  }

  function claimTokens() public nonReentrant icoNotActive returns (bool) {
    require(claimedTokens[msg.sender] < totalAllocation(msg.sender), "Already claimed all allocation");
    require(lastClaimed[msg.sender] + 1 days <= block.timestamp, "Must wait 24 hours between claims");

    uint256 totalTokensForSale = 14000000 * (10 ** 18);
    uint256 userContribution = _contributions[msg.sender];
    uint256 totalTokensPurchasedByUser = totalTokensForSale.mul(userContribution).div(_weiRaised);
    uint256 tokensRemaining = totalTokensPurchasedByUser.sub(claimedTokens[msg.sender]);

    require(tokensRemaining > 0, "No tokens left to claim");

    uint256 percentToClaim;
    if (claimedTokens[msg.sender] == 0) {
      percentToClaim = 50;
    } else {
      percentToClaim = 10;
    }

    uint256 tokensToClaim = totalTokensPurchasedByUser.mul(percentToClaim).div(100);
    claimedTokens[msg.sender] = claimedTokens[msg.sender].add(tokensToClaim);
    lastClaimed[msg.sender] = block.timestamp;

    bool sent = _token.transfer(msg.sender, tokensToClaim);
    require(sent, "Token transfer failed");
    return true;
  }

  function canClaim(address user) public view returns (bool) {
    return (lastClaimed[user] + 1 days <= block.timestamp);
  }

  function claimedAll(address user) public view returns (bool) {
    return (claimedTokens[user] >= totalAllocation(user));
  }

  function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
    return weiAmount.mul(_weiRaised).div(10 ** _tokenDecimals);
  }

  bool private fundsForwarded = false;

  function _forwardFunds() internal {
    _wallet.transfer(_weiRaised);
    uint256 totalTokens = _token.balanceOf(address(this));
    uint256 tokensToOwner = totalTokens.mul(48).div(100);
    _token.transfer(_wallet, tokensToOwner);
    fundsForwarded = true;
  }

  function claimActive() public view returns (bool) {
    return fundsForwarded && _weiRaised >= softCap;
  }

  function checkContribution(address addr) public view returns (uint256) {
    return _contributions[addr];
  }

  function setPrivateRoundActive(bool state) public onlyOwner {
    require(privateRoundActive != state, "Private round is already in that state");
    privateRoundActive = state;
  }

  function setMerkleRoot(bytes32 _root) external onlyOwner {
    merkleRoot = _root;
  }

  function setAvailableTokens(uint256 amount) public onlyOwner icoNotActive {
    availableTokensICO = amount;
  }

  function weiRaised() public view returns (uint256) {
    return _weiRaised;
  }

  function setWalletReceiver(address payable newWallet) external onlyOwner {
    _wallet = newWallet;
  }

  function setHardCapPrivate(uint256 value) external onlyOwner {
    hardCap.privateRound = value;
  }

  function setHardCapICO(uint256 value) external onlyOwner {
    hardCap.ico = value;
  }

  function setSoftCap(uint256 value) external onlyOwner {
    softCap = value;
  }

  function setMaxPurchasePrivate(uint256 value) external onlyOwner {
    maxPurchase.privateRound = value;
  }

  function setMinPurchasePrivateO(uint256 value) external onlyOwner {
    minPurchase.privateRound = value;
  }

  function setMaxPurchaseICO(uint256 value) external onlyOwner {
    maxPurchase.ico = value;
  }

  function setMinPurchaseICO(uint256 value) external onlyOwner {
    minPurchase.ico = value;
  }

  function isICOActive() public view returns (bool) {
    return endICO > 0 && block.timestamp >= startDate && block.timestamp < endICO;
  }

  function totalAllocation(address user) public view returns (uint256) {
    uint256 totalTokensForSale = 14000000 * (10 ** 18);
    uint256 userContribution = _contributions[user];

    return totalTokensForSale.mul(userContribution).div(_weiRaised);
  }

  function unclaimedTokens(address user) public view returns (uint256) {
    uint256 totalTokensForSale = 14000000 * (10 ** 18);
    uint256 userContribution = _contributions[user];

    uint256 totalTokensPurchasedByUser = totalTokensForSale.mul(userContribution).div(_weiRaised);
    uint256 tokensRemaining = totalTokensPurchasedByUser.sub(claimedTokens[user]);

    return tokensRemaining;
  }

  function claimedTokensAmount(address user) public view returns (uint256) {
    return claimedTokens[user];
  }

  function takeTokens(IERC20 tokenAddress) public onlyOwner icoNotActive returns (bool) {
    IERC20 tokenBEP = tokenAddress;
    uint256 tokenAmt = tokenBEP.balanceOf(address(this));
    require(tokenAmt > 0, "BEP-20 balance is 0");
    bool sent = tokenBEP.transfer(_wallet, tokenAmt);
    require(sent, "Token transfer failed");
    return true;
  }

  function refundMe() public icoNotActive {
    require(startRefund == true, "no refund available");
    uint256 amount = _contributions[msg.sender];
    if (address(this).balance >= amount) {
      _contributions[msg.sender] = 0;
      if (amount > 0) {
        address payable recipient = payable(msg.sender);
        recipient.transfer(amount);
        emit Refund(msg.sender, amount);
      }
    }
  }

  function addAirdropRecipients(address[] memory recipients) public onlyOwner {
    for (uint256 i = 0; i < recipients.length; i++) {
      if (!airdropRecipients[recipients[i]]) {
        airdropRecipients[recipients[i]] = true;
        airdropAddresses.push(recipients[i]);
        numRecipients++;
        emit AirdropAdded(recipients[i]);
      }
    }
  }

  function distributeAirdrop() public onlyOwner {
    require(numRecipients > 0, "No recipients for airdrop");
    uint256 totalAirdrop = 560000 * 10 ** _tokenDecimals;
    require(_token.balanceOf(address(this)) >= totalAirdrop, "Insufficient tokens for airdrop");

    uint256 amountPerRecipient = totalAirdrop.div(numRecipients);

    for (uint256 i = 0; i < airdropAddresses.length; i++) {
      if (airdropRecipients[airdropAddresses[i]]) {
        _token.transfer(airdropAddresses[i], amountPerRecipient);
        emit AirdropDistributed(airdropAddresses[i], amountPerRecipient);
        airdropRecipients[airdropAddresses[i]] = false;
      }
    }

    delete airdropAddresses;
    numRecipients = 0;
  }
}
