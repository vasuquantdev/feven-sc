// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal EIP-1167 clone helper. Matches the standard 55-byte proxy.
library Clones {
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    function predictDeterministicAddress(address implementation, bytes32 salt, address deployer)
        internal
        pure
        returns (address predicted)
    {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash)))));
    }
}
