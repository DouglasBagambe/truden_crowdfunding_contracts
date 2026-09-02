// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IKeiboGovernedEscrow {
    function pause() external;
    function unpause() external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

/// @notice Bounded governance executor. It cannot execute arbitrary targets or calldata.
contract KeiboGovernance is AccessControl {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");
    enum Action { Pause, Unpause, GrantRole, RevokeRole }
    enum ProposalState { Pending, Cancelled, Executed }

    struct Proposal {
        Action action;
        bytes32 role;
        address account;
        uint64 executableAt;
        uint64 challengeEndsAt;
        ProposalState state;
    }

    IKeiboGovernedEscrow public immutable escrow;
    uint64 public immutable executionDelay;
    uint64 public immutable challengePeriod;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    event ProposalCreated(uint256 indexed proposalId, Action action, uint64 executableAt, uint64 challengeEndsAt);
    event ProposalCancelled(uint256 indexed proposalId, bytes32 indexed reasonHash);
    event ProposalExecuted(uint256 indexed proposalId);

    constructor(address admin, IKeiboGovernedEscrow target, uint64 delay, uint64 challenge) {
        require(admin != address(0) && address(target) != address(0), "zero address");
        require(delay >= 1 days && challenge >= 1 hours && challenge <= delay, "unsafe timing");
        escrow = target;
        executionDelay = delay;
        challengePeriod = challenge;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(CHALLENGER_ROLE, admin);
    }

    function propose(Action action, bytes32 role, address account) external onlyRole(PROPOSER_ROLE) returns (uint256 id) {
        if (action == Action.GrantRole || action == Action.RevokeRole) require(account != address(0), "role account required");
        id = proposalCount++;
        uint64 executableAt = uint64(block.timestamp) + executionDelay;
        proposals[id] = Proposal(action, role, account, executableAt, uint64(block.timestamp) + challengePeriod, ProposalState.Pending);
        emit ProposalCreated(id, action, executableAt, uint64(block.timestamp) + challengePeriod);
    }

    function cancel(uint256 proposalId, bytes32 reasonHash) external onlyRole(CHALLENGER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Pending && block.timestamp <= proposal.challengeEndsAt, "not challengeable");
        require(reasonHash != bytes32(0), "reason required");
        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId, reasonHash);
    }

    function execute(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Pending && block.timestamp >= proposal.executableAt, "not executable");
        proposal.state = ProposalState.Executed;
        if (proposal.action == Action.Pause) escrow.pause();
        else if (proposal.action == Action.Unpause) escrow.unpause();
        else if (proposal.action == Action.GrantRole) escrow.grantRole(proposal.role, proposal.account);
        else escrow.revokeRole(proposal.role, proposal.account);
        emit ProposalExecuted(proposalId);
    }
}
