// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Replacement crypto escrow. Fiat records and settlement remain off-chain in the PostgreSQL ledger.
contract KeiboCampaignEscrow is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant SUCCESS_FEE_BPS = 500;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    bytes32 public constant CAMPAIGN_MANAGER_ROLE = keccak256("CAMPAIGN_MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    enum CampaignState { Funding, Funded, Cancelled, Refunding, Closed }
    enum MilestoneState { Pending, Approved, Released, Cancelled }

    struct Campaign {
        address creator;
        IERC20 asset;
        uint128 cap;
        uint128 raised;
        uint64 deadline;
        CampaignState state;
    }
    struct Milestone { uint128 amount; MilestoneState state; bytes32 evidenceHash; }
    struct RoleTransfer { address candidate; uint64 executableAt; }

    uint256 public campaignCount;
    uint64 public immutable roleTransferDelay;
    address public immutable feeRecipient;
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(address => uint128)) public contributions;
    mapping(uint256 => uint256) public recordedNetworkCosts;
    mapping(uint256 => uint256) public releasedGross;
    mapping(uint256 => uint256) public releasedFees;
    mapping(uint256 => Milestone[]) private milestones;
    mapping(bytes32 => RoleTransfer) public pendingRoleTransfers;

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, address indexed asset, uint256 cap, uint64 deadline);
    event Contributed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignFunded(uint256 indexed campaignId);
    event MilestoneApproved(uint256 indexed campaignId, uint256 indexed milestoneId, bytes32 evidenceHash);
    event MilestoneReleased(uint256 indexed campaignId, uint256 indexed milestoneId, uint256 creatorAmount, uint256 feeAmount);
    event Refunded(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId);
    event NetworkCostRecorded(uint256 indexed campaignId, uint256 amount, bytes32 indexed evidenceHash);
    event RoleTransferScheduled(bytes32 indexed role, address indexed candidate, uint64 executableAt);
    event RoleTransferExecuted(bytes32 indexed role, address indexed previousHolder, address newHolder);
    event RoleTransferCancelled(bytes32 indexed role);

    constructor(address admin, address initialFeeRecipient, uint64 transferDelay) {
        require(admin != address(0) && initialFeeRecipient != address(0), "zero address");
        require(transferDelay >= 1 days, "delay too short");
        feeRecipient = initialFeeRecipient;
        roleTransferDelay = transferDelay;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CAMPAIGN_MANAGER_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
    }

    function createCampaign(IERC20 asset, uint128 cap, uint64 deadline, uint128[] calldata milestoneAmounts) external whenNotPaused returns (uint256 id) {
        require(address(asset) != address(0) && cap > 0 && deadline > block.timestamp, "invalid campaign");
        require(milestoneAmounts.length > 0 && milestoneAmounts.length <= 32, "invalid milestones");
        uint256 milestoneTotal;
        for (uint256 i; i < milestoneAmounts.length; ++i) { require(milestoneAmounts[i] > 0, "zero milestone"); milestoneTotal += milestoneAmounts[i]; }
        require(milestoneTotal == cap, "milestones != cap");
        id = campaignCount++;
        campaigns[id] = Campaign(msg.sender, asset, cap, 0, deadline, CampaignState.Funding);
        for (uint256 i; i < milestoneAmounts.length; ++i) milestones[id].push(Milestone(milestoneAmounts[i], MilestoneState.Pending, bytes32(0)));
        emit CampaignCreated(id, msg.sender, address(asset), cap, deadline);
    }

    function contribute(uint256 campaignId, uint128 amount) external nonReentrant whenNotPaused {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.creator != address(0) && campaign.state == CampaignState.Funding, "not funding");
        require(block.timestamp < campaign.deadline && amount > 0 && campaign.raised + amount <= campaign.cap, "invalid contribution");
        campaign.asset.safeTransferFrom(msg.sender, address(this), amount);
        campaign.raised += amount;
        contributions[campaignId][msg.sender] += amount;
        emit Contributed(campaignId, msg.sender, amount);
        if (campaign.raised == campaign.cap) { campaign.state = CampaignState.Funded; emit CampaignFunded(campaignId); }
    }

    function approveMilestone(uint256 campaignId, uint256 milestoneId, bytes32 evidenceHash) external onlyRole(CAMPAIGN_MANAGER_ROLE) whenNotPaused {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.state == CampaignState.Funded && evidenceHash != bytes32(0), "not releasable");
        Milestone storage milestone = milestones[campaignId][milestoneId];
        require(milestone.state == MilestoneState.Pending, "invalid milestone");
        milestone.state = MilestoneState.Approved;
        milestone.evidenceHash = evidenceHash;
        emit MilestoneApproved(campaignId, milestoneId, evidenceHash);
    }

    function releaseMilestone(uint256 campaignId, uint256 milestoneId) external nonReentrant whenNotPaused {
        Campaign storage campaign = campaigns[campaignId];
        require(msg.sender == campaign.creator, "creator only");
        Milestone storage milestone = milestones[campaignId][milestoneId];
        require(campaign.state == CampaignState.Funded && milestone.state == MilestoneState.Approved, "not approved");
        milestone.state = MilestoneState.Released;
        uint256 newReleasedGross = releasedGross[campaignId] + uint256(milestone.amount);
        uint256 cumulativeFee = newReleasedGross * SUCCESS_FEE_BPS / BPS_DENOMINATOR;
        uint256 fee = cumulativeFee - releasedFees[campaignId];
        releasedGross[campaignId] = newReleasedGross;
        releasedFees[campaignId] = cumulativeFee;
        campaign.asset.safeTransfer(campaign.creator, uint256(milestone.amount) - fee);
        if (fee > 0) campaign.asset.safeTransfer(feeRecipient, fee);
        emit MilestoneReleased(campaignId, milestoneId, uint256(milestone.amount) - fee, fee);
    }

    function cancelCampaign(uint256 campaignId) external onlyRole(CAMPAIGN_MANAGER_ROLE) whenNotPaused {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.state == CampaignState.Funding || campaign.state == CampaignState.Funded, "not cancellable");
        campaign.state = CampaignState.Refunding;
        emit CampaignCancelled(campaignId);
    }

    function refund(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.state == CampaignState.Refunding || (campaign.state == CampaignState.Funding && block.timestamp >= campaign.deadline), "refund unavailable");
        uint256 amount = contributions[campaignId][msg.sender];
        require(amount > 0, "nothing to refund");
        contributions[campaignId][msg.sender] = 0;
        campaign.asset.safeTransfer(msg.sender, amount);
        emit Refunded(campaignId, msg.sender, amount);
    }

    /// @notice Records separately evidenced network cost. It never changes contributor or creator balances.
    function recordNetworkCost(uint256 campaignId, uint256 amount, bytes32 evidenceHash) external onlyRole(TREASURY_ROLE) {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.creator != address(0) && amount > 0 && evidenceHash != bytes32(0), "invalid network cost");
        recordedNetworkCosts[campaignId] += amount;
        emit NetworkCostRecorded(campaignId, amount, evidenceHash);
    }

    function milestoneCount(uint256 campaignId) external view returns (uint256) { return milestones[campaignId].length; }
    function milestoneAt(uint256 campaignId, uint256 milestoneId) external view returns (Milestone memory) { return milestones[campaignId][milestoneId]; }
    function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
    function scheduleRoleTransfer(bytes32 role, address candidate) external onlyRole(DEFAULT_ADMIN_ROLE) { require(candidate != address(0), "zero candidate"); uint64 at = uint64(block.timestamp) + roleTransferDelay; pendingRoleTransfers[role] = RoleTransfer(candidate, at); emit RoleTransferScheduled(role, candidate, at); }
    function cancelRoleTransfer(bytes32 role) external onlyRole(DEFAULT_ADMIN_ROLE) { require(pendingRoleTransfers[role].candidate != address(0), "not scheduled"); delete pendingRoleTransfers[role]; emit RoleTransferCancelled(role); }
    function executeRoleTransfer(bytes32 role, address previousHolder) external { RoleTransfer memory transfer = pendingRoleTransfers[role]; require(transfer.candidate != address(0) && block.timestamp >= transfer.executableAt, "not executable"); delete pendingRoleTransfers[role]; _grantRole(role, transfer.candidate); if (previousHolder != address(0)) _revokeRole(role, previousHolder); emit RoleTransferExecuted(role, previousHolder, transfer.candidate); }
}
