#!/usr/bin/env python3
"""
Debug script to isolate hash tree root differences by testing simpler structures.
"""

from lean_spec.subspecs.ssz.hash import hash_tree_root
from lean_spec.types.container import Container
from lean_spec.types.uint import Uint64, Uint32
from lean_spec.types.byte_arrays import Bytes32

# Test 1: Simple container with just basic types
class SimpleTest(Container):
    slot: Uint64
    proposer_index: Uint32

def test_simple_container():
    print("=== Test 1: Simple Container ===")
    simple = SimpleTest(slot=Uint64(0), proposer_index=Uint32(0))
    hash_result = hash_tree_root(simple)
    print(f"Simple container hash: {hash_result.hex()}")
    return hash_result.hex()

# Test 2: Just the config
class ConfigTest(Container):
    num_validators: Uint32
    genesis_time: Uint64

def test_config():
    print("\n=== Test 2: Config Only ===")
    config = ConfigTest(num_validators=Uint32(4096), genesis_time=Uint64(0))
    hash_result = hash_tree_root(config)
    print(f"Config hash: {hash_result.hex()}")
    return hash_result.hex()

# Test 3: Block header
class BlockHeaderTest(Container):
    slot: Uint64
    proposer_index: Uint32
    parent_root: Bytes32
    state_root: Bytes32
    body_root: Bytes32

def test_block_header():
    print("\n=== Test 3: Block Header ===")
    header = BlockHeaderTest(
        slot=Uint64(0),
        proposer_index=Uint32(0),
        parent_root=Bytes32([0] * 32),
        state_root=Bytes32([0] * 32),
        body_root=Bytes32([0] * 32)
    )
    hash_result = hash_tree_root(header)
    print(f"Block header hash: {hash_result.hex()}")
    return hash_result.hex()

# Test 4: Checkpoint
class CheckpointTest(Container):
    root: Bytes32
    slot: Uint64

def test_checkpoint():
    print("\n=== Test 4: Checkpoint ===")
    checkpoint = CheckpointTest(root=Bytes32([0] * 32), slot=Uint64(0))
    hash_result = hash_tree_root(checkpoint)
    print(f"Checkpoint hash: {hash_result.hex()}")
    return hash_result.hex()

def main():
    print("Debugging hash tree root differences...")
    test_simple_container()
    test_config()
    test_block_header()
    test_checkpoint()
    
    print("\n=== Analysis ===")
    print("These individual component hashes can help isolate where the difference occurs.")
    print("If any of these match between Zig and Python, we know that part is correct.")

if __name__ == "__main__":
    main()
