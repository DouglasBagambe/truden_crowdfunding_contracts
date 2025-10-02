// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Investment NFT Contract
 * @dev ERC1155 contract for crowdfunding investment stakes
 * Rebuilt with optimized stack usage
 */
contract InvestmentNFT is ERC1155, ERC1155Supply, AccessControl, ReentrancyGuard, Pausable {
    
    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE = keccak256("METADATA_UPDATER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // Constants
    uint256 public constant FIXED_SUPPLY_PER_PROJECT = 1_000_000;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_LOCKUP_PERIOD = 180 days;

    // Enums
    enum ProjectStatus { Active, Completed, Failed, Liquidated }

    // Core project data
    struct ProjectData {
        uint256 projectId;
        address creator;
        address paymentToken;
        uint256 targetAmount;
        uint256 initialTokenValue;
        uint256 currentTokenValue;
        uint256 creationDate;
        uint256 lockupPeriod;
        ProjectStatus status;
        bool redeemable;
    }

    // Project metadata (separate to reduce struct size)
    struct ProjectMetadata {
        string title;
        string description;
        string metadataURI;
        uint256 performanceMultiplier;
        uint256 lastUpdateDate;
    }

    // User investment data
    struct Investment {
        uint256 originalAmount;
        uint256 tokenAmount;
        uint256 investmentDate;
        uint256 averageBuyPrice;
        uint256 totalDividends;
        uint256 lastClaimDate;
        bool hasRedeemed;
    }

    // Marketplace listing
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 pricePerToken;
        address paymentToken;
        uint256 expiryDate;
        uint256 minPurchase;
        bool active;
        bool partialFill;
    }

    // Dividend info
    struct Dividend {
        uint256 totalAmount;
        uint256 pricePerToken;
        uint256 payoutDate;
        address paymentToken;
    }

    // State
    mapping(uint256 => ProjectData) public projects;
    mapping(uint256 => ProjectMetadata) public metadata;
    mapping(uint256 => mapping(address => Investment)) public investments;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => mapping(uint256 => Dividend)) public dividends;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public dividendClaimed;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public dividendAmount;
    mapping(uint256 => uint256) public dividendCount;
    mapping(uint256 => address[]) public investors;
    mapping(address => uint256[]) public userProjects;

    uint256 public listingCounter;
    uint256 public marketplaceFee = 250; // 2.5%
    address public feeRecipient;
    address public escrowContract;
    string private baseURI;

    // Events
    event ProjectCreated(uint256 indexed projectId, address creator, uint256 supply);
    event TokensMinted(uint256 indexed projectId, address investor, uint256 amount);
    event MetadataUpdated(uint256 indexed projectId, uint256 newValue);
    event DividendDistributed(uint256 indexed projectId, uint256 payoutId, uint256 amount);
    event DividendClaimed(uint256 indexed projectId, uint256 payoutId, address user, uint256 amount);
    event ListingCreated(uint256 indexed listingId, uint256 projectId, uint256 amount);
    event TokensPurchased(uint256 indexed listingId, address buyer, uint256 amount);
    event TokensRedeemed(uint256 indexed projectId, address user, uint256 amount);
    event StatusUpdated(uint256 indexed projectId, ProjectStatus status);

    constructor(
        string memory _baseURI,
        address _feeRecipient,
        address _escrowContract
    ) ERC1155(_baseURI) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_escrowContract != address(0), "Invalid escrow");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(METADATA_UPDATER_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        
        baseURI = _baseURI;
        feeRecipient = _feeRecipient;
        escrowContract = _escrowContract;
    }

    /**
     * @dev Create project NFT
     */
    function createProjectNFT(
        uint256 _id,
        address _creator,
        uint256 _target,
        address _token
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256) {
        require(_target > 0, "Invalid target");
        require(_creator != address(0), "Invalid creator");
        require(projects[_id].projectId == 0, "Exists");

        uint256 initValue = _target / FIXED_SUPPLY_PER_PROJECT;
        require(initValue > 0, "Target too small");

        projects[_id] = ProjectData({
            projectId: _id,
            creator: _creator,
            paymentToken: _token,
            targetAmount: _target,
            initialTokenValue: initValue,
            currentTokenValue: initValue,
            creationDate: block.timestamp,
            lockupPeriod: DEFAULT_LOCKUP_PERIOD,
            status: ProjectStatus.Active,
            redeemable: false
        });

        metadata[_id].performanceMultiplier = BASIS_POINTS;
        metadata[_id].lastUpdateDate = block.timestamp;

        emit ProjectCreated(_id, _creator, FIXED_SUPPLY_PER_PROJECT);
        return _id;
    }

    /**
     * @dev Set project metadata (separate function to avoid stack issues)
     */
    function setProjectMetadata(
        uint256 _id,
        string calldata _title,
        string calldata _desc,
        string calldata _uri
    ) external onlyRole(MINTER_ROLE) {
        require(projects[_id].projectId != 0, "Project doesn't exist");
        metadata[_id].title = _title;
        metadata[_id].description = _desc;
        metadata[_id].metadataURI = _uri;
    }

    /**
     * @dev Mint investment tokens
     */
    function mintInvestmentTokens(
        uint256 _projectId,
        address _investor,
        uint256 _amount
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(_investor != address(0), "Invalid investor");
        require(_amount > 0, "Invalid amount");
        
        ProjectData storage project = projects[_projectId];
        require(project.projectId != 0, "Project doesn't exist");
        require(project.status == ProjectStatus.Active, "Not active");

        uint256 tokens = (_amount * FIXED_SUPPLY_PER_PROJECT) / project.targetAmount;
        require(tokens > 0, "Amount too small");
        require(totalSupply(_projectId) + tokens <= FIXED_SUPPLY_PER_PROJECT, "Exceeds supply");

        Investment storage inv = investments[_projectId][_investor];
        
        if (inv.tokenAmount == 0) {
            investors[_projectId].push(_investor);
            userProjects[_investor].push(_projectId);
            inv.investmentDate = block.timestamp;
        }
        
        uint256 totalTokens = inv.tokenAmount + tokens;
        uint256 totalInvested = inv.originalAmount + _amount;
        
        inv.averageBuyPrice = (inv.averageBuyPrice * inv.tokenAmount + project.currentTokenValue * tokens) / totalTokens;
        inv.originalAmount = totalInvested;
        inv.tokenAmount = totalTokens;

        _mint(_investor, _projectId, tokens, "");

        emit TokensMinted(_projectId, _investor, tokens);
    }

    /**
     * @dev Update metadata
     */
    function updateMetadata(
        uint256 _projectId,
        uint256 _newValue,
        uint256 _multiplier
    ) external onlyRole(METADATA_UPDATER_ROLE) whenNotPaused {
        require(projects[_projectId].projectId != 0, "Project doesn't exist");
        require(_newValue > 0, "Invalid value");
        require(_multiplier > 0, "Invalid multiplier");

        projects[_projectId].currentTokenValue = _newValue;
        metadata[_projectId].performanceMultiplier = _multiplier;
        metadata[_projectId].lastUpdateDate = block.timestamp;

        emit MetadataUpdated(_projectId, _newValue);
    }

    /**
     * @dev Update metadata URI
     */
    function updateMetadataURI(
        uint256 _projectId,
        string calldata _uri
    ) external onlyRole(METADATA_UPDATER_ROLE) {
        require(projects[_projectId].projectId != 0, "Project doesn't exist");
        metadata[_projectId].metadataURI = _uri;
    }

    /**
     * @dev Distribute dividends
     */
    function distributeDividends(
        uint256 _projectId,
        uint256 _amount,
        address _token
    ) external payable onlyRole(ORACLE_ROLE) nonReentrant whenNotPaused {
        require(projects[_projectId].projectId != 0, "Project doesn't exist");
        require(_amount > 0, "Invalid amount");

        if (_token == address(0)) {
            require(msg.value == _amount, "ETH mismatch");
        } else {
            require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        }

        uint256 payoutId = dividendCount[_projectId]++;
        uint256 supply = totalSupply(_projectId);
        uint256 pricePerToken = _amount / supply;

        dividends[_projectId][payoutId] = Dividend({
            totalAmount: _amount,
            pricePerToken: pricePerToken,
            payoutDate: block.timestamp,
            paymentToken: _token
        });

        _calculateDividends(_projectId, payoutId, pricePerToken);

        emit DividendDistributed(_projectId, payoutId, _amount);
    }

    /**
     * @dev Calculate dividend amounts for investors
     */
    function _calculateDividends(
        uint256 _projectId,
        uint256 _payoutId,
        uint256 _pricePerToken
    ) private {
        address[] storage investorList = investors[_projectId];
        uint256 len = investorList.length;
        
        for (uint256 i = 0; i < len; i++) {
            address investor = investorList[i];
            uint256 balance = balanceOf(investor, _projectId);
            if (balance > 0) {
                dividendAmount[_projectId][_payoutId][investor] = balance * _pricePerToken;
            }
        }
    }

    /**
     * @dev Claim dividends
     */
    function claimDividends(uint256 _projectId, uint256 _payoutId) 
        external nonReentrant whenNotPaused 
    {
        require(!dividendClaimed[_projectId][_payoutId][msg.sender], "Already claimed");
        
        uint256 amount = dividendAmount[_projectId][_payoutId][msg.sender];
        require(amount > 0, "Nothing to claim");

        dividendClaimed[_projectId][_payoutId][msg.sender] = true;
        
        Investment storage inv = investments[_projectId][msg.sender];
        inv.totalDividends += amount;
        inv.lastClaimDate = block.timestamp;

        Dividend storage div = dividends[_projectId][_payoutId];
        
        if (div.paymentToken == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            require(IERC20(div.paymentToken).transfer(msg.sender, amount), "Transfer failed");
        }

        emit DividendClaimed(_projectId, _payoutId, msg.sender, amount);
    }

    /**
     * @dev Create marketplace listing
     */
    function createListing(
        uint256 _projectId,
        uint256 _amount,
        uint256 _price,
        address _token,
        uint256 _expiry,
        bool _partialFill,
        uint256 _minPurchase
    ) external whenNotPaused returns (uint256) {
        require(balanceOf(msg.sender, _projectId) >= _amount, "Insufficient balance");
        require(_amount > 0, "Invalid amount");
        require(_price > 0, "Invalid price");
        require(_expiry > block.timestamp, "Invalid expiry");
        
        ProjectData storage project = projects[_projectId];
        require(project.projectId != 0, "Project doesn't exist");
        require(block.timestamp >= project.creationDate + project.lockupPeriod, "Locked");

        uint256 listingId = listingCounter++;
        
        listings[listingId] = Listing({
            seller: msg.sender,
            tokenId: _projectId,
            amount: _amount,
            pricePerToken: _price,
            paymentToken: _token,
            expiryDate: _expiry,
            minPurchase: _minPurchase,
            active: true,
            partialFill: _partialFill
        });

        _safeTransferFrom(msg.sender, address(this), _projectId, _amount, "");

        emit ListingCreated(listingId, _projectId, _amount);
        return listingId;
    }

    /**
     * @dev Purchase from marketplace
     */
    function purchase(uint256 _listingId, uint256 _amount) 
        external payable nonReentrant whenNotPaused 
    {
        Listing storage listing = listings[_listingId];
        require(listing.active, "Not active");
        require(block.timestamp < listing.expiryDate, "Expired");
        require(_amount >= listing.minPurchase, "Below minimum");
        require(_amount <= listing.amount, "Exceeds available");
        require(listing.seller != msg.sender, "Cannot buy own");

        uint256 totalPrice = _amount * listing.pricePerToken;
        uint256 fee = (totalPrice * marketplaceFee) / BASIS_POINTS;
        uint256 sellerAmount = totalPrice - fee;

        _processPayment(listing.paymentToken, totalPrice, listing.seller, sellerAmount, fee);
        _safeTransferFrom(address(this), msg.sender, listing.tokenId, _amount, "");
        _updateInvestmentRecords(listing.tokenId, listing.seller, msg.sender, _amount, listing.pricePerToken);

        listing.amount -= _amount;
        if (listing.amount == 0 || !listing.partialFill) {
            listing.active = false;
        }

        emit TokensPurchased(_listingId, msg.sender, _amount);
    }

    /**
     * @dev Process marketplace payment
     */
    function _processPayment(
        address _token,
        uint256 _total,
        address _seller,
        uint256 _sellerAmount,
        uint256 _fee
    ) private {
        if (_token == address(0)) {
            require(msg.value == _total, "ETH mismatch");
            payable(_seller).transfer(_sellerAmount);
            payable(feeRecipient).transfer(_fee);
        } else {
            IERC20 token = IERC20(_token);
            require(token.transferFrom(msg.sender, _seller, _sellerAmount), "Seller transfer failed");
            require(token.transferFrom(msg.sender, feeRecipient, _fee), "Fee transfer failed");
        }
    }

    /**
     * @dev Update investment records after marketplace trade
     */
    function _updateInvestmentRecords(
        uint256 _projectId,
        address _seller,
        address _buyer,
        uint256 _amount,
        uint256 _price
    ) private {
        Investment storage buyerInv = investments[_projectId][_buyer];
        
        if (buyerInv.tokenAmount == 0) {
            investors[_projectId].push(_buyer);
            userProjects[_buyer].push(_projectId);
            buyerInv.investmentDate = block.timestamp;
        }
        
        uint256 prevTokens = buyerInv.tokenAmount;
        uint256 newTotal = prevTokens + _amount;
        buyerInv.averageBuyPrice = (buyerInv.averageBuyPrice * prevTokens + _price * _amount) / newTotal;
        buyerInv.tokenAmount = newTotal;

        Investment storage sellerInv = investments[_projectId][_seller];
        sellerInv.tokenAmount -= _amount;
    }

    /**
     * @dev Cancel listing
     */
    function cancelListing(uint256 _listingId) external whenNotPaused {
        Listing storage listing = listings[_listingId];
        require(listing.seller == msg.sender, "Not your listing");
        require(listing.active, "Not active");

        listing.active = false;
        _safeTransferFrom(address(this), msg.sender, listing.tokenId, listing.amount, "");
    }

    /**
     * @dev Redeem tokens
     */
    function redeemTokens(uint256 _projectId, uint256 _amount) 
        external nonReentrant whenNotPaused 
    {
        require(_amount > 0, "Invalid amount");
        require(balanceOf(msg.sender, _projectId) >= _amount, "Insufficient balance");

        ProjectData storage project = projects[_projectId];
        require(project.projectId != 0, "Project doesn't exist");
        require(project.redeemable, "Not redeemable");
        require(block.timestamp >= project.creationDate + project.lockupPeriod, "Locked");

        uint256 value = _amount * project.currentTokenValue;
        
        _burn(msg.sender, _projectId, _amount);

        Investment storage inv = investments[_projectId][msg.sender];
        inv.tokenAmount -= _amount;
        inv.hasRedeemed = true;

        if (project.paymentToken == address(0)) {
            payable(msg.sender).transfer(value);
        } else {
            require(IERC20(project.paymentToken).transfer(msg.sender, value), "Transfer failed");
        }

        emit TokensRedeemed(_projectId, msg.sender, _amount);
    }

    /**
     * @dev Update project status
     */
    function updateStatus(uint256 _projectId, ProjectStatus _status) 
        external onlyRole(ORACLE_ROLE) 
    {
        ProjectData storage project = projects[_projectId];
        require(project.projectId != 0, "Project doesn't exist");
        
        project.status = _status;
        
        if (_status == ProjectStatus.Completed || _status == ProjectStatus.Failed) {
            project.redeemable = true;
        }

        emit StatusUpdated(_projectId, _status);
    }

    /**
     * @dev Get project details
     */
    function getProject(uint256 _id) external view returns (
        address creator,
        uint256 target,
        uint256 currentValue,
        ProjectStatus status,
        bool redeemable
    ) {
        ProjectData storage p = projects[_id];
        return (p.creator, p.targetAmount, p.currentTokenValue, p.status, p.redeemable);
    }

    /**
     * @dev Get project metadata
     */
    function getMetadata(uint256 _id) external view returns (
        string memory title,
        string memory description,
        uint256 multiplier
    ) {
        ProjectMetadata storage m = metadata[_id];
        return (m.title, m.description, m.performanceMultiplier);
    }

    /**
     * @dev Get investment details
     */
    function getInvestment(uint256 _projectId, address _user) external view returns (
        uint256 originalAmount,
        uint256 tokens,
        uint256 currentValue,
        uint256 totalDividends,
        uint256 avgPrice
    ) {
        Investment storage inv = investments[_projectId][_user];
        ProjectData storage project = projects[_projectId];
        
        return (
            inv.originalAmount,
            inv.tokenAmount,
            inv.tokenAmount * project.currentTokenValue,
            inv.totalDividends,
            inv.averageBuyPrice
        );
    }

    /**
     * @dev Get listing details
     */
    function getListing(uint256 _id) external view returns (
        address seller,
        uint256 tokenId,
        uint256 amount,
        uint256 price,
        bool active
    ) {
        Listing storage l = listings[_id];
        return (l.seller, l.tokenId, l.amount, l.pricePerToken, l.active);
    }

    /**
     * @dev Get unclaimed dividends
     */
    function getUnclaimedDividends(uint256 _projectId, address _user) 
        external view returns (uint256[] memory payoutIds, uint256[] memory amounts) 
    {
        uint256 total = dividendCount[_projectId];
        uint256 count = 0;
        
        for (uint256 i = 0; i < total; i++) {
            if (!dividendClaimed[_projectId][i][_user] && dividendAmount[_projectId][i][_user] > 0) {
                count++;
            }
        }
        
        payoutIds = new uint256[](count);
        amounts = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < total; i++) {
            if (!dividendClaimed[_projectId][i][_user] && dividendAmount[_projectId][i][_user] > 0) {
                payoutIds[index] = i;
                amounts[index] = dividendAmount[_projectId][i][_user];
                index++;
            }
        }
        
        return (payoutIds, amounts);
    }

    /**
     * @dev Get token URI
     */
    function uri(uint256 _tokenId) public view override returns (string memory) {
        string memory metaURI = metadata[_tokenId].metadataURI;
        if (bytes(metaURI).length > 0) {
            return metaURI;
        }
        return string(abi.encodePacked(baseURI, _toString(_tokenId)));
    }

    /**
     * @dev Convert uint to string
     */
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Admin functions
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setMarketplaceFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee <= 1000, "Fee too high");
        marketplaceFee = _fee;
    }

    function setFeeRecipient(address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_recipient != address(0), "Invalid recipient");
        feeRecipient = _recipient;
    }

    function setEscrowContract(address _escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_escrow != address(0), "Invalid escrow");
        escrowContract = _escrow;
    }

    function setBaseURI(string memory _uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = _uri;
    }

    function emergencyWithdraw(address _token, uint256 _amount) 
        external onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_token == address(0)) {
            payable(msg.sender).transfer(_amount);
        } else {
            require(IERC20(_token).transfer(msg.sender, _amount), "Transfer failed");
        }
    }

    /**
     * @dev Override _update for pause functionality
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        if (paused()) revert EnforcedPause();
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId) 
        public view override(ERC1155, AccessControl) returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}