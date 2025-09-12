// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; 
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Escrow is ReentrancyGuard, Ownable { struct Milestone { uint256 amount; uint256 dueDate; string evidenceURI; bool released; bool disputed; }

mapping(uint256 => mapping(uint256 => Milestone)) public projectMilestones;
mapping(uint256 => mapping(address => uint256)) public deposits;
mapping(uint256 => uint256) public totalLockedFunds;
mapping(uint256 => bool) public projectExists;

event FundsDeposited(uint256 indexed projectId, address indexed payer, uint256 amount);
event MilestoneSubmitted(uint256 indexed projectId, uint256 indexed milestoneId, string evidenceURI);
event FundsReleased(uint256 indexed projectId, uint256 indexed milestoneId, uint256 amount);
event DisputeRaised(uint256 indexed projectId, uint256 indexed milestoneId);
event FundsRefunded(uint256 indexed projectId, address indexed investor, uint256 amount);

constructor() Ownable(msg.sender) {}

function deposit(uint256 projectId, uint256 amount) external payable nonReentrant {
    require(projectExists[projectId], "Project does not exist");
    if (msg.value > 0) {
        deposits[projectId][msg.sender] += msg.value;
    } else {
        revert("No ETH sent");
    }
    totalLockedFunds[projectId] += amount;
    emit FundsDeposited(projectId, msg.sender, amount);
}

function confirmMilestone(uint256 projectId, uint256 milestoneId, string memory evidenceURI) external onlyOwner {
    require(projectExists[projectId], "Project does not exist");
    projectMilestones[projectId][milestoneId] = Milestone(0, block.timestamp + 30 days, evidenceURI, false, false);
    emit MilestoneSubmitted(projectId, milestoneId, evidenceURI);
}

function raiseDispute(uint256 projectId, uint256 milestoneId) external onlyOwner {
    require(projectMilestones[projectId][milestoneId].amount > 0, "Milestone not found");
    projectMilestones[projectId][milestoneId].disputed = true;
    emit DisputeRaised(projectId, milestoneId);
}

function resolveDispute(uint256 projectId, uint256 milestoneId, bool release) external onlyOwner {
    require(projectMilestones[projectId][milestoneId].disputed, "No dispute to resolve");
    if (release) {
        _releaseFunds(projectId, milestoneId);
    } else {
        _refundFunds(projectId, milestoneId);
    }
    projectMilestones[projectId][milestoneId].disputed = false;
}

function _releaseFunds(uint256 projectId, uint256 milestoneId) internal {
    Milestone storage milestone = projectMilestones[projectId][milestoneId];
    require(!milestone.released, "Funds already released");
    require(block.timestamp >= milestone.dueDate, "Milestone not due yet");
    uint256 amount = milestone.amount;
    totalLockedFunds[projectId] -= amount;
    milestone.released = true;
    (bool sent, ) = owner().call{value: amount}("");
    require(sent, "Failed to release funds");
    emit FundsReleased(projectId, milestoneId, amount);
}

function _refundFunds(uint256 projectId, uint256 milestoneId) internal {
    Milestone storage milestone = projectMilestones[projectId][milestoneId];
    require(!milestone.released, "Funds already released");
    uint256 amount = milestone.amount;
    totalLockedFunds[projectId] -= amount;
    milestone.released = true;
    (bool sent, ) = msg.sender.call{value: amount}("");
    require(sent, "Failed to refund funds");
    emit FundsRefunded(projectId, msg.sender, amount);
}

function createProject(uint256 projectId) external onlyOwner {
    require(!projectExists[projectId], "Project already exists");
    projectExists[projectId] = true;
}

function withdraw(uint256 amount) external onlyOwner nonReentrant {
    require(address(this).balance >= amount, "Insufficient balance");
    (bool sent, ) = owner().call{value: amount}("");
    require(sent, "Failed to withdraw");
}

receive() external payable {}

}