// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Non-transferable investment evidence. Off-chain policy remains the compliance authority.
contract KeiboInvestmentReceipt is ERC1155, AccessControl, EIP712 {
    bytes32 public constant RECEIPT_OPERATOR_ROLE = keccak256("RECEIPT_OPERATOR_ROLE");
    bytes32 private constant ELIGIBILITY_TYPEHASH = keccak256(
        "Eligibility(address investor,uint256 campaignId,uint256 amount,uint64 expiresAt,bytes32 policyHash,uint256 nonce)"
    );

    address public immutable eligibilitySigner;
    mapping(address => uint256) public nonces;
    mapping(uint256 => mapping(address => uint256)) public settledAmount;

    event ReceiptIssued(uint256 indexed campaignId, address indexed investor, uint256 amount, bytes32 policyHash);
    event ReceiptRevoked(uint256 indexed campaignId, address indexed investor, uint256 amount, bytes32 reasonHash);

    constructor(string memory receiptUri, address admin, address signer)
        ERC1155(receiptUri)
        EIP712("KEIBO Investment Eligibility", "1")
    {
        require(admin != address(0) && signer != address(0), "zero address");
        eligibilitySigner = signer;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECEIPT_OPERATOR_ROLE, admin);
    }

    function issue(
        address investor,
        uint256 campaignId,
        uint256 amount,
        uint64 expiresAt,
        bytes32 policyHash,
        bytes calldata eligibilitySignature
    ) external onlyRole(RECEIPT_OPERATOR_ROLE) {
        require(investor != address(0) && amount > 0 && expiresAt >= block.timestamp, "invalid receipt");
        require(policyHash != bytes32(0), "policy required");
        uint256 nonce = nonces[investor]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ELIGIBILITY_TYPEHASH, investor, campaignId, amount, expiresAt, policyHash, nonce))
        );
        require(_validEligibilitySignature(digest, eligibilitySignature), "invalid eligibility evidence");
        settledAmount[campaignId][investor] += amount;
        _mint(investor, campaignId, amount, "");
        emit ReceiptIssued(campaignId, investor, amount, policyHash);
    }

    function revoke(address investor, uint256 campaignId, uint256 amount, bytes32 reasonHash)
        external
        onlyRole(RECEIPT_OPERATOR_ROLE)
    {
        require(reasonHash != bytes32(0), "reason required");
        settledAmount[campaignId][investor] -= amount;
        _burn(investor, campaignId, amount);
        emit ReceiptRevoked(campaignId, investor, amount, reasonHash);
    }

    function eligibilityDigest(
        address investor,
        uint256 campaignId,
        uint256 amount,
        uint64 expiresAt,
        bytes32 policyHash,
        uint256 nonce
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(ELIGIBILITY_TYPEHASH, investor, campaignId, amount, expiresAt, policyHash, nonce))
        );
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        require(from == address(0) || to == address(0), "receipts are non-transferable");
        super._update(from, to, ids, values);
    }

    function _validEligibilitySignature(bytes32 digest, bytes calldata signature) private view returns (bool) {
        if (eligibilitySigner.code.length == 0) {
            return ECDSA.recover(digest, signature) == eligibilitySigner;
        }
        (bool success, bytes memory result) = eligibilitySigner.staticcall(
            abi.encodeCall(IERC1271.isValidSignature, (digest, signature))
        );
        return success && result.length >= 32 && abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
