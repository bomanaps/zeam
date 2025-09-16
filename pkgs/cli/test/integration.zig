const std = @import("std");
const process = std.process;
const net = std.net;
const build_options = @import("build_options");

test "CLI beam command with mock network - complete integration test" {
    const allocator = std.testing.allocator;

    // Start CLI with beam command and mock network - use build option for executable path
    const args = [_][]const u8{ build_options.cli_exe_path, "beam", "--mockNetwork", "true" };
    var cli_process = process.Child.init(&args, allocator);
    defer {
        _ = cli_process.kill() catch {};
        _ = cli_process.wait() catch {};
    }

    // Start the process
    try cli_process.spawn();

    // Wait for metrics server to be ready (with extended timeout for CI)
    const metrics_port: u16 = 9667;
    const start_time = std.time.milliTimestamp();
    const max_wait_time = 60000; // 60 second timeout for CI environments
    const retry_interval = 500; // 500ms between retries
    var server_ready = false;
    var retry_count: u32 = 0;

    while (std.time.milliTimestamp() - start_time < max_wait_time) {
        retry_count += 1;

        // Try to connect to the metrics server
        const address = net.Address.parseIp4("127.0.0.1", metrics_port) catch {
            std.time.sleep(retry_interval * std.time.ns_per_ms);
            continue;
        };

        var connection = net.tcpConnectToAddress(address) catch {
            std.time.sleep(retry_interval * std.time.ns_per_ms);
            continue;
        };

        // Test if we can actually send/receive data
        connection.close();
        server_ready = true;
        break;
    }

    // Provide detailed error message if server didn't start
    if (!server_ready) {
        std.debug.print("Integration test failed: Metrics server not ready after {} seconds ({} retries)\n", .{ max_wait_time / 1000, retry_count });
    }

    // Verify server started successfully
    try std.testing.expect(server_ready);

    // Let the node run for a bit to generate some activity
    std.time.sleep(2000 * std.time.ns_per_ms);

    // Make HTTP request to metrics endpoint
    const address = try net.Address.parseIp4("127.0.0.1", metrics_port);
    var connection = try net.tcpConnectToAddress(address);
    defer connection.close();

    // Create HTTP request
    var request_buffer: [4096]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "GET /metrics HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:9667\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{});

    try connection.writeAll(request);

    // Read response
    var response_buffer: [8192]u8 = undefined;
    const bytes_read = try connection.readAll(&response_buffer);
    const response = response_buffer[0..bytes_read];

    // Verify we got a valid HTTP response
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200") != null or std.mem.indexOf(u8, response, "HTTP/1.0 200") != null);

    // Verify response contains metrics data (should contain some metric names)
    try std.testing.expect(std.mem.indexOf(u8, response, "# HELP") != null or std.mem.indexOf(u8, response, "# TYPE") != null);

    // Verify response is not empty
    try std.testing.expect(response.len > 100);

    // Make multiple requests to verify consistency
    for (0..3) |_| {
        var connection2 = try net.tcpConnectToAddress(address);
        defer connection2.close();

        var request_buffer2: [4096]u8 = undefined;
        const request2 = try std.fmt.bufPrint(&request_buffer2, "GET /metrics HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:9667\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{});

        try connection2.writeAll(request2);

        var response_buffer2: [8192]u8 = undefined;
        const bytes_read2 = try connection2.readAll(&response_buffer2);
        const response2 = response_buffer2[0..bytes_read2];

        // Verify HTTP response is valid
        try std.testing.expect(std.mem.indexOf(u8, response2, "HTTP/1.1 200") != null or std.mem.indexOf(u8, response2, "HTTP/1.0 200") != null);

        // Verify response is not empty
        try std.testing.expect(response2.len > 100);

        // Small delay between requests
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
