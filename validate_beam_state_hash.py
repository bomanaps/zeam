#!/usr/bin/env python3
"""
Validate BeamState hash tree root against leanSpec Python reference implementation.

This script mirrors the exact BeamState structure from our Zig implementation
and computes the hash tree root using leanSpec's SSZ implementation to verify
that our Zig SSZ library produces the same result.
"""

from lean_spec.subspecs.ssz.hash import hash_tree_root
from lean_spec.types.container import Container
from lean_spec.types.uint import Uint64, Uint32, Uint8
from lean_spec.types.byte_arrays import Bytes32
from lean_spec.types.collections import SSZList
from lean_spec.types.bitfields import BaseBitlist


# Constants from our Zig implementation
VALIDATOR_REGISTRY_LIMIT = 1 << 12  # 2^12 = 4096
HISTORICAL_ROOTS_LIMIT = 1 << 18    # 2^18 = 262144


# Define BeamStateConfig (matches our Zig BeamStateConfig)
class BeamStateConfig(Container):
    num_validators: Uint32
    genesis_time: Uint64


# Define BeamBlockHeader (matches our Zig BeamBlockHeader)
class BeamBlockHeader(Container):
    slot: Uint64
    proposer_index: Uint32
    parent_root: Bytes32
    state_root: Bytes32
    body_root: Bytes32


# Define Mini3SFCheckpoint (matches our Zig Mini3SFCheckpoint)
class Mini3SFCheckpoint(Container):
    root: Bytes32
    slot: Uint64


# Define concrete bitlist types
class JustifiedSlotsBitlist(BaseBitlist):
    LIMIT = HISTORICAL_ROOTS_LIMIT

class JustificationsValidatorsBitlist(BaseBitlist):
    LIMIT = VALIDATOR_REGISTRY_LIMIT

# Define concrete list types  
class HistoricalBlockHashesList(SSZList):
    ELEMENT_TYPE = Bytes32
    LIMIT = HISTORICAL_ROOTS_LIMIT

class JustificationsRootsList(SSZList):
    ELEMENT_TYPE = Bytes32
    LIMIT = HISTORICAL_ROOTS_LIMIT

# Define BeamState (matches our Zig BeamState structure)
class BeamState(Container):
    config: BeamStateConfig
    slot: Uint64
    latest_block_header: BeamBlockHeader
    
    latest_justified: Mini3SFCheckpoint
    latest_finalized: Mini3SFCheckpoint
    
    # Empty lists with capacity limits (matching our Zig implementation)
    historical_block_hashes: HistoricalBlockHashesList
    justified_slots: JustifiedSlotsBitlist
    justifications_roots: JustificationsRootsList
    justifications_validators: JustificationsValidatorsBitlist


def create_beam_state():
    """Create a BeamState with the same values as our Zig baseState() function."""
    
    # Create config (matches sampleConfig() in Zig)
    config = BeamStateConfig(
        num_validators=Uint32(VALIDATOR_REGISTRY_LIMIT),  # 4096
        genesis_time=Uint64(0)
    )
    
    # Create block header (matches sampleBlockHeader() in Zig)
    block_header = BeamBlockHeader(
        slot=Uint64(0),
        proposer_index=Uint32(0),
        parent_root=Bytes32([0] * 32),
        state_root=Bytes32([0] * 32),
        body_root=Bytes32([0] * 32)
    )
    
    # Create checkpoint (matches sampleCheckpoint() in Zig)
    checkpoint = Mini3SFCheckpoint(
        root=Bytes32([0] * 32),
        slot=Uint64(0)
    )
    
    # Create BeamState with empty collections
    beam_state = BeamState(
        config=config,
        slot=Uint64(0),
        latest_block_header=block_header,
        latest_justified=checkpoint,
        latest_finalized=checkpoint,
        historical_block_hashes=HistoricalBlockHashesList(data=[]),
        justified_slots=JustifiedSlotsBitlist(data=[]),
        justifications_roots=JustificationsRootsList(data=[]),
        justifications_validators=JustificationsValidatorsBitlist(data=[])
    )
    
    return beam_state


def main():
    """Compute and print the hash tree root of our BeamState."""
    print("=== BeamState Hash Tree Root Validation ===")
    print("Creating BeamState with same structure as Zig implementation...")
    
    # Create the beam state
    beam_state = create_beam_state()
    
    print("\nBeamState structure:")
    print(f"  config: {{ num_validators: {beam_state.config.num_validators}, genesis_time: {beam_state.config.genesis_time} }}")
    print(f"  slot: {beam_state.slot}")
    print(f"  latest_block_header: {{ slot: {beam_state.latest_block_header.slot}, proposer_index: {beam_state.latest_block_header.proposer_index} }}")
    print(f"  latest_justified: {{ root: [0x32], slot: {beam_state.latest_justified.slot} }}")
    print(f"  latest_finalized: {{ root: [0x32], slot: {beam_state.latest_finalized.slot} }}")
    print(f"  historical_block_hashes: empty list (capacity: {HISTORICAL_ROOTS_LIMIT})")
    print(f"  justified_slots: empty bitlist (capacity: {HISTORICAL_ROOTS_LIMIT} bits)")
    print(f"  justifications_roots: empty list (capacity: {HISTORICAL_ROOTS_LIMIT})")
    print(f"  justifications_validators: empty bitlist (capacity: {VALIDATOR_REGISTRY_LIMIT} bits)")
    
    print("\nComputing hash tree root using leanSpec...")
    
    # Compute hash tree root
    hash_result = hash_tree_root(beam_state)
    
    # Convert to hex string for comparison
    hash_hex = hash_result.hex()
    
    print(f"\nPython leanSpec hash tree root: {hash_hex}")
    print(f"Zig implementation hash tree root: 933fc69092f542e467681ac6cf9dae4a616ba5ea9c3c61f93cbcaf0be3548e01")
    
    # Compare
    zig_hash = "933fc69092f542e467681ac6cf9dae4a616ba5ea9c3c61f93cbcaf0be3548e01"
    
    if hash_hex == zig_hash:
        print("\n✅ SUCCESS: Hash tree roots match! Our Zig SSZ implementation is correct.")
        return True
    else:
        print(f"\n❌ MISMATCH: Hash tree roots differ.")
        print(f"Difference in hash indicates potential issues with:")
        print("  - Field ordering in struct vs Container")
        print("  - Type encoding (endianness, bit width)")
        print("  - Empty list/bitlist handling")
        print("  - SSZ merkleization algorithm differences")
        return False


if __name__ == "__main__":
    main()
