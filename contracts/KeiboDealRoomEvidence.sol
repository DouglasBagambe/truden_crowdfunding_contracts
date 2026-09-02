// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Tamper-evident hashes only. Off-chain services remain responsible for authorization and storage.
contract KeiboDealRoomEvidence is AccessControl {
    bytes32 public constant EVIDENCE_RECORDER_ROLE = keccak256("EVIDENCE_RECORDER_ROLE");
    mapping(bytes32 => bool) public knownDocuments;

    event DocumentRecorded(uint256 indexed campaignId, bytes32 indexed documentHash, bytes32 indexed accessPolicyHash);
    event AccessEvidenceRecorded(bytes32 indexed documentHash, bytes32 indexed subjectHash, bytes32 indexed actionHash);

    constructor(address admin) {
        require(admin != address(0), "zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EVIDENCE_RECORDER_ROLE, admin);
    }

    function recordDocument(uint256 campaignId, bytes32 documentHash, bytes32 accessPolicyHash)
        external
        onlyRole(EVIDENCE_RECORDER_ROLE)
    {
        require(documentHash != bytes32(0) && accessPolicyHash != bytes32(0), "invalid evidence");
        require(!knownDocuments[documentHash], "document already recorded");
        knownDocuments[documentHash] = true;
        emit DocumentRecorded(campaignId, documentHash, accessPolicyHash);
    }

    function recordAccess(bytes32 documentHash, bytes32 subjectHash, bytes32 actionHash)
        external
        onlyRole(EVIDENCE_RECORDER_ROLE)
    {
        require(knownDocuments[documentHash] && subjectHash != bytes32(0) && actionHash != bytes32(0), "invalid access evidence");
        emit AccessEvidenceRecorded(documentHash, subjectHash, actionHash);
    }
}
