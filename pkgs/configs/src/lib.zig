const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const params = @import("@zeam/params");
const types = @import("@zeam/types");

const utils = @import("@zeam/utils");
pub const ChainOptions = utils.Partial(utils.MixIn(types.GenesisSpec, types.ChainSpec));

const configs = @import("./configs/mainnet.zig");
const Yaml = @import("yaml").Yaml;
const key_manager_lib = @import("@zeam/key-manager");

pub const Chain = enum { custom };

pub const ChainConfig = struct {
    id: Chain,
    genesis: types.GenesisSpec,
    spec: types.ChainSpec,

    const Self = @This();

    // for custom chains
    pub fn init(chainId: Chain, chainOptsOrNull: ?ChainOptions) !Self {
        switch (chainId) {
            .custom => {
                if (chainOptsOrNull) |*chainOpts| {
                    const genesis = utils.Cast(types.GenesisSpec, chainOpts);
                    // transfer ownership of any allocated memory in chainOpts to spec
                    const spec = utils.Cast(types.ChainSpec, chainOpts);

                    return Self{
                        .id = chainId,
                        .genesis = genesis,
                        .spec = spec,
                    };
                } else {
                    return ChainConfigError.InvalidChainSpec;
                }
            },
        }
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.spec.deinit(allocator);
    }
};

const ChainConfigError = error{
    InvalidChainSpec,
};

const GenesisConfigError = error{
    InvalidYamlShape,
    MissingGenesisTime,
    InvalidGenesisTime,
    MissingValidatorConfig,
    InvalidValidatorPubkeys,
    InvalidValidatorCount,
};

/// Parses genesis configuration from YAML.
///
/// Required: `GENESIS_TIME` (integer >= 0).
/// Optional: `genesis_validators` (list of 104-char hex strings) or `VALIDATOR_COUNT` (integer > 0).
/// If both are present, `genesis_validators` takes precedence.
///
/// Returns `GenesisSpec` with genesis time and validator pubkeys.
/// Errors: `InvalidYamlShape`, `MissingGenesisTime`, `InvalidGenesisTime`, `MissingValidatorConfig`, `InvalidValidatorPubkeys`, `InvalidValidatorCount`.
pub fn genesisConfigFromYAML(
    allocator: Allocator,
    config: Yaml,
    override_genesis_time: ?u64,
) !types.GenesisSpec {
    if (config.docs.items.len == 0) return GenesisConfigError.InvalidYamlShape;
    const root = config.docs.items[0].map;

    const genesis_time_node = root.get("GENESIS_TIME") orelse return GenesisConfigError.MissingGenesisTime;
    var genesis_time: u64 = switch (genesis_time_node) {
        .int => |value| blk: {
            if (value < 0) return GenesisConfigError.InvalidGenesisTime;
            const casted: u64 = @intCast(value);
            break :blk casted;
        },
        else => return GenesisConfigError.InvalidGenesisTime,
    };
    if (override_genesis_time) |override| genesis_time = override;

    if (root.get("genesis_validators")) |pubkeys_node| {
        const pubkeys = try parsePubkeysFromYaml(allocator, pubkeys_node);
        return types.GenesisSpec{
            .genesis_time = genesis_time,
            .validator_pubkeys = pubkeys,
        };
    }

    const validator_count_node = root.get("VALIDATOR_COUNT") orelse return GenesisConfigError.MissingValidatorConfig;
    const validator_count = switch (validator_count_node) {
        .int => |value| blk: {
            if (value <= 0) return GenesisConfigError.InvalidValidatorCount;
            const casted: usize = @intCast(value);
            break :blk casted;
        },
        else => return GenesisConfigError.InvalidValidatorCount,
    };

    const pubkeys = try synthesizePubkeys(allocator, validator_count);
    return types.GenesisSpec{
        .genesis_time = genesis_time,
        .validator_pubkeys = pubkeys,
    };
}

fn parsePubkeysFromYaml(
    allocator: Allocator,
    node: Yaml.Value,
) ![]types.Bytes52 {
    if (node != .list) return GenesisConfigError.InvalidValidatorPubkeys;
    const list = node.list;
    if (list.len == 0) return GenesisConfigError.InvalidValidatorPubkeys;

    var pubkeys = try allocator.alloc(types.Bytes52, list.len);
    errdefer allocator.free(pubkeys);

    for (list, 0..) |item, idx| {
        // The Zig YAML library has a bug where it parses quoted "0x..." as float
        // If any item is not a string, return an error as the YAML is malformed
        if (item != .string) {
            allocator.free(pubkeys);
            return GenesisConfigError.InvalidValidatorPubkeys;
        }
        pubkeys[idx] = try hexToBytes52(item.string);
    }

    return pubkeys;
}

fn hexToBytes52(input: []const u8) !types.Bytes52 {
    // Remove 0x prefix if present
    const hex_str = if (std.mem.startsWith(u8, input, "0x"))
        input[2..]
    else
        input;

    if (hex_str.len != 104) return GenesisConfigError.InvalidValidatorPubkeys; // 52 bytes = 104 hex chars
    var bytes: types.Bytes52 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex_str) catch {
        return GenesisConfigError.InvalidValidatorPubkeys;
    };
    return bytes;
}

fn synthesizePubkeys(
    allocator: Allocator,
    count: usize,
) ![]types.Bytes52 {
    var key_manager = try key_manager_lib.getTestKeyManager(allocator, count, 1024);
    defer key_manager.deinit();

    var pubkeys = try allocator.alloc(types.Bytes52, count);
    errdefer allocator.free(pubkeys);

    for (0..count) |i| {
        _ = try key_manager.getPublicKeyBytes(i, pubkeys[i][0..]);
    }

    return pubkeys;
}

// TODO: Enable and update the this test once the YAML parsing for public keys PR is added
// test "load genesis config from yaml" {
//     const yaml_content =
//         \\# Genesis Settings
//         \\GENESIS_TIME: 1704085200
//         \\
//         \\# Validator Settings
//         \\VALIDATOR_COUNT: 9
//     ;
//
//     var yaml: Yaml = .{ .source = yaml_content };
//     defer yaml.deinit(std.testing.allocator);
//     try yaml.load(std.testing.allocator);
//
//     const genesis_config = try genesisConfigFromYAML(yaml, null);
//
//     try std.testing.expect(genesis_config.genesis_time == 1704085200);
//     try std.testing.expect(genesis_config.num_validators() == 9);
//
//     const genesis_config_override = try genesisConfigFromYAML(yaml, 1234);
//     try std.testing.expect(genesis_config_override.genesis_time == 1234);
//     try std.testing.expect(genesis_config_override.num_validators() == 9);
// }

// TODO: Enable and update this test once the keymanager file-reading PR is added (followup PR)
// JSON parsing for genesis config needs to support validator_pubkeys instead of num_validators
// test "custom dev chain" {
//     const dev_spec =
//         \\{"preset": "mainnet", "name": "devchain1", "genesis_time": 1244, "num_validators": 4}
//     ;
//
//     var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena_allocator.deinit();
//
//     const options = json.ParseOptions{
//         .ignore_unknown_fields = true,
//         .allocate = .alloc_if_needed,
//     };
//     const dev_options = (try json.parseFromSlice(ChainOptions, arena_allocator.allocator(), dev_spec, options)).value;
//
//     const dev_config = try ChainConfig.init(Chain.custom, dev_options);
//     std.debug.print("dev config = {any}\n", .{dev_config});
//     std.debug.print("chainoptions = {any}\n", .{ChainOptions{}});
// }
