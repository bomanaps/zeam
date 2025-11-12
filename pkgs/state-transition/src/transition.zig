const ssz = @import("ssz");
const std = @import("std");
const types = @import("@zeam/types");

const zeam_utils = @import("@zeam/utils");
const xmss = @import("@zeam/xmss");
const zeam_metrics = @import("@zeam/metrics");

const Allocator = std.mem.Allocator;
const StateTransitionError = types.StateTransitionError;

// put the active logs at debug level for now by default
pub const StateTransitionOpts = struct {
    // signatures are validated outside for keeping life simple for the STF prover
    // we will trust client will validate them however the flag here
    // represents such dependency and assumption for STF
    validSignatures: bool = true,
    validateResult: bool = true,
    logger: zeam_utils.ModuleLogger,
};

// pub fn process_epoch(state: types.BeamState) void {
//     // right now nothing to do
//     _ = state;
//     return;
// }

pub fn is_justifiable_slot(finalized: types.Slot, candidate: types.Slot) !bool {
    if (candidate < finalized) {
        return StateTransitionError.InvalidJustifiableSlot;
    }

    const delta: f32 = @floatFromInt(candidate - finalized);
    if (delta <= 5) {
        return true;
    }
    const delta_x2: f32 = @mod(std.math.pow(f32, delta, 0.5), 1);
    if (delta_x2 == 0) {
        return true;
    }
    const delta_x2_x: f32 = @mod(std.math.pow(f32, delta + 0.25, 0.5), 1);
    if (delta_x2_x == 0.5) {
        return true;
    }

    return false;
}

pub fn apply_raw_block(allocator: Allocator, state: *types.BeamState, block: *types.BeamBlock, logger: zeam_utils.ModuleLogger, opts: StateTransitionOpts) !void {
    _ = opts;
    const transition_timer = zeam_metrics.lean_state_transition_time_seconds.start();
    defer _ = transition_timer.observe();

    try state.process_slots(allocator, block.slot, logger);
    try state.process_block(allocator, block.*, logger);

    logger.debug("extracting state root\n", .{});
    var state_root: [32]u8 = undefined;
    try ssz.hashTreeRoot(*types.BeamState, state, &state_root, allocator);
    block.state_root = state_root;
}

pub fn verifySignatures(
    allocator: Allocator,
    state: *const types.BeamState,
    signed_block: *const types.SignedBlockWithAttestation,
) !void {
    const attestations = signed_block.message.block.body.attestations.constSlice();
    const signatures = signed_block.signature.constSlice();

    // Must have exactly one signature per attestation plus one for proposer
    if (attestations.len + 1 != signatures.len) {
        return StateTransitionError.InvalidBlockSignatures;
    }

    // Verify all body attestations
    for (attestations, 0..) |attestation, i| {
        try verifySingleAttestation(
            allocator,
            state,
            &attestation,
            &signatures[i],
        );
    }

    // Verify proposer attestation (last signature in the list)
    try verifySingleAttestation(
        allocator,
        state,
        &signed_block.message.proposer_attestation,
        &signatures[signatures.len - 1],
    );
}

pub fn verifySingleAttestation(
    allocator: Allocator,
    state: *const types.BeamState,
    attestation: *const types.Attestation,
    signatureBytes: *const types.Bytes4000,
) !void {
    const validatorIndex: usize = @intCast(attestation.validator_id);
    const validators = state.validators.constSlice();
    if (validatorIndex >= validators.len) {
        return StateTransitionError.InvalidValidatorId;
    }

    const validator = &validators[validatorIndex];
    const pubkey = validator.getPubkey();

    var message: [32]u8 = undefined;
    try ssz.hashTreeRoot(types.Attestation, attestation.*, &message, allocator);

    const epoch: u32 = @intCast(attestation.data.slot);

    try xmss.verifyBincode(pubkey, &message, epoch, signatureBytes);
}

pub fn apply_transition(allocator: Allocator, state: *types.BeamState, block: types.BeamBlock, opts: StateTransitionOpts) !void {
    const transition_timer = zeam_metrics.lean_state_transition_time_seconds.start();
    defer _ = transition_timer.observe();

    opts.logger.debug("applying  state transition state-slot={d} block-slot={d}\n", .{ state.slot, block.slot });

    const validSignatures = opts.validSignatures;
    if (!validSignatures) {
        return StateTransitionError.InvalidBlockSignatures;
    }

    try state.process_slots(allocator, block.slot, opts.logger);
    try state.process_block(allocator, block, opts.logger);

    if (opts.validateResult) {
        var state_root: [32]u8 = undefined;
        try ssz.hashTreeRoot(*types.BeamState, state, &state_root, allocator);
        if (!std.mem.eql(u8, &state_root, &block.state_root)) {
            opts.logger.debug("state root={x:02} block root={x:02}\n", .{ state_root, block.state_root });
            return StateTransitionError.InvalidPostState;
        }
    }
}
