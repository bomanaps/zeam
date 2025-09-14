const std = @import("std");
const process = std.process;
const net = std.net;

test "CLI beam command with mock network - complete integration test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start CLI with beam command and mock network
    const args = [_][]const u8{ "./zig-out/bin/zeam", "beam", "--mockNetwork", "true" };
    var cli_process = process.Child.init(&args, allocator);
    defer {
        _ = cli_process.kill() catch {};
        _ = cli_process.wait() catch {};
    }

    // Start the process
    try cli_process.spawn();

    // Wait for metrics server to be ready (with timeout)
    const metrics_port: u16 = 9667;
    const start_time = std.time.milliTimestamp();
    var server_ready = false;

    while (std.time.milliTimestamp() - start_time < 10000) { // 10 second timeout
        const address = net.Address.parseIp4("127.0.0.1", metrics_port) catch {
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };

        var connection = net.tcpConnectToAddress(address) catch {
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        connection.close();
        server_ready = true;
        break;
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
