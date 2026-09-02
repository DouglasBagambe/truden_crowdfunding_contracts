// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface IContributionTarget {
    function contribute(uint256 campaignId, uint128 amount) external;
}

contract FalseReturnERC20 is ERC20 {
    constructor() ERC20("False Return", "FALSE") {
        _mint(msg.sender, 1_000_000);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract ReentrantERC20 is ERC20 {
    IContributionTarget public target;
    uint256 public campaignId;
    bool private attacking;

    constructor() ERC20("Reentrant", "REENTER") {
        _mint(msg.sender, 1_000_000);
    }

    function configure(IContributionTarget newTarget, uint256 newCampaignId) external {
        target = newTarget;
        campaignId = newCampaignId;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!attacking) {
            attacking = true;
            target.contribute(campaignId, 1);
        }
        return super.transferFrom(from, to, value);
    }
}

contract Mock1271Signer is IERC1271 {
    address public immutable owner;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return ECDSA.recover(hash, signature) == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}
