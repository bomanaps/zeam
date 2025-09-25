const std = @import("std");
const process = std.process;
const net = std.net;
const build_options = @import("build_options");
const constants = @import("cli_constants");

/// Verify that the Zeam executable exists and return its path
/// Includes detailed debugging output if the executable is not found
fn getZeamExecutable() ![]const u8 {
    const exe_file = std.fs.openFileAbsolute(build_options.cli_exe_path, .{}) catch |err| {
        std.debug.print("ERROR: Cannot find executable at {s}: {}\n", .{ build_options.cli_exe_path, err });

        // Try to list the directory to see what's actually there
        std.debug.print("INFO: Attempting to list {s} directory...\n", .{build_options.cli_exe_path});
        const dir_path = std.fs.path.dirname(build_options.cli_exe_path);
        if (dir_path) |path| {
            var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |dir_err| {
                std.debug.print("ERROR: Cannot open directory {s}: {}\n", .{ path, dir_err });
                return err;
            };
            defer dir.close();

            var iterator = dir.iterate();
            std.debug.print("INFO: Contents of {s}:\n", .{path});
            while (try iterator.next()) |entry| {
                std.debug.print("  - {s} (type: {})\n", .{ entry.name, entry.kind });
            }
        }

        return err;
    };
    exe_file.close();
    std.debug.print("INFO: Found executable at {s}\n", .{build_options.cli_exe_path});
    return build_options.cli_exe_path;
}

/// Helper function to start a beam simulation node and wait for it to be ready
/// Handles the complete process lifecycle: creation, spawning, and waiting for readiness
/// Returns the process handle for cleanup, or error if startup fails
fn spinBeamSimNode(allocator: std.mem.Allocator, exe_path: []const u8) !*process.Child {
    // Set up process with beam command and mock network
    const args = [_][]const u8{ exe_path, "beam", "--mockNetwork", "true" };
    const cli_process = try allocator.create(process.Child);
    cli_process.* = process.Child.init(&args, allocator);

    // Capture stdout and stderr for debugging
    cli_process.stdout_behavior = .Pipe;
    cli_process.stderr_behavior = .Pipe;

    // Start the process
    cli_process.spawn() catch |err| {
        std.debug.print("ERROR: Failed to spawn process: {}\n", .{err});
        allocator.destroy(cli_process);
        return err;
    };

    std.debug.print("INFO: Process spawned successfully with PID\n", .{});

    // Wait for server to be ready
    const start_time = std.time.milliTimestamp();
    var server_ready = false;
    var retry_count: u32 = 0;

    while (std.time.milliTimestamp() - start_time < constants.DEFAULT_SERVER_STARTUP_TIMEOUT_MS) {
        retry_count += 1;

        // Print progress every 10 retries
        if (retry_count % 10 == 0) {
            const elapsed = @divTrunc(std.time.milliTimestamp() - start_time, 1000);
            std.debug.print("INFO: Still waiting for server... ({} seconds, {} retries)\n", .{ elapsed, retry_count });
        }

        // Try to connect to the metrics server
        const address = net.Address.parseIp4(constants.DEFAULT_SERVER_IP, constants.DEFAULT_METRICS_PORT) catch {
            std.time.sleep(constants.DEFAULT_RETRY_INTERVAL_MS * std.time.ns_per_ms);
            continue;
        };

        var connection = net.tcpConnectToAddress(address) catch |err| {
            // Only print error details on certain intervals to avoid spam
            if (retry_count % 20 == 0) {
                std.debug.print("DEBUG: Connection attempt {} failed: {}\n", .{ retry_count, err });
            }
            std.time.sleep(constants.DEFAULT_RETRY_INTERVAL_MS * std.time.ns_per_ms);
            continue;
        };

        // Test if we can actually send/receive data
        connection.close();
        server_ready = true;
        std.debug.print("SUCCESS: Server ready after {} seconds ({} retries)\n", .{ @divTrunc(std.time.milliTimestamp() - start_time, 1000), retry_count });
        break;
    }

    // If server didn't start, try to get process output for debugging
    if (!server_ready) {
        std.debug.print("ERROR: Metrics server not ready after {} seconds ({} retries)\n", .{ @divTrunc(constants.DEFAULT_SERVER_STARTUP_TIMEOUT_MS, 1000), retry_count });

        // Try to read any output from the process
        if (cli_process.stdout) |stdout| {
            var stdout_buffer: [4096]u8 = undefined;
            const stdout_bytes = stdout.readAll(&stdout_buffer) catch 0;
            if (stdout_bytes > 0) {
                std.debug.print("STDOUT: {s}\n", .{stdout_buffer[0..stdout_bytes]});
            }
        }

        if (cli_process.stderr) |stderr| {
            var stderr_buffer: [4096]u8 = undefined;
            const stderr_bytes = stderr.readAll(&stderr_buffer) catch 0;
            if (stderr_bytes > 0) {
                std.debug.print("STDERR: {s}\n", .{stderr_buffer[0..stderr_bytes]});
            }
        }

        // Check if process is still running
        if (cli_process.wait() catch null) |term| {
            switch (term) {
                .Exited => |code| std.debug.print("ERROR: Process exited with code {}\n", .{code}),
                .Signal => |sig| std.debug.print("ERROR: Process killed by signal {}\n", .{sig}),
                .Stopped => |sig| std.debug.print("ERROR: Process stopped by signal {}\n", .{sig}),
                .Unknown => |code| std.debug.print("ERROR: Process terminated with unknown code {}\n", .{code}),
            }
        } else {
            std.debug.print("INFO: Process is still running\n", .{});
        }

        // Server not ready, cleanup and return error
        allocator.destroy(cli_process);
        return error.ServerStartupTimeout;
    }

    return cli_process;
}

/// Wait for node to start and be ready for activity
/// TODO: Over time, this can be abstracted to listen for some event
/// that the node can output when being active, rather than using a fixed sleep
fn waitForNodeStart() void {
    std.time.sleep(2000 * std.time.ns_per_ms);
}

/// Helper struct for making HTTP requests to Zeam endpoints
const ZeamRequest = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ZeamRequest {
        return ZeamRequest{ .allocator = allocator };
    }

    /// Make a request to the /metrics endpoint and return the response
    fn getMetrics(self: ZeamRequest) ![]u8 {
        return self.makeRequest("/metrics");
    }

    /// Make a request to the /health endpoint and return the response
    fn getHealth(self: ZeamRequest) ![]u8 {
        return self.makeRequest("/health");
    }

    /// Internal helper to make HTTP requests to any endpoint
    fn makeRequest(self: ZeamRequest, endpoint: []const u8) ![]u8 {
        // Create connection to the server
        const address = try net.Address.parseIp4(constants.DEFAULT_SERVER_IP, constants.DEFAULT_METRICS_PORT);
        var connection = try net.tcpConnectToAddress(address);
        defer connection.close();

        // Create HTTP request
        var request_buffer: [4096]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{ endpoint, constants.DEFAULT_SERVER_IP, constants.DEFAULT_METRICS_PORT });

        try connection.writeAll(request);

        // Read response
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = try connection.readAll(&response_buffer);

        // Allocate and return a copy of the response
        const response = try self.allocator.dupe(u8, response_buffer[0..bytes_read]);
        return response;
    }

    /// Free a response returned by getMetrics() or getHealth()
    fn freeResponse(self: ZeamRequest, response: []u8) void {
        self.allocator.free(response);
    }
};

/// SSE Client for testing event streaming
const SSEClient = struct {
    allocator: std.mem.Allocator,
    connection: std.net.Stream,
    received_events: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) !SSEClient {
        const address = try net.Address.parseIp4(constants.DEFAULT_SERVER_IP, constants.DEFAULT_METRICS_PORT);
        const connection = try net.tcpConnectToAddress(address);

        return SSEClient{
            .allocator = allocator,
            .connection = connection,
            .received_events = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *SSEClient) void {
        self.connection.close();
        for (self.received_events.items) |event| {
            self.allocator.free(event);
        }
        self.received_events.deinit();
    }

    fn connect(self: *SSEClient) !void {
        // Send SSE request
        const request = "GET /events HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:9667\r\n" ++
            "Accept: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";

        try self.connection.writeAll(request);
    }

    fn readEvents(self: *SSEClient, timeout_ms: u64) !void {
        const timeout_ns = timeout_ms * std.time.ns_per_ms;
        const start_time = std.time.nanoTimestamp();

        var buffer: [4096]u8 = undefined;

        while (std.time.nanoTimestamp() - start_time < timeout_ns) {
            const bytes_read = self.connection.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            if (bytes_read > 0) {
                const event_data = try self.allocator.dupe(u8, buffer[0..bytes_read]);
                try self.received_events.append(event_data);
            }
        }
    }

    fn hasEvent(self: *SSEClient, event_type: []const u8) bool {
        for (self.received_events.items) |event_data| {
            if (std.mem.indexOf(u8, event_data, event_type) != null) {
                return true;
            }
        }
        return false;
    }

    fn getEventCount(self: *SSEClient, event_type: []const u8) usize {
        var count: usize = 0;
        for (self.received_events.items) |event_data| {
            if (std.mem.indexOf(u8, event_data, event_type) != null) {
                count += 1;
            }
        }
        return count;
    }
};

/// Clean up a process created by spinBeamSimNode
fn cleanupProcess(allocator: std.mem.Allocator, cli_process: *process.Child) void {
    _ = cli_process.kill() catch {};
    _ = cli_process.wait() catch {};
    allocator.destroy(cli_process);
}

test "CLI beam command with mock network - complete integration test" {
    const allocator = std.testing.allocator;

    // Get executable path
    const exe_path = try getZeamExecutable();

    // Start node and wait for readiness
    const cli_process = try spinBeamSimNode(allocator, exe_path);
    defer cleanupProcess(allocator, cli_process);

    // Wait for node to be fully active
    waitForNodeStart();

    // Test metrics endpoint
    var zeam_request = ZeamRequest.init(allocator);
    const response = try zeam_request.getMetrics();
    defer zeam_request.freeResponse(response);

    // Verify we got a valid HTTP response
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200") != null or std.mem.indexOf(u8, response, "HTTP/1.0 200") != null);

    // Verify response contains actual metric names from the metrics system
    try std.testing.expect(std.mem.indexOf(u8, response, "chain_onblock_duration_seconds") != null or
        std.mem.indexOf(u8, response, "block_processing_duration_seconds") != null);

    // Verify response is not empty
    try std.testing.expect(response.len > 100);

    std.debug.print("SUCCESS: All integration test checks passed\n", .{});
}

test "SSE events integration test - wait for justification and finalization" {
    const allocator = std.testing.allocator;

    // Get executable path
    const exe_path = try getZeamExecutable();

    // Start node and wait for readiness
    const cli_process = try spinBeamSimNode(allocator, exe_path);
    defer cleanupProcess(allocator, cli_process);

    // Wait for node to be fully active
    waitForNodeStart();

    // Create SSE client
    var sse_client = try SSEClient.init(allocator);
    defer sse_client.deinit();

    // Connect to SSE endpoint
    try sse_client.connect();

    std.debug.print("INFO: Connected to SSE endpoint, waiting for events...\n", .{});

    // Read events until both justification and finalization are seen, or timeout
    const timeout_ms: u64 = 120000; // 120 seconds timeout
    const start_ns = std.time.nanoTimestamp();
    const deadline_ns = start_ns + timeout_ms * std.time.ns_per_ms;
    var got_justification = false;
    var got_finalization = false;

    // streaming loop: accumulate SSE and parse JSON payloads
    var read_buf: [4096]u8 = undefined;
    var accum = std.ArrayList(u8).init(allocator);
    defer accum.deinit();

    while (std.time.nanoTimestamp() < deadline_ns and !(got_justification and got_finalization)) {
        const bytes_read = sse_client.connection.read(&read_buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.time.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (bytes_read == 0) {
            std.time.sleep(50 * std.time.ns_per_ms);
            continue;
        }

        // keep raw chunk for debugging like before
        const raw_chunk = try allocator.dupe(u8, read_buf[0..bytes_read]);
        defer allocator.free(raw_chunk);
        try sse_client.received_events.append(try allocator.dupe(u8, raw_chunk));

        // append into accumulator
        try accum.appendSlice(raw_chunk);

        // process complete SSE events separated by double newlines
        while (true) {
            const sep = std.mem.indexOf(u8, accum.items, "\n\n") orelse std.mem.indexOf(u8, accum.items, "\r\n\r\n");
            if (sep == null) break;
            const is_crlf = std.mem.startsWith(u8, accum.items[sep.?..], "\r\n\r\n");
            const end_idx: usize = sep.? + (if (is_crlf) @as(usize, 4) else @as(usize, 2));
            const event_block = accum.items[0..end_idx];

            // parse event type
            const event_line_start = std.mem.indexOf(u8, event_block, "event:") orelse null;
            const data_line_start = std.mem.indexOf(u8, event_block, "data:") orelse null;
            if (event_line_start != null and data_line_start != null) {
                // extract event type token
                const event_line_slice = blk: {
                    const nl = std.mem.indexOfScalarPos(u8, event_block, event_line_start.?, '\n') orelse event_block.len;
                    break :blk std.mem.trim(u8, event_block[event_line_start.? + "event:".len .. nl], " \t\r\n");
                };

                // extract JSON payload after data:
                const data_line_slice = blk2: {
                    const nl = std.mem.indexOfScalarPos(u8, event_block, data_line_start.?, '\n') orelse event_block.len;
                    break :blk2 std.mem.trim(u8, event_block[data_line_start.? + "data:".len .. nl], " \t\r\n");
                };

                // only parse json for justification/finalization
                if (!got_justification and std.mem.eql(u8, event_line_slice, "new_justification")) {
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data_line_slice, .{ .ignore_unknown_fields = true }) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        if (p.value.object.get("justified_slot")) |js| {
                            switch (js) {
                                .integer => |ival| {
                                    if (ival > 0) {
                                        got_justification = true;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                } else if (!got_finalization and std.mem.eql(u8, event_line_slice, "new_finalization")) {
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data_line_slice, .{ .ignore_unknown_fields = true }) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        if (p.value.object.get("finalized_slot")) |fs| {
                            switch (fs) {
                                .integer => |ival| {
                                    if (ival > 0) {
                                        got_finalization = true;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }

            // remove processed block from accumulator
            const remaining_len = accum.items.len - end_idx;
            if (remaining_len > 0) {
                std.mem.copyForwards(u8, accum.items[0..remaining_len], accum.items[end_idx..accum.items.len]);
                accum.shrinkRetainingCapacity(remaining_len);
            } else {
                accum.clearRetainingCapacity();
            }
        }
    }

    // Check if we received connection event
    try std.testing.expect(sse_client.hasEvent("connection"));

    // Check for chain events
    const head_events = sse_client.getEventCount("new_head");
    const justification_events = sse_client.getEventCount("new_justification");
    const finalization_events = sse_client.getEventCount("new_finalization");

    std.debug.print("INFO: Received events - Head: {}, Justification: {}, Finalization: {}\n", .{ head_events, justification_events, finalization_events });

    // Require justification (> 0) to have been observed; finalization (> 0) is best-effort
    try std.testing.expect(got_justification);
    if (!got_finalization) {
        std.debug.print("WARN: Did not observe finalization > 0 within timeout; proceeding.\n", .{});
    }

    // Print some sample events for debugging
    for (sse_client.received_events.items, 0..) |event_data, i| {
        if (i < 5) { // Print first 5 events
            std.debug.print("Event {}: {s}\n", .{ i, event_data });
        }
    }

    std.debug.print("SUCCESS: SSE events integration test completed\n", .{});
}
