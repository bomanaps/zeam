const std = @import("std");
const Allocator = std.mem.Allocator;
const process = std.process;
const net = std.net;
const build_options = @import("build_options");
const enr_lib = @import("enr");
const enr = enr_lib;
const beam_test = @import("beam_integration_test.zig");
const SSEClient = beam_test.SSEClient;
const ChainEvent = beam_test.ChainEvent;

/// Generates a test ENR with the specified IP and QUIC port
/// Based on the genENR function from tools/src/main.zig
fn generateTestENR(allocator: Allocator, ip: []const u8, quic_port: u16) ![]const u8 {
    // Use a fixed test secret key for deterministic ENRs
    const test_secret_key = "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291";

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var signable_enr = enr.SignableENR.fromSecretKeyString(test_secret_key) catch {
        return error.ENRCreationFailed;
    };

    // Set IP address
    const ip_addr = std.net.Ip4Address.parse(ip, 0) catch {
        return error.InvalidIPAddress;
    };
    const ip_addr_bytes = std.mem.asBytes(&ip_addr.sa.addr);
    signable_enr.set("ip", ip_addr_bytes) catch {
        return error.ENRSetIPFailed;
    };

    // Set QUIC port
    var quic_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &quic_bytes, quic_port, .big);
    signable_enr.set("quic", &quic_bytes) catch {
        return error.ENRSetQUICFailed;
    };

    // Write ENR to buffer
    try enr.writeSignableENR(buffer.writer(), &signable_enr);
    return buffer.toOwnedSlice();
}

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

/// Generates proper genesis directory structure like the genesis tool
pub fn generateGenesisDirectory(allocator: Allocator, config: TestConfig) !void {
    const cwd = std.fs.cwd();

    // Create test directory
    cwd.makeDir(config.test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => return err,
    };

    // Create network subdirectories for each node
    const node0_dir = try std.fmt.allocPrint(allocator, "{s}/node0", .{config.test_dir});
    defer allocator.free(node0_dir);
    const node1_dir = try std.fmt.allocPrint(allocator, "{s}/node1", .{config.test_dir});
    defer allocator.free(node1_dir);

    cwd.makeDir(node0_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    cwd.makeDir(node1_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Generate config.yaml (proper format expected by genesisConfigFromYAML)
    const config_yaml = try std.fmt.allocPrint(allocator,
        \\GENESIS_TIME: {d}
        \\VALIDATOR_COUNT: {d}
    , .{ config.genesis_time, config.num_validators });
    defer allocator.free(config_yaml);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{config.test_dir});
    defer allocator.free(config_path);
    try cwd.writeFile(.{ .sub_path = config_path, .data = config_yaml });

    // Generate nodes.yaml (array format expected by nodesFromYAML) - using programmatically generated ENRs with localhost and different ports
    const enr_0 = try generateTestENR(allocator, "127.0.0.1", 9000);
    defer allocator.free(enr_0);
    const enr_1 = try generateTestENR(allocator, "127.0.0.1", 9001);
    defer allocator.free(enr_1);

    const nodes_yaml = try std.fmt.allocPrint(allocator,
        \\- "{s}"
        \\- "{s}"
    , .{ enr_0, enr_1 });
    defer allocator.free(nodes_yaml);

    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.yaml", .{config.test_dir});
    defer allocator.free(nodes_path);
    try cwd.writeFile(.{ .sub_path = nodes_path, .data = nodes_yaml });

    // Generate validators.yaml (format expected by validatorIndicesFromYAML)
    // Note: validator indices should align with bootnode array indices (0, 1)
    const validators_yaml =
        \\zeam_0:
        \\  - 0
        \\zeam_1:
        \\  - 1
    ;

    const validators_path = try std.fmt.allocPrint(allocator, "{s}/validators.yaml", .{config.test_dir});
    defer allocator.free(validators_path);
    try cwd.writeFile(.{ .sub_path = validators_path, .data = validators_yaml });

    // Generate network keys for each node (required by buildStartOptions)
    // Each node needs a DIFFERENT private key to have a different PeerID in libp2p
    // Using different valid 32-byte (64 hex char) keys for each node
    const key0_content = "0000000000000000000000000000000000000000000000000000000000000001";
    const key1_content = "0000000000000000000000000000000000000000000000000000000000000002";

    const key0_path = try std.fmt.allocPrint(allocator, "{s}/key", .{node0_dir});
    defer allocator.free(key0_path);
    try cwd.writeFile(.{ .sub_path = key0_path, .data = key0_content });

    const key1_path = try std.fmt.allocPrint(allocator, "{s}/key", .{node1_dir});
    defer allocator.free(key1_path);
    try cwd.writeFile(.{ .sub_path = key1_path, .data = key1_content });
}

/// Helper to spawn a zeam node process
fn spawnZeamNodeProcess(
    allocator: Allocator,
    node_id: u32,
    config: TestConfig,
    metrics_port: u16,
) !*process.Child {
    std.debug.print("🔧 Preparing to spawn node {d}...\n", .{node_id});

    const exe_path = build_options.cli_exe_path;
    std.debug.print("📦 Executable path: {s}\n", .{exe_path});

    const network_dir = try std.fmt.allocPrint(allocator, "{s}/node{d}", .{ config.test_dir, node_id });
    defer allocator.free(network_dir);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/node{d}/data", .{ config.test_dir, node_id });
    defer allocator.free(db_path);

    const node_id_str = try std.fmt.allocPrint(allocator, "{d}", .{node_id});
    defer allocator.free(node_id_str);

    const metrics_port_str = try std.fmt.allocPrint(allocator, "{d}", .{metrics_port});
    defer allocator.free(metrics_port_str);

    const genesis_time_str = try std.fmt.allocPrint(allocator, "{d}", .{config.genesis_time});
    defer allocator.free(genesis_time_str);

    // Create database directory
    const cwd = std.fs.cwd();
    cwd.makeDir(db_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const args = &[_][]const u8{
        exe_path,
        "node",
        "--custom_genesis",
        config.test_dir,
        "--node_id",
        node_id_str,
        "--override_genesis_time",
        genesis_time_str,
        "--metrics_enable",
        "--metrics_port",
        metrics_port_str,
        "--network_dir",
        network_dir,
        "--db_path",
        db_path,
    };

    // Debug: Print the command
    std.debug.print("📋 Command for node {d}: {s} {s}", .{ node_id, exe_path, args[1] });
    for (args[2..]) |arg| {
        std.debug.print(" {s}", .{arg});
    }
    std.debug.print("\n", .{});

    const cli_process = try allocator.create(process.Child);
    cli_process.* = process.Child.init(args, allocator);

    std.debug.print("🚀 Spawning node {d} process...\n", .{node_id});

    // Spawn the process
    cli_process.spawn() catch |err| {
        std.debug.print("❌ ERROR: Failed to spawn node {d} process: {}\n", .{ node_id, err });
        allocator.destroy(cli_process);
        return err;
    };

    std.debug.print("✅ Spawned node {d} process successfully\n", .{node_id});
    return cli_process;
}

/// Wait for node startup by checking metrics endpoint
fn waitForNodeStartup(metrics_port: u16, timeout_seconds: u64) !void {
    std.debug.print("⏳ Waiting for node on port {d} to start (timeout: {d}s)...\n", .{ metrics_port, timeout_seconds });

    const start_time = std.time.milliTimestamp();
    const timeout_ms = timeout_seconds * 1000;
    var attempt: usize = 0;

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        attempt += 1;
        if (attempt % 10 == 0) {
            const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
            std.debug.print("⏱️  Still waiting for port {d}... ({d}s elapsed, attempt {d})\n", .{ metrics_port, elapsed, attempt });
        }
        const address = net.Address.parseIp4("127.0.0.1", metrics_port) catch {
            std.time.sleep(1000 * std.time.ns_per_ms);
            continue;
        };

        var connection = net.tcpConnectToAddress(address) catch {
            std.time.sleep(1000 * std.time.ns_per_ms);
            continue;
        };
        connection.close();

        std.debug.print("✅ Node on port {d} is ready\n", .{metrics_port});
        return;
    }

    return error.NodeStartupTimeout;
}

/// Monitor SSE events for finalization using the working SSEClient
fn monitorForFinalization(allocator: Allocator, metrics_port: u16, timeout_seconds: u64) !FinalizationResult {
    std.debug.print("📡 Creating SSE client for port {d}...\n", .{metrics_port});

    // Create SSE client using the proven implementation
    var sse_client = try SSEClient.init(allocator, metrics_port);
    defer sse_client.deinit();

    // Connect to SSE endpoint
    try sse_client.connect();
    std.debug.print("✅ Connected to SSE endpoint, waiting for finalization events...\n", .{});

    // Monitor for finalization
    const deadline_ns = std.time.nanoTimestamp() + (@as(i64, @intCast(timeout_seconds)) * std.time.ns_per_s);
    var event_count: usize = 0;

    while (std.time.nanoTimestamp() < deadline_ns) {
        const event = try sse_client.readEvent();
        if (event) |e| {
            event_count += 1;
            std.debug.print("📨 Event #{d}: {s}\n", .{ event_count, e.event_type });

            // Check for finalization with slot > 0
            if (std.mem.eql(u8, e.event_type, "new_finalization")) {
                if (e.finalized_slot) |slot| {
                    std.debug.print("🔍 Found finalization event with slot {d}\n", .{slot});
                    if (slot > 0) {
                        std.debug.print("🎉 Finalization detected at slot {d}!\n", .{slot});
                        e.deinit(allocator);
                        return FinalizationResult{
                            .finalized = true,
                            .finalization_slot = slot,
                            .finalization_root = [_]u8{0} ** 32,
                            .timeout_reached = false,
                        };
                    }
                }
            }

            // Free the event memory
            e.deinit(allocator);
        }
    }

    std.debug.print("❌ Timeout reached after {d} seconds\n", .{timeout_seconds});
    std.debug.print("📊 Total events received: {d}\n", .{event_count});
    return FinalizationResult{
        .finalized = false,
        .finalization_slot = 0,
        .finalization_root = [_]u8{0} ** 32,
        .timeout_reached = true,
    };
}

/// Runs two nodes as separate processes to finalization
fn runTwoNodesAsProcessesToFinalization(allocator: Allocator, config: TestConfig) !FinalizationResult {
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("🚀 STARTING TWO-NODE PROCESS TEST\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Test config: genesis_time={d}, num_validators={d}, timeout={d}s\n", .{ config.genesis_time, config.num_validators, config.timeout_seconds });
    std.debug.print("\n", .{});

    // Use ports 9669 and 9670 to avoid conflicts with beam_integration_test (which uses 9667/9668)
    const node_0_port: u16 = 9669;
    const node_1_port: u16 = 9670;

    // Spawn node 0
    std.debug.print("▶️  STEP 1: Spawning Node 0 (port {d})\n", .{node_0_port});
    const node_0_process = try spawnZeamNodeProcess(allocator, 0, config, node_0_port);
    defer {
        _ = node_0_process.kill() catch {};
        _ = node_0_process.wait() catch {};
        allocator.destroy(node_0_process);
    }

    // Spawn node 1
    std.debug.print("\n▶️  STEP 2: Spawning Node 1 (port {d})\n", .{node_1_port});
    const node_1_process = try spawnZeamNodeProcess(allocator, 1, config, node_1_port);
    defer {
        std.debug.print("🧹 Cleaning up node 1 process...\n", .{});
        _ = node_1_process.kill() catch {};
        _ = node_1_process.wait() catch {};
        allocator.destroy(node_1_process);
    }

    std.debug.print("\n✅ Both node processes spawned\n", .{});

    // Wait for both nodes to start (check metrics endpoints)
    std.debug.print("\n▶️  STEP 3: Waiting for nodes to start (60s timeout each)...\n", .{});
    try waitForNodeStartup(node_0_port, 60); // 60 second startup timeout
    try waitForNodeStartup(node_1_port, 60);

    std.debug.print("\n✅ Both nodes are ready!\n", .{});

    // Monitor node 0 for finalization via SSE
    std.debug.print("\n▶️  STEP 4: Monitoring for finalization via SSE (timeout: {d}s)...\n", .{config.timeout_seconds});
    const result = try monitorForFinalization(allocator, node_0_port, config.timeout_seconds);

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("🏁 TEST COMPLETE - Finalized: {}\n", .{result.finalized});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});

    return result;
}

/// Cleans up genesis directory and all subdirectories
fn cleanupGenesisDirectory(allocator: Allocator, test_dir: []const u8) !void {
    _ = allocator; // Suppress unused parameter warning

    const cwd = std.fs.cwd();
    cwd.deleteTree(test_dir) catch |err| switch (err) {
        error.AccessDenied, error.FileBusy, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.NotDir, error.SystemResources, error.ReadOnlyFileSystem, error.InvalidUtf8, error.BadPathName, error.NetworkNotFound, error.DeviceBusy, error.NoDevice, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.Unexpected, error.FileTooBig, error.InvalidWtf8 => return err,
        // If directory doesn't exist, that's fine - nothing to clean up
    };
}

test "genesis_generator_two_node_finalization_sim" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    // Configuration for the test
    const config = TestConfig{
        .genesis_time = @as(u64, @intCast(std.time.timestamp())),
        .num_validators = 2, // 2 validators (one per node) - ensures every slot has a proposer
        .test_dir = "test_genesis_two_nodes",
        .timeout_seconds = 300, // 5 minutes
    };

    std.debug.print("🚀 Starting Genesis Generator Two-Node Finalization Test \n", .{});
    std.debug.print("📁 Test directory: {s}\n", .{config.test_dir});
    std.debug.print("⏰ Genesis time: {d}\n", .{config.genesis_time});
    std.debug.print("👥 Number of validators: {d}\n", .{config.num_validators});
    std.debug.print("⏱️  Timeout: {d} seconds\n", .{config.timeout_seconds});

    // Create log directory (required by logger)
    const cwd = std.fs.cwd();
    cwd.makeDir("log") catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => return err,
    };

    // Generate proper genesis directory structure (like genesis tool)
    try generateGenesisDirectory(allocator, config);
    std.debug.print("✅ Generated proper genesis directory structure\n", .{});

    // Run two nodes as separate processes to finalization
    const result = try runTwoNodesAsProcessesToFinalization(allocator, config);

    // Clean up genesis directory
    try cleanupGenesisDirectory(allocator, config.test_dir);

    // Verify the result
    if (result.timeout_reached) {
        std.debug.print("❌ Test failed: Timeout reached after {d} seconds\n", .{config.timeout_seconds});
        return error.TestTimeout;
    }

    if (!result.finalized) {
        std.debug.print("❌ Test failed: No finalization detected\n", .{});
        return error.NoFinalization;
    }

    std.debug.print("✅ Test passed: Finalization detected at slot {d}\n", .{result.finalization_slot});
    std.debug.print("🎉 Genesis Generator Two-Node Finalization Test completed successfully!\n", .{});
}
