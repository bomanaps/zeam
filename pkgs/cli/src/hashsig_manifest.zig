const std = @import("std");
const xmss = @import("@zeam/xmss");
const types = @import("@zeam/types");
const utils = @import("@zeam/utils");
const Yaml = @import("yaml").Yaml;

// Import BytesToHex from types.utils
const BytesToHex = types.BytesToHex;

pub const ManifestError = error{
    MissingValidatorsArray,
    MissingValidatorName,
    MissingValidatorPrivkey,
    MissingValidatorIndices,
    MissingValidatorAssignments,
    DuplicateValidatorIndex,
    InvalidValidatorIndex,
    InvalidPubkeyLength,
    InvalidGenesisLayout,
    InvalidYamlShape,
};

pub const ManifestOptions = struct {
    allocator: std.mem.Allocator,
    validator_config: Yaml,
    validators: Yaml,
    manifest_path: []const u8,
    pubkeys_path: []const u8,
};

const default_active_epochs: usize = 1024;

const ValidatorEntry = struct {
    name: []const u8,
    indices: []usize,
    pubkey: types.Bytes52,
};

/// Generates validator manifest files from YAML configuration.
///
/// Inputs: `validator_config` (validators with name/privkey) and `validators` (name -> indices mapping).
/// Outputs: `manifest_path` (YAML with 0x-prefixed pubkeys) and `pubkeys_path` (ordered hex list, no 0x prefix).
/// Returns total validator count. Errors: `InvalidYamlShape`, `MissingValidatorsArray`, `MissingValidatorName`, `MissingValidatorPrivkey`, `MissingValidatorIndices`, `InvalidValidatorIndex`, `DuplicateValidatorIndex`, `InvalidPubkeyLength`, `InvalidGenesisLayout`, `MissingValidatorAssignments`.
pub fn generate(opts: ManifestOptions) !usize {
    var entries = try collectValidatorEntries(opts.allocator, opts.validator_config, opts.validators);
    defer {
        for (entries.items) |entry| {
            opts.allocator.free(entry.name);
            opts.allocator.free(entry.indices);
        }
        entries.deinit();
    }

    const total_validator_count = try computeValidatorCount(entries.items);
    try writeManifest(opts.allocator, opts.manifest_path, entries.items);
    try writePubkeyList(opts.allocator, opts.pubkeys_path, entries.items, total_validator_count);
    return total_validator_count;
}

fn collectValidatorEntries(
    allocator: std.mem.Allocator,
    validator_config: Yaml,
    validators: Yaml,
) !std.ArrayList(ValidatorEntry) {
    const docs = validator_config.docs;
    if (docs.items.len == 0) return ManifestError.InvalidYamlShape;
    const config_root = docs.items[0].map;
    const validator_nodes = config_root.get("validators") orelse return ManifestError.MissingValidatorsArray;

    var entries = std.ArrayList(ValidatorEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.indices);
        }
        entries.deinit();
    }

    for (validator_nodes.list) |node_entry| {
        const node_map = node_entry.map;

        const name_value = node_map.get("name") orelse return ManifestError.MissingValidatorName;
        if (name_value != .string) return ManifestError.InvalidYamlShape;
        const privkey_value = node_map.get("privkey") orelse return ManifestError.MissingValidatorPrivkey;
        if (privkey_value != .string) return ManifestError.InvalidYamlShape;

        const name = try allocator.dupe(u8, name_value.string);
        const privkey = privkey_value.string;

        const indices = try collectValidatorIndices(allocator, validators, name);

        const pubkey = try derivePubkeyFromSeed(allocator, privkey);

        try entries.append(.{
            .name = name,
            .indices = indices,
            .pubkey = pubkey,
        });
    }

    return entries;
}

fn derivePubkeyFromSeed(allocator: std.mem.Allocator, seed: []const u8) !types.Bytes52 {
    var keypair = try xmss.KeyPair.generate(allocator, seed, 0, default_active_epochs);
    defer keypair.deinit();

    var buffer: [256]u8 = undefined;
    const written = try keypair.pubkeyToBytes(&buffer);
    if (written != 52) return ManifestError.InvalidPubkeyLength;

    var pubkey: types.Bytes52 = undefined;
    @memcpy(pubkey[0..written], buffer[0..written]);
    return pubkey;
}

fn collectValidatorIndices(
    allocator: std.mem.Allocator,
    validators: Yaml,
    node_name: []const u8,
) ![]usize {
    const docs = validators.docs;
    if (docs.items.len == 0) return ManifestError.InvalidYamlShape;

    const node_entry = docs.items[0].map.get(node_name) orelse return ManifestError.MissingValidatorIndices;
    if (node_entry != .list) return ManifestError.InvalidYamlShape;

    var indices = std.ArrayList(usize).init(allocator);
    errdefer indices.deinit();

    for (node_entry.list) |idx_value| {
        if (idx_value != .int) return ManifestError.InvalidYamlShape;
        if (idx_value.int < 0) return ManifestError.InvalidValidatorIndex;
        try indices.append(@intCast(idx_value.int));
    }

    if (indices.items.len == 0) return ManifestError.MissingValidatorIndices;

    return indices.toOwnedSlice();
}

fn computeValidatorCount(entries: []ValidatorEntry) !usize {
    var max_index: usize = 0;
    var seen_any = false;

    for (entries) |entry| {
        for (entry.indices) |idx| {
            seen_any = true;
            if (idx > max_index) {
                max_index = idx;
            }
        }
    }

    if (!seen_any) return ManifestError.MissingValidatorAssignments;
    return max_index + 1;
}

fn writeManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: []const ValidatorEntry,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.writer();

    try writer.writeAll("validators:\n");
    for (entries) |entry| {
        const hex = try BytesToHex(allocator, &entry.pubkey);
        defer allocator.free(hex);

        try writer.print("  - name: \"{s}\"\n", .{entry.name});
        try writer.print("    pubkey: \"{s}\"\n", .{hex});
        try writer.writeAll("    validator_indices:\n");
        for (entry.indices) |idx| {
            try writer.print("      - {d}\n", .{idx});
        }
    }
}

fn writePubkeyList(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: []const ValidatorEntry,
    total_validators: usize,
) !void {
    if (total_validators == 0) return ManifestError.InvalidGenesisLayout;

    var ordered = try allocator.alloc(types.Bytes52, total_validators);
    defer allocator.free(ordered);
    var filled = try allocator.alloc(bool, total_validators);
    defer allocator.free(filled);
    @memset(filled, false);

    for (entries) |entry| {
        for (entry.indices) |idx| {
            if (idx >= total_validators) return ManifestError.InvalidValidatorIndex;
            if (filled[idx]) return ManifestError.DuplicateValidatorIndex;
            ordered[idx] = entry.pubkey;
            filled[idx] = true;
        }
    }

    for (filled) |flag| {
        if (!flag) return ManifestError.MissingValidatorAssignments;
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.writer();

    for (ordered) |pubkey| {
        // Write as plain hex WITHOUT 0x prefix and WITH quotes
        // The 0x prefix causes YAML parser to treat it as float even when quoted
        const hex_no_prefix = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&pubkey)});
        defer allocator.free(hex_no_prefix);
        try writer.print("  - \"{s}\"\n", .{hex_no_prefix});
    }
}
