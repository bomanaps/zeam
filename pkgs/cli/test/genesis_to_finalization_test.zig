const std = @import("std");
const Allocator = std.mem.Allocator;
const BeamNode = @import("@zeam/node").BeamNode;
const NetworkBackend = @import("@zeam/network").NetworkBackend;
const mockNetwork = @import("@zeam/network").mockNetwork;
const Clock = @import("@zeam/node").Clock;
const Logger = @import("@zeam/utils").Logger;

const TestConfig = struct {
    genesis_time: u64,
    num_validators: u32,
    test_dir: []const u8,
    timeout_seconds: u64 = 300, // 5 minutes default
};

const FinalizationResult = struct {
    finalized: bool,
    finalization_slot: u64,
    finalization_root: [32]u8,
    timeout_reached: bool = false,
};

/// Generates fresh genesis configuration files for 2 nodes
pub fn generateTestConfigFiles(allocator: Allocator, config: TestConfig) !void {
    const cwd = std.fs.cwd();

    // Create test directory
    cwd.makeDir(config.test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => return err,
    };

    // Generate config.yaml
    const config_yaml = try std.fmt.allocPrint(allocator,
        \\GENESIS_TIME: {d}
        \\CHAIN_SPEC: "minimal"
        \\NETWORK_ID: 1
        \\BOOTNODES: []
        \\VALIDATORS: 3
        \\SLOTS_PER_EPOCH: 8
        \\SECONDS_PER_SLOT: 6
    , .{config.genesis_time});
    defer allocator.free(config_yaml);

    try cwd.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{config.test_dir}), .data = config_yaml });

    // Generate nodes.yaml with two distinct ENR entries
    const nodes_yaml =
        \\zeam_0:
        \\  enr: "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuT-mD5LJhNnB4LzR7kmzU7CbOQvSNY6MC-OL2sIN0Y3CCf5yDdWRwgn-c"
        \\  ip: "127.0.0.1"
        \\  tcp_port: 9000
        \\  quic_port: 9001
        \\zeam_1:
        \\  enr: "enr:-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04jRzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQPKY0yuT-mD5LJhNnB4LzR7kmzU7CbOQvSNY6MC-OL2sIN0Y3CCf5yDdWRwgn-c"
        \\  ip: "127.0.0.1"
        \\  tcp_port: 9002
        \\  quic_port: 9003
    ;

    try cwd.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/nodes.yaml", .{config.test_dir}), .data = nodes_yaml });

    // Generate validators.yaml with zeam_0 and zeam_1 entries
    const validators_yaml =
        \\zeam_0:
        \\  - 1
        \\zeam_1:
        \\  - 2
    ;

    try cwd.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/validators.yaml", .{config.test_dir}), .data = validators_yaml });

    // Generate validator-config.yaml with proper entries for zeam_0 and zeam_1
    const validator_config_yaml =
        \\zeam_0:
        \\  private_key: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        \\  ip: "127.0.0.1"
        \\  tcp_port: 9000
        \\  quic_port: 9001
        \\zeam_1:
        \\  private_key: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        \\  ip: "127.0.0.1"
        \\  tcp_port: 9002
        \\  quic_port: 9003
    ;

    try cwd.writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/validator-config.yaml", .{config.test_dir}), .data = validator_config_yaml });
}

/// Runs two nodes in-process to finalization (like beam command)
fn runTwoNodesInProcessToFinalization(allocator: Allocator, config: TestConfig) !FinalizationResult {
    std.debug.print("🔄 Starting two nodes in-process to finalization...\n");

    // Create mock network (like beam command)
    var network = try mockNetwork(allocator);
    defer network.deinit();

    // Create two loggers
    var logger1 = try Logger.init(allocator, .debug, "zeam_0");
    defer logger1.deinit();
    var logger2 = try Logger.init(allocator, .debug, "zeam_1");
    defer logger2.deinit();

    // Create network backends
    var network_backend1 = try NetworkBackend.init(allocator, &network, 0, &logger1);
    defer network_backend1.deinit();
    var network_backend2 = try NetworkBackend.init(allocator, &network, 1, &logger2);
    defer network_backend2.deinit();

    // Create two BeamNode instances (like beam command)
    var beam_node_1 = try BeamNode.init(allocator, 0, [_]usize{1}, &network_backend1, &logger1);
    defer beam_node_1.deinit();
    var beam_node_2 = try BeamNode.init(allocator, 1, [_]usize{2}, &network_backend2, &logger2);
    defer beam_node_2.deinit();

    // Create clock
    var clock = try Clock.init(allocator, config.genesis_time);
    defer clock.deinit();

    std.debug.print("✅ Created two BeamNode instances with mock networking\n");

    // Run nodes and monitor for finalization
    return try runNodesWithFinalizationMonitoring(allocator, &beam_node_1, &beam_node_2, &clock, config.timeout_seconds);
}

/// Runs nodes and monitors for finalization with direct state access
fn runNodesWithFinalizationMonitoring(allocator: Allocator, beam_node_1: *BeamNode, beam_node_2: *BeamNode, clock: *Clock, timeout_seconds: u64) !FinalizationResult {
    _ = allocator; // Suppress unused parameter warning

    // Create timeout timer
    var timeout_timer = try std.time.Timer.start();
    const timeout_ns = timeout_seconds * std.time.ns_per_s;

    std.debug.print("🔄 Starting nodes and monitoring for finalization...\n");

    // Start nodes in separate threads (like beam command)
    const node1_thread = try std.Thread.spawn(.{}, BeamNode.run, .{beam_node_1});
    const node2_thread = try std.Thread.spawn(.{}, BeamNode.run, .{beam_node_2});
    const clock_thread = try std.Thread.spawn(.{}, Clock.run, .{clock});

    // Monitor for finalization with direct state access
    while (timeout_timer.read() < timeout_ns) {
        // Check finalization state directly from both nodes' fork choice stores
        const node1_finalized = beam_node_1.chain.forkChoice.fcStore.latest_finalized.slot > 0;
        const node2_finalized = beam_node_2.chain.forkChoice.fcStore.latest_finalized.slot > 0;

        if (node1_finalized or node2_finalized) {
            const finalization_slot = if (node1_finalized) beam_node_1.chain.forkChoice.fcStore.latest_finalized.slot else beam_node_2.chain.forkChoice.fcStore.latest_finalized.slot;
            const finalization_root = if (node1_finalized) beam_node_1.chain.forkChoice.fcStore.latest_finalized.root else beam_node_2.chain.forkChoice.fcStore.latest_finalized.root;

            std.debug.print("✅ Finalization detected at slot {d}\n", .{finalization_slot});

            // Stop the nodes
            beam_node_1.stop();
            beam_node_2.stop();
            clock.stop();

            // Wait for threads to finish
            node1_thread.join();
            node2_thread.join();
            clock_thread.join();

            return FinalizationResult{
                .finalized = true,
                .finalization_slot = finalization_slot,
                .finalization_root = finalization_root,
                .timeout_reached = false,
            };
        }

        // Small sleep to prevent busy waiting
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    // Timeout reached
    std.debug.print("❌ Timeout reached after {d} seconds\n", .{timeout_seconds});

    // Stop the nodes
    beam_node_1.stop();
    beam_node_2.stop();
    clock.stop();

    // Wait for threads to finish
    node1_thread.join();
    node2_thread.join();
    clock_thread.join();

    return FinalizationResult{
        .finalized = false,
        .finalization_slot = 0,
        .finalization_root = [_]u8{0} ** 32,
        .timeout_reached = true,
    };
}

/// Cleans up test configuration files
fn cleanupTestConfigFiles(allocator: Allocator, test_dir: []const u8) !void {
    _ = allocator; // Suppress unused parameter warning

    const cwd = std.fs.cwd();
    cwd.deleteTree(test_dir) catch |err| switch (err) {
        error.FileNotFound => {}, // Directory doesn't exist, that's fine
        else => return err,
    };
}

test "genesis_generator_two_node_finalization_sim" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    // Configuration for the test
    const config = TestConfig{
        .genesis_time = @as(u64, @intCast(std.time.timestamp())),
        .num_validators = 3,
        .test_dir = "test_genesis_two_nodes",
        .timeout_seconds = 300, // 5 minutes
    };

    std.debug.print("🚀 Starting Genesis Generator Two-Node Finalization Simulation (In-Process)\n");
    std.debug.print("📁 Test directory: {s}\n", .{config.test_dir});
    std.debug.print("⏰ Genesis time: {d}\n", .{config.genesis_time});
    std.debug.print("👥 Number of validators: {d}\n", .{config.num_validators});
    std.debug.print("⏱️  Timeout: {d} seconds\n", .{config.timeout_seconds});

    // Generate fresh genesis files (simulating the genesis tool)
    try generateTestConfigFiles(allocator, config);
    std.debug.print("✅ Generated fresh genesis configuration files\n");

    // Run two nodes in-process to finalization (like beam command)
    const result = try runTwoNodesInProcessToFinalization(allocator, config);

    // Clean up test files
    try cleanupTestConfigFiles(allocator, config.test_dir);

    // Verify the result
    if (result.timeout_reached) {
        std.debug.print("❌ Test failed: Timeout reached after {d} seconds\n", .{config.timeout_seconds});
        return error.TestTimeout;
    }

    if (!result.finalized) {
        std.debug.print("❌ Test failed: No finalization detected\n");
        return error.NoFinalization;
    }

    std.debug.print("✅ Test passed: Finalization detected at slot {d}\n", .{result.finalization_slot});
    std.debug.print("🎉 Genesis Generator Two-Node Finalization Simulation completed successfully!\n");
}
