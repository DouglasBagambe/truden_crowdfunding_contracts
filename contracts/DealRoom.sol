// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Deal Room Contract
 * @dev Simple access control for private project documents during due diligence
 */
contract DealRoom is AccessControl, Pausable, ReentrancyGuard {
    
    // Role definitions - matching your system
    bytes32 public constant INNOVATOR_ROLE = keccak256("INNOVATOR_ROLE");
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");

    // Enums
    enum KYCStatus { NotVerified, Verified, Expired }
    enum DealRoomStatus { Active, Closed, Expired }

    // Deal room structure
    struct DealRoomInfo {
        uint256 projectId;
        address innovator; // Project creator
        string title;
        string description;
        uint256 creationDate;
        uint256 expiryDate;
        DealRoomStatus status;
        bool kycRequired;
        uint256 minInvestmentIntent; // Minimum investment to access
        string[] documentHashes; // IPFS hashes for documents
        address[] authorizedInvestors;
        mapping(address => InvestorAccess) investorAccess;
    }

    // Investor access tracking
    struct InvestorAccess {
        bool hasAccess;
        uint256 accessGrantedDate;
        uint256 investmentIntent; // How much they intend to invest
        uint256 documentsViewed;
        uint256 lastAccessDate;
        string accessReason;
    }

    // KYC data (simplified)
    struct KYCData {
        KYCStatus status;
        uint256 verificationDate;
        uint256 expiryDate;
        address verifier;
    }

    // State variables
    mapping(uint256 => DealRoomInfo) public dealRooms;
    mapping(address => KYCData) public kycData;
    mapping(address => uint256[]) public innovatorDealRooms; // Track innovator's deal rooms
    mapping(address => uint256[]) public investorDealRooms; // Track investor's accessed deal rooms
    
    uint256 public dealRoomCounter;
    uint256 public defaultExpiryDuration = 90 days; // 3 months default

    // Events
    event DealRoomCreated(uint256 indexed dealRoomId, uint256 indexed projectId, address indexed innovator, string title);
    event AccessRequested(uint256 indexed dealRoomId, address indexed investor, uint256 investmentIntent);
    event AccessGranted(uint256 indexed dealRoomId, address indexed investor, address indexed grantedBy);
    event AccessRevoked(uint256 indexed dealRoomId, address indexed investor, string reason);
    event DocumentAdded(uint256 indexed dealRoomId, string documentHash, address indexed uploader);
    event DocumentViewed(uint256 indexed dealRoomId, address indexed investor, string documentHash);
    event KYCUpdated(address indexed user, KYCStatus status);
    event DealRoomClosed(uint256 indexed dealRoomId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Create a deal room for a project (Innovator only)
     */
    function createDealRoom(
        uint256 _projectId,
        string memory _title,
        string memory _description,
        uint256 _expiryDate,
        bool _kycRequired,
        uint256 _minInvestmentIntent
    ) external whenNotPaused returns (uint256) {
        require(bytes(_title).length > 0, "Title required");
        require(_expiryDate > block.timestamp, "Invalid expiry date");
        require(_minInvestmentIntent > 0, "Invalid minimum investment");

        uint256 dealRoomId = dealRoomCounter++;
        DealRoomInfo storage dealRoom = dealRooms[dealRoomId];
        
        dealRoom.projectId = _projectId;
        dealRoom.innovator = msg.sender;
        dealRoom.title = _title;
        dealRoom.description = _description;
        dealRoom.creationDate = block.timestamp;
        dealRoom.expiryDate = _expiryDate;
        dealRoom.status = DealRoomStatus.Active;
        dealRoom.kycRequired = _kycRequired;
        dealRoom.minInvestmentIntent = _minInvestmentIntent;

        // Grant innovator role and track deal room
        _grantRole(INNOVATOR_ROLE, msg.sender);
        innovatorDealRooms[msg.sender].push(dealRoomId);

        emit DealRoomCreated(dealRoomId, _projectId, msg.sender, _title);
        return dealRoomId;
    }

    /**
     * @dev Request access to deal room (Investor)
     */
    function requestAccess(
        uint256 _dealRoomId,
        uint256 _investmentIntent,
        string memory _reason
    ) external whenNotPaused {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(dealRoom.status == DealRoomStatus.Active, "Deal room not active");
        require(block.timestamp < dealRoom.expiryDate, "Deal room expired");
        require(_investmentIntent >= dealRoom.minInvestmentIntent, "Investment intent too low");
        require(!dealRoom.investorAccess[msg.sender].hasAccess, "Already has access");

        // Check KYC if required
        if (dealRoom.kycRequired) {
            require(kycData[msg.sender].status == KYCStatus.Verified, "KYC verification required");
            require(kycData[msg.sender].expiryDate > block.timestamp, "KYC expired");
        }

        // Store access request (pending approval)
        InvestorAccess storage access = dealRoom.investorAccess[msg.sender];
        access.investmentIntent = _investmentIntent;
        access.accessReason = _reason;

        emit AccessRequested(_dealRoomId, msg.sender, _investmentIntent);
    }

    /**
     * @dev Grant access to investor (Innovator or Admin)
     */
    function grantAccess(uint256 _dealRoomId, address _investor) external whenNotPaused {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(
            dealRoom.innovator == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only innovator or admin can grant access"
        );
        require(dealRoom.status == DealRoomStatus.Active, "Deal room not active");
        require(!dealRoom.investorAccess[_investor].hasAccess, "Already has access");

        // Grant access
        InvestorAccess storage access = dealRoom.investorAccess[_investor];
        access.hasAccess = true;
        access.accessGrantedDate = block.timestamp;

        // Add to authorized investors list
        dealRoom.authorizedInvestors.push(_investor);
        
        // Grant investor role and track deal room access
        _grantRole(INVESTOR_ROLE, _investor);
        investorDealRooms[_investor].push(_dealRoomId);

        emit AccessGranted(_dealRoomId, _investor, msg.sender);
    }

    /**
     * @dev Revoke access from investor
     */
    function revokeAccess(
        uint256 _dealRoomId,
        address _investor,
        string memory _reason
    ) external {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(
            dealRoom.innovator == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only innovator or admin can revoke access"
        );

        dealRoom.investorAccess[_investor].hasAccess = false;
        emit AccessRevoked(_dealRoomId, _investor, _reason);
    }

    /**
     * @dev Add document to deal room (Innovator only)
     */
    function addDocument(
        uint256 _dealRoomId,
        string memory _documentHash
    ) external whenNotPaused {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(dealRoom.innovator == msg.sender, "Only innovator can add documents");
        require(dealRoom.status == DealRoomStatus.Active, "Deal room not active");
        require(bytes(_documentHash).length > 0, "Document hash required");
        
        dealRoom.documentHashes.push(_documentHash);
        emit DocumentAdded(_dealRoomId, _documentHash, msg.sender);
    }

    /**
     * @dev View document (creates audit trail)
     */
    function viewDocument(
        uint256 _dealRoomId,
        string memory _documentHash
    ) external whenNotPaused {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        InvestorAccess storage access = dealRoom.investorAccess[msg.sender];
        
        require(access.hasAccess, "Access denied");
        require(dealRoom.status == DealRoomStatus.Active, "Deal room not active");
        require(block.timestamp < dealRoom.expiryDate, "Deal room expired");

        // Update access tracking
        access.documentsViewed++;
        access.lastAccessDate = block.timestamp;

        emit DocumentViewed(_dealRoomId, msg.sender, _documentHash);
    }

    /**
     * @dev Update KYC status (Admin only)
     */
    function updateKYCStatus(
        address _user,
        KYCStatus _status,
        uint256 _expiryDate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_user != address(0), "Invalid user address");

        KYCData storage kyc = kycData[_user];
        kyc.status = _status;
        kyc.verificationDate = block.timestamp;
        kyc.expiryDate = _expiryDate;
        kyc.verifier = msg.sender;

        emit KYCUpdated(_user, _status);
    }

    /**
     * @dev Close deal room (Innovator or Admin)
     */
    function closeDealRoom(uint256 _dealRoomId) external {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(
            dealRoom.innovator == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only innovator or admin can close"
        );

        dealRoom.status = DealRoomStatus.Closed;
        emit DealRoomClosed(_dealRoomId);
    }

    /**
     * @dev Check if investor has access
     */
    function hasAccess(uint256 _dealRoomId, address _investor) external view returns (bool) {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        return dealRoom.investorAccess[_investor].hasAccess && 
               dealRoom.status == DealRoomStatus.Active &&
               block.timestamp < dealRoom.expiryDate;
    }

    /**
     * @dev Get deal room info
     */
    function getDealRoom(uint256 _dealRoomId) external view returns (
        uint256 projectId,
        address innovator,
        string memory title,
        string memory description,
        uint256 creationDate,
        uint256 expiryDate,
        DealRoomStatus status,
        bool kycRequired,
        uint256 minInvestmentIntent
    ) {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        return (
            dealRoom.projectId,
            dealRoom.innovator,
            dealRoom.title,
            dealRoom.description,
            dealRoom.creationDate,
            dealRoom.expiryDate,
            dealRoom.status,
            dealRoom.kycRequired,
            dealRoom.minInvestmentIntent
        );
    }

    /**
     * @dev Get deal room documents (only for authorized users)
     */
    function getDealRoomDocuments(uint256 _dealRoomId) external view returns (string[] memory) {
        DealRoomInfo storage dealRoom = dealRooms[_dealRoomId];
        require(
            dealRoom.innovator == msg.sender || 
            dealRoom.investorAccess[msg.sender].hasAccess ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access denied"
        );
        
        return dealRoom.documentHashes;
    }

    /**
     * @dev Get authorized investors for a deal room
     */
    function getAuthorizedInvestors(uint256 _dealRoomId) external view returns (address[] memory) {
        require(
            dealRooms[_dealRoomId].innovator == msg.sender || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only innovator or admin can view investors"
        );
        
        return dealRooms[_dealRoomId].authorizedInvestors;
    }

    /**
     * @dev Get investor access info
     */
    function getInvestorAccess(uint256 _dealRoomId, address _investor) external view returns (
        bool hasAccessStatus,
        uint256 accessGrantedDate,
        uint256 investmentIntent,
        uint256 documentsViewed,
        uint256 lastAccessDate
    ) {
        require(
            dealRooms[_dealRoomId].innovator == msg.sender || 
            _investor == msg.sender ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access denied"
        );

        InvestorAccess storage access = dealRooms[_dealRoomId].investorAccess[_investor];
        return (
            access.hasAccess,
            access.accessGrantedDate,
            access.investmentIntent,
            access.documentsViewed,
            access.lastAccessDate
        );
    }

    /**
     * @dev Get user's KYC status
     */
    function getKYCStatus(address _user) external view returns (
        KYCStatus status,
        uint256 verificationDate,
        uint256 expiryDate
    ) {
        require(
            _user == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access denied"
        );

        KYCData storage kyc = kycData[_user];
        return (kyc.status, kyc.verificationDate, kyc.expiryDate);
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

    function setDefaultExpiryDuration(uint256 _duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_duration > 0, "Invalid duration");
        defaultExpiryDuration = _duration;
    }

    /**
     * @dev Auto-expire deal rooms (can be called by anyone)
     */
    function checkAndExpireDealRooms(uint256[] calldata _dealRoomIds) external {
        for (uint256 i = 0; i < _dealRoomIds.length; i++) {
            uint256 dealRoomId = _dealRoomIds[i];
            DealRoomInfo storage dealRoom = dealRooms[dealRoomId];
            
            if (dealRoom.status == DealRoomStatus.Active && block.timestamp >= dealRoom.expiryDate) {
                dealRoom.status = DealRoomStatus.Expired;
            }
        }
    }
}