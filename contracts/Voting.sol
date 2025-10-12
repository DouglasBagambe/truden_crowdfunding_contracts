// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Voting Contract for DAO Governance
 * @dev Manages proposals, staking-based voting, and treasury operations
 */
contract Voting is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    enum ProposalStatus { Pending, Active, Succeeded, Failed, Executed, Cancelled }
    enum VoteChoice { Abstain, Yes, No }
    enum StakeStatus { Active, Unlocked, Withdrawn }

    // Structs
    struct Proposal {
        uint256 proposalId;
        address proposer;
        string description;
        uint256 targetAmount;
        address targetContract;
        bytes executionData;
        uint256 startTime;
        uint256 endTime;
        uint256 quorumRequired;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
        uint256 totalStaked;
        ProposalStatus status;
        bool executed;
        uint256 executionTime;
    }

    struct Stake {
        address staker;
        uint256 amount;
        VoteChoice vote;
        uint256 stakeTime;
        uint256 weight;
        StakeStatus status;
        bool claimed;
    }

    struct VoterInfo {
        uint256 totalVotingPower;
        uint256 activeStakes;
        uint256 participationCount;
        uint256 lastVoteTime;
        bool hasNFT;
        uint256 nftBalance;
    }

    struct TreasuryBalance {
        address token;
        uint256 totalBalance;
        uint256 lockedAmount;
        uint256 availableAmount;
        uint256 lastUpdateTime;
    }

    // Mappings
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Stake)) public stakes;
    mapping(uint256 => address[]) public proposalStakers;
    mapping(address => VoterInfo) public voters;
    mapping(address => TreasuryBalance) public treasury;
    mapping(address => uint256[]) public userProposals;
    mapping(uint256 => bool) public proposalExists;

    uint256 public proposalCounter;
    uint256 public constant MIN_STAKE_AMOUNT = 1e18; // 1 token minimum
    uint256 public constant MIN_VOTING_PERIOD = 3 days;
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public defaultQuorum = 5000; // 50% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    
    address public escrowContract;
    address public nftContract;
    address public governanceToken;

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 targetAmount,
        uint256 endTime
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteChoice vote,
        uint256 amount,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId, bool success);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event StakeUnlocked(uint256 indexed proposalId, address indexed staker, uint256 amount);
    event StakeWithdrawn(uint256 indexed proposalId, address indexed staker, uint256 amount);
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed depositor);
    event TreasuryPayout(address indexed token, uint256 amount, address indexed recipient);
    event QuorumUpdated(uint256 newQuorum);

    // Main Contructor
    constructor(
        address _governanceToken,
        address _escrowContract,
        address _nftContract
    ) {

    }

    // Functions
    /**
     * @dev Create a new governance proposal
     */
    function proposeProject(
        string memory _description,
        uint256 _targetAmount,
        address _targetContract,
        bytes memory _executionData,
        uint256 _votingDuration
    ) external whenNotPaused returns (uint256) {
        require(hasRole(PROPOSER_ROLE, msg.sender), "Not authorized to propose");
        require(bytes(_description).length > 0, "Description required");
        require(_targetAmount > 0, "Invalid target amount");
        require(_votingDuration >= MIN_VOTING_PERIOD, "Voting period too short");
        require(_votingDuration <= MAX_VOTING_PERIOD, "Voting period too long");

        uint256 proposalId = proposalCounter++;
        uint256 endTime = block.timestamp + _votingDuration;
        
        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            description: _description,
            targetAmount: _targetAmount,
            targetContract: _targetContract,
            executionData: _executionData,
            startTime: block.timestamp,
            endTime: endTime,
            quorumRequired: defaultQuorum,
            yesVotes: 0,
            noVotes: 0,
            abstainVotes: 0,
            totalStaked: 0,
            status: ProposalStatus.Active,
            executed: false,
            executionTime: 0
        });
        
        proposalExists[proposalId] = true;
        userProposals[msg.sender].push(proposalId);
        
        emit ProposalCreated(proposalId, msg.sender, _description, _targetAmount, endTime);
        return proposalId;
    }

    /**
     * @dev Vote on a proposal by staking tokens
     */
    function vote(
        uint256 _proposalId,
        VoteChoice _voteChoice,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        require(proposalExists[_proposalId], "Proposal doesn't exist");
        require(_amount >= MIN_STAKE_AMOUNT, "Stake too low");
        require(_voteChoice != VoteChoice.Abstain || _amount == 0, "Cannot stake for abstain");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp < proposal.endTime, "Voting ended");
        require(stakes[_proposalId][msg.sender].amount == 0, "Already voted");

        uint256 weight = _amount;
        VoterInfo storage voter = voters[msg.sender];
        
        if (nftContract != address(0)) {
            try IERC20(nftContract).balanceOf(msg.sender) returns (uint256 nftBalance) {
                if (nftBalance > 0) {
                    voter.hasNFT = true;
                    voter.nftBalance = nftBalance;
                    weight = (_amount * 15) / 10;
                }
            } catch {}
        }

        IERC20(governanceToken).safeTransferFrom(msg.sender, escrowContract, _amount);
        
        stakes[_proposalId][msg.sender] = Stake({
            staker: msg.sender,
            amount: _amount,
            vote: _voteChoice,
            stakeTime: block.timestamp,
            weight: weight,
            status: StakeStatus.Active,
            claimed: false
        });
        
        proposalStakers[_proposalId].push(msg.sender);

        if (_voteChoice == VoteChoice.Yes) {
            proposal.yesVotes += weight;
        } else if (_voteChoice == VoteChoice.No) {
            proposal.noVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }
        
        proposal.totalStaked += _amount;
        
        voter.totalVotingPower += weight;
        voter.activeStakes++;
        voter.participationCount++;
        voter.lastVoteTime = block.timestamp;
        
        emit VoteCast(_proposalId, msg.sender, _voteChoice, _amount, weight);
    }

    /**
     * @dev Finalize proposal after voting period ends
     */
    function finalizeProposal(uint256 _proposalId) external nonReentrant whenNotPaused {
        require(proposalExists[_proposalId], "Proposal doesn't exist");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp >= proposal.endTime, "Voting still active");
        require(!proposal.executed, "Already executed");

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes + proposal.abstainVotes;
        uint256 requiredVotes = (proposal.targetAmount * proposal.quorumRequired) / BASIS_POINTS;
        bool quorumReached = totalVotes >= requiredVotes;
        
        bool passed = quorumReached && proposal.yesVotes > proposal.noVotes;

        if (passed) {
            proposal.status = ProposalStatus.Succeeded;
            
            if (proposal.targetContract != address(0) && proposal.executionData.length > 0) {
                (bool success, ) = proposal.targetContract.call(proposal.executionData);
                if (success) {
                    proposal.executed = true;
                    proposal.executionTime = block.timestamp;
                    proposal.status = ProposalStatus.Executed;
                }
                emit ProposalExecuted(_proposalId, success);
            }
            
            _unlockStakesToProject(_proposalId);
        } else {
            proposal.status = ProposalStatus.Failed;
            _unlockStakesToVoters(_proposalId);
        }
    }

    /**
     * @dev Internal function to unlock stakes to project on success
     */
    function _unlockStakesToProject(uint256 _proposalId) internal {
        address[] memory stakers = proposalStakers[_proposalId];
        
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            Stake storage stake = stakes[_proposalId][staker];
            
            if (stake.status == StakeStatus.Active && stake.amount > 0) {
                stake.status = StakeStatus.Unlocked;
                emit StakeUnlocked(_proposalId, staker, stake.amount);
            }
        }
    }

    /**
     * @dev Internal function to unlock stakes back to voters on failure
     */
    function _unlockStakesToVoters(uint256 _proposalId) internal {
        address[] memory stakers = proposalStakers[_proposalId];
        
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            Stake storage stake = stakes[_proposalId][staker];
            
            if (stake.status == StakeStatus.Active && stake.amount > 0) {
                stake.status = StakeStatus.Unlocked;
                emit StakeUnlocked(_proposalId, staker, stake.amount);
            }
        }
    }

    /**
     * @dev Withdraw unlocked stake
     */
    function withdrawStake(uint256 _proposalId) external nonReentrant whenNotPaused {
        Stake storage stake = stakes[_proposalId][msg.sender];
        require(stake.amount > 0, "No stake found");
        require(stake.status == StakeStatus.Unlocked, "Stake not unlocked");
        require(!stake.claimed, "Already withdrawn");
        
        uint256 amount = stake.amount;
        stake.status = StakeStatus.Withdrawn;
        stake.claimed = true;
        
        VoterInfo storage voter = voters[msg.sender];
        voter.activeStakes--;
        
        emit StakeWithdrawn(_proposalId, msg.sender, amount);
    }

    /**
     * @dev Deposit funds to treasury
     */
    function depositTreasury(
        address _token,
        uint256 _amount
    ) external payable nonReentrant whenNotPaused {
        require(_amount > 0 || msg.value > 0, "Invalid amount");
        
        if (_token == address(0)) {
            require(msg.value > 0, "No ETH sent");
            _updateTreasuryBalance(address(0), msg.value);
            emit TreasuryDeposit(address(0), msg.value, msg.sender);
        } else {
            require(_amount > 0, "Invalid token amount");
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            _updateTreasuryBalance(_token, _amount);
            emit TreasuryDeposit(_token, _amount, msg.sender);
        }
    }

    /**
     * @dev Internal function to update treasury balance
     */
    function _updateTreasuryBalance(address _token, uint256 _amount) internal {
        TreasuryBalance storage balance = treasury[_token];
        balance.token = _token;
        balance.totalBalance += _amount;
        balance.availableAmount += _amount;
        balance.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Execute treasury payout
     */
    function executePayout(
        address _token,
        address _recipient,
        uint256 _amount
    ) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) whenNotPaused {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        
        TreasuryBalance storage balance = treasury[_token];
        require(balance.availableAmount >= _amount, "Insufficient treasury funds");
        
        balance.availableAmount -= _amount;
        balance.lastUpdateTime = block.timestamp;
        
        if (_token == address(0)) {
            payable(_recipient).transfer(_amount);
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }
        
        emit TreasuryPayout(_token, _amount, _recipient);
    }

    /**
     * @dev Cancel a proposal (admin only)
     */
    function cancelProposal(uint256 _proposalId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(proposalExists[_proposalId], "Proposal doesn't exist");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Active || proposal.status == ProposalStatus.Pending, 
                "Cannot cancel");
        
        proposal.status = ProposalStatus.Cancelled;
        _unlockStakesToVoters(_proposalId);
        
        emit ProposalCancelled(_proposalId, msg.sender);
    }

    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 _proposalId) external view returns (
        address proposer,
        string memory description,
        uint256 targetAmount,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 endTime,
        ProposalStatus status
    ) {
        require(proposalExists[_proposalId], "Proposal doesn't exist");
        Proposal storage proposal = proposals[_proposalId];
        
        return (
            proposal.proposer,
            proposal.description,
            proposal.targetAmount,
            proposal.yesVotes,
            proposal.noVotes,
            proposal.endTime,
            proposal.status
        );
    }

    /**
     * @dev Get stake information for a user
     */
    function getStake(uint256 _proposalId, address _staker) external view returns (
        uint256 amount,
        VoteChoice voteChoice,
        uint256 weight,
        StakeStatus status,
        bool claimed
    ) {
        Stake storage stake = stakes[_proposalId][_staker];
        return (
            stake.amount,
            stake.vote,
            stake.weight,
            stake.status,
            stake.claimed
        );
    }

    /**
     * @dev Get voter information
     */
    function getVoterInfo(address _voter) external view returns (
        uint256 totalVotingPower,
        uint256 activeStakes,
        uint256 participationCount,
        bool hasNFT
    ) {
        VoterInfo storage voter = voters[_voter];
        return (
            voter.totalVotingPower,
            voter.activeStakes,
            voter.participationCount,
            voter.hasNFT
        );
    }

    /**
     * @dev Get treasury balance for a token
     */
    function getTreasuryBalance(address _token) external view returns (
        uint256 totalBalance,
        uint256 lockedAmount,
        uint256 availableAmount
    ) {
        TreasuryBalance storage balance = treasury[_token];
        return (
            balance.totalBalance,
            balance.lockedAmount,
            balance.availableAmount
        );
    }

    /**
     * @dev Get all proposals created by a user
     */
    function getUserProposals(address _user) external view returns (uint256[] memory) {
        return userProposals[_user];
    }

    /**
     * @dev Get all stakers for a proposal
     */
    function getProposalStakers(uint256 _proposalId) external view returns (address[] memory) {
        require(proposalExists[_proposalId], "Proposal doesn't exist");
        return proposalStakers[_proposalId];
    }

    /**
     * @dev Set default quorum percentage (admin only)
     */
    function setDefaultQuorum(uint256 _quorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_quorum > 0 && _quorum <= BASIS_POINTS, "Invalid quorum");
        defaultQuorum = _quorum;
        emit QuorumUpdated(_quorum);
    }

    /**
     * @dev Set escrow contract address (admin only)
     */
    function setEscrowContract(address _escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_escrow != address(0), "Invalid escrow address");
        escrowContract = _escrow;
    }

    /**
     * @dev Set NFT contract address (admin only)
     */
    function setNFTContract(address _nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nftContract = _nft;
    }

    /**
     * @dev Pause contract (admin only)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract (admin only)
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Check interface support
     */
    function supportsInterface(bytes4 interfaceId) 
        public view override(AccessControl) returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable {
        _updateTreasuryBalance(address(0), msg.value);
        emit TreasuryDeposit(address(0), msg.value, msg.sender);
    }

}