// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Escrow Contract for Crowdfunding Platform
 * @dev Manages project funding with milestone-based releases and dispute resolution
 * Integrates with Kleros for decentralized arbitration
 */
contract Escrow is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PROJECT_CREATOR_ROLE = keccak256("PROJECT_CREATOR_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    // Enums for better state management
    enum ProjectStatus { Active, Completed, Cancelled, Disputed }
    enum MilestoneStatus { Pending, Submitted, Approved, Disputed, Released, Refunded }
    enum DisputeStatus { None, Raised, UnderReview, Resolved }

    // Enhanced milestone structure
    struct Milestone {
        uint256 amount;
        uint256 dueDate;
        string title;
        string description;
        string evidenceURI;
        address creator;
        MilestoneStatus status;
        DisputeStatus disputeStatus;
        uint256 submissionDate;
        uint256 approvalDate;
        mapping(address => bool) approvals; // Multi-validator approval system
        uint256 approvalsCount;
        uint256 requiredApprovals;
    }

    // Project structure
    struct Project {
        address creator;
        string title;
        string description;
        uint256 targetAmount;
        uint256 raisedAmount;
        uint256 creationDate;
        uint256 deadline;
        ProjectStatus status;
        IERC20 token; // address(0) for ETH
        uint256 totalMilestones;
        uint256 completedMilestones;
        bool emergencyWithdrawEnabled;
    }

    // Investor contribution tracking
    struct Investment {
        uint256 amount;
        uint256 timestamp;
        bool refunded;
        uint256 milestoneContributions; // Track which milestones this investment covers
    }

    // State variables
    mapping(uint256 => Project) public projects;
    mapping(uint256 => mapping(uint256 => Milestone)) public projectMilestones;
    mapping(uint256 => mapping(address => Investment)) public investments;
    mapping(uint256 => address[]) public projectInvestors;
    mapping(uint256 => uint256) public totalLockedFunds;
    mapping(address => uint256[]) public userProjects; // Track user's projects
    
    uint256 public projectCounter;
    uint256 public constant MIN_MILESTONE_DURATION = 7 days;
    uint256 public constant MAX_PROJECT_DURATION = 365 days;
    uint256 public platformFeePercentage = 250; // 2.5% in basis points
    address public feeRecipient;

    // Events
    event ProjectCreated(uint256 indexed projectId, address indexed creator, string title, uint256 targetAmount);
    event FundsDeposited(uint256 indexed projectId, address indexed investor, uint256 amount, address token);
    event MilestoneCreated(uint256 indexed projectId, uint256 indexed milestoneId, uint256 amount, uint256 dueDate);
    event MilestoneSubmitted(uint256 indexed projectId, uint256 indexed milestoneId, string evidenceURI, uint256 timestamp);
    event MilestoneApproved(uint256 indexed projectId, uint256 indexed milestoneId, address indexed validator);
    event FundsReleased(uint256 indexed projectId, uint256 indexed milestoneId, uint256 amount, address recipient);
    event DisputeRaised(uint256 indexed projectId, uint256 indexed milestoneId, address indexed initiator);
    event DisputeResolved(uint256 indexed projectId, uint256 indexed milestoneId, bool releasedToCreator);
    event FundsRefunded(uint256 indexed projectId, address indexed investor, uint256 amount);
    event ProjectStatusChanged(uint256 indexed projectId, ProjectStatus status);
    event EmergencyWithdrawTriggered(uint256 indexed projectId, address indexed initiator);

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RESOLVER_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Create a new project with enhanced validation
     */
    function createProject(
        string memory _title,
        string memory _description,
        uint256 _targetAmount,
        uint256 _deadline,
        address _token
    ) external whenNotPaused returns (uint256) {
        require(bytes(_title).length > 0, "Title required");
        require(bytes(_description).length > 0, "Description required");
        require(_targetAmount > 0, "Invalid target amount");
        require(_deadline > block.timestamp, "Invalid deadline");
        require(_deadline <= block.timestamp + MAX_PROJECT_DURATION, "Deadline too far");

        uint256 projectId = projectCounter++;
        Project storage project = projects[projectId];
        
        project.creator = msg.sender;
        project.title = _title;
        project.description = _description;
        project.targetAmount = _targetAmount;
        project.creationDate = block.timestamp;
        project.deadline = _deadline;
        project.status = ProjectStatus.Active;
        project.token = IERC20(_token);

        // Grant creator role for this project
        _grantRole(PROJECT_CREATOR_ROLE, msg.sender);
        userProjects[msg.sender].push(projectId);

        emit ProjectCreated(projectId, msg.sender, _title, _targetAmount);
        return projectId;
    }

    /**
     * @dev Create milestone with enhanced validation
     */
    function createMilestone(
        uint256 _projectId,
        uint256 _amount,
        uint256 _dueDate,
        string memory _title,
        string memory _description,
        uint256 _requiredApprovals
    ) external whenNotPaused {
        require(projects[_projectId].creator == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized");
        require(_amount > 0, "Invalid amount");
        require(_dueDate > block.timestamp + MIN_MILESTONE_DURATION, "Due date too soon");
        require(bytes(_title).length > 0, "Title required");
        require(_requiredApprovals > 0, "Need at least 1 approval");

        Project storage project = projects[_projectId];
        require(project.status == ProjectStatus.Active, "Project not active");

        uint256 milestoneId = project.totalMilestones++;
        Milestone storage milestone = projectMilestones[_projectId][milestoneId];
        
        milestone.amount = _amount;
        milestone.dueDate = _dueDate;
        milestone.title = _title;
        milestone.description = _description;
        milestone.creator = msg.sender;
        milestone.status = MilestoneStatus.Pending;
        milestone.requiredApprovals = _requiredApprovals;

        emit MilestoneCreated(_projectId, milestoneId, _amount, _dueDate);
    }

    /**
     * @dev Enhanced deposit function with better tracking
     */
    function deposit(uint256 _projectId, uint256 _amount) external payable nonReentrant whenNotPaused {
        Project storage project = projects[_projectId];
        require(project.status == ProjectStatus.Active, "Project not active");
        require(block.timestamp < project.deadline, "Project deadline passed");
        
        uint256 actualAmount;
        address tokenAddress = address(project.token);

        if (tokenAddress == address(0)) {
            // ETH deposit
            require(msg.value == _amount, "ETH amount mismatch");
            actualAmount = msg.value;
        } else {
            // ERC20 deposit
            require(msg.value == 0, "No ETH for token deposits");
            project.token.safeTransferFrom(msg.sender, address(this), _amount);
            actualAmount = _amount;
        }

        // Record investment
        Investment storage investment = investments[_projectId][msg.sender];
        if (investment.amount == 0) {
            projectInvestors[_projectId].push(msg.sender);
        }
        
        investment.amount = investment.amount + actualAmount;
        investment.timestamp = block.timestamp;
        
        project.raisedAmount = project.raisedAmount + actualAmount;
        totalLockedFunds[_projectId] = totalLockedFunds[_projectId] + actualAmount;

        emit FundsDeposited(_projectId, msg.sender, actualAmount, tokenAddress);
        
        // Auto-complete project if target reached
        if (project.raisedAmount >= project.targetAmount) {
            project.status = ProjectStatus.Completed;
            emit ProjectStatusChanged(_projectId, ProjectStatus.Completed);
        }
    }

    /**
     * @dev Submit milestone evidence
     */
    function submitMilestone(
        uint256 _projectId,
        uint256 _milestoneId,
        string memory _evidenceURI
    ) external whenNotPaused {
        Project storage project = projects[_projectId];
        require(project.creator == msg.sender, "Only creator can submit");
        
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        require(milestone.status == MilestoneStatus.Pending, "Invalid milestone status");
        require(bytes(_evidenceURI).length > 0, "Evidence URI required");

        milestone.evidenceURI = _evidenceURI;
        milestone.status = MilestoneStatus.Submitted;
        milestone.submissionDate = block.timestamp;

        emit MilestoneSubmitted(_projectId, _milestoneId, _evidenceURI, block.timestamp);
    }

    /**
     * @dev Multi-validator approval system
     */
    function approveMilestone(uint256 _projectId, uint256 _milestoneId) external whenNotPaused {
        require(hasRole(VALIDATOR_ROLE, msg.sender) || 
                investments[_projectId][msg.sender].amount > 0, "Not authorized to validate");
        
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        require(milestone.status == MilestoneStatus.Submitted, "Milestone not submitted");
        require(!milestone.approvals[msg.sender], "Already approved");

        milestone.approvals[msg.sender] = true;
        milestone.approvalsCount++;

        emit MilestoneApproved(_projectId, _milestoneId, msg.sender);

        // Auto-release if enough approvals
        if (milestone.approvalsCount >= milestone.requiredApprovals) {
            milestone.status = MilestoneStatus.Approved;
            milestone.approvalDate = block.timestamp;
            _releaseFunds(_projectId, _milestoneId);
        }
    }

    /**
     * @dev Enhanced dispute system
     */
    function raiseDispute(uint256 _projectId, uint256 _milestoneId, string memory /* _reason */) external whenNotPaused {
        require(investments[_projectId][msg.sender].amount > 0 || 
                hasRole(VALIDATOR_ROLE, msg.sender), "Not authorized");
        
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        require(milestone.status != MilestoneStatus.Released, "Already released");
        require(milestone.disputeStatus == DisputeStatus.None, "Dispute already raised");

        milestone.disputeStatus = DisputeStatus.Raised;
        milestone.status = MilestoneStatus.Disputed;

        emit DisputeRaised(_projectId, _milestoneId, msg.sender);
    }

    /**
     * @dev Resolve dispute (integration point for Kleros)
     */
    function resolveDispute(
        uint256 _projectId, 
        uint256 _milestoneId, 
        bool _releaseToCreator
    ) external onlyRole(RESOLVER_ROLE) whenNotPaused {
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        require(milestone.disputeStatus == DisputeStatus.Raised, "No active dispute");

        milestone.disputeStatus = DisputeStatus.Resolved;

        if (_releaseToCreator) {
            milestone.status = MilestoneStatus.Approved;
            _releaseFunds(_projectId, _milestoneId);
        } else {
            milestone.status = MilestoneStatus.Refunded;
            _refundMilestone(_projectId, _milestoneId);
        }

        emit DisputeResolved(_projectId, _milestoneId, _releaseToCreator);
    }

    /**
     * @dev Internal function to release funds with platform fee
     */
    function _releaseFunds(uint256 _projectId, uint256 _milestoneId) internal {
        Project storage project = projects[_projectId];
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        
        require(milestone.status == MilestoneStatus.Approved, "Not approved for release");
        require(milestone.status != MilestoneStatus.Released, "Already released");

        uint256 amount = milestone.amount;
        uint256 platformFee = (amount * platformFeePercentage) / 10000;
        uint256 creatorAmount = amount - platformFee;

        milestone.status = MilestoneStatus.Released;
        project.completedMilestones++;
        totalLockedFunds[_projectId] = totalLockedFunds[_projectId] - amount;

        // Transfer funds
        if (address(project.token) == address(0)) {
            payable(project.creator).transfer(creatorAmount);
            payable(feeRecipient).transfer(platformFee);
        } else {
            project.token.safeTransfer(project.creator, creatorAmount);
            project.token.safeTransfer(feeRecipient, platformFee);
        }

        emit FundsReleased(_projectId, _milestoneId, creatorAmount, project.creator);
    }

    /**
     * @dev Refund milestone proportionally to investors
     */
    function _refundMilestone(uint256 _projectId, uint256 _milestoneId) internal {
        Project storage project = projects[_projectId];
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        
        uint256 totalAmount = milestone.amount;
        address[] memory investors = projectInvestors[_projectId];
        
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            Investment storage investment = investments[_projectId][investor];
            
            if (!investment.refunded && investment.amount > 0) {
                uint256 refundAmount = (totalAmount * investment.amount) / project.raisedAmount;
                
                if (address(project.token) == address(0)) {
                    payable(investor).transfer(refundAmount);
                } else {
                    project.token.safeTransfer(investor, refundAmount);
                }
                
                emit FundsRefunded(_projectId, investor, refundAmount);
            }
        }
        
        totalLockedFunds[_projectId] = totalLockedFunds[_projectId] - totalAmount;
    }

    /**
     * @dev Emergency withdrawal for extreme cases
     */
    function triggerEmergencyWithdraw(uint256 _projectId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Project storage project = projects[_projectId];
        project.emergencyWithdrawEnabled = true;
        project.status = ProjectStatus.Cancelled;
        
        emit EmergencyWithdrawTriggered(_projectId, msg.sender);
        emit ProjectStatusChanged(_projectId, ProjectStatus.Cancelled);
    }

    /**
     * @dev Allow investors to withdraw in emergency situations
     */
    function emergencyWithdraw(uint256 _projectId) external nonReentrant {
        Project storage project = projects[_projectId];
        require(project.emergencyWithdrawEnabled, "Emergency withdrawal not enabled");
        
        Investment storage investment = investments[_projectId][msg.sender];
        require(!investment.refunded && investment.amount > 0, "Nothing to withdraw");
        
        uint256 amount = investment.amount;
        investment.refunded = true;
        
        if (address(project.token) == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            project.token.safeTransfer(msg.sender, amount);
        }
        
        emit FundsRefunded(_projectId, msg.sender, amount);
    }

    /**
     * @dev Get project details
     */
    function getProject(uint256 _projectId) external view returns (
        address creator,
        string memory title,
        string memory description,
        uint256 targetAmount,
        uint256 raisedAmount,
        uint256 deadline,
        ProjectStatus status
    ) {
        Project storage project = projects[_projectId];
        return (
            project.creator,
            project.title,
            project.description,
            project.targetAmount,
            project.raisedAmount,
            project.deadline,
            project.status
        );
    }

    /**
     * @dev Get milestone details
     */
    function getMilestone(uint256 _projectId, uint256 _milestoneId) external view returns (
        uint256 amount,
        uint256 dueDate,
        string memory title,
        string memory evidenceURI,
        MilestoneStatus status,
        uint256 approvalsCount,
        uint256 requiredApprovals
    ) {
        Milestone storage milestone = projectMilestones[_projectId][_milestoneId];
        return (
            milestone.amount,
            milestone.dueDate,
            milestone.title,
            milestone.evidenceURI,
            milestone.status,
            milestone.approvalsCount,
            milestone.requiredApprovals
        );
    }

    /**
     * @dev Get user's investment in a project
     */
    function getUserInvestment(uint256 _projectId, address _user) external view returns (
        uint256 amount,
        uint256 timestamp,
        bool refunded
    ) {
        Investment storage investment = investments[_projectId][_user];
        return (investment.amount, investment.timestamp, investment.refunded);
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

    function setPlatformFee(uint256 _feePercentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feePercentage <= 1000, "Fee too high"); // Max 10%
        platformFeePercentage = _feePercentage;
    }

    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Fallback function
     */
    receive() external payable {}
}