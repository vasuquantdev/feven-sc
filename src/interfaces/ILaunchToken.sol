// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ILaunchToken {
    struct Socials {
        string telegram;
        string twitter;
        string discord;
        string website;
        string extra;
    }

    struct Profile {
        string logo;
        string description;
        Socials socials;
    }

    function initialize(
        address creator,
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI,
        Profile calldata profile,
        uint256 supply
    ) external;

    function initializePool(bytes32 poolId, address quote, uint32 streamDuration, uint16 pushBountyBps, uint128 pushFloor)
        external;

    function burn(uint256 amount) external;
    function factory() external view returns (address);
    function quote() external view returns (address);
}
