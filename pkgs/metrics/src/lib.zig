const std = @import("std");
const metrics_lib = @import("metrics");

// Platform-specific time function
fn getTimestamp() i128 {
    // For freestanding targets, we might not have access to system time
    // In that case, we'll use a simple counter or return 0
    if (@import("builtin").target.os.tag == .freestanding) {
        // For freestanding environments, we can't measure real time
        // Return 0 for now - in a real implementation you'd want a cycle counter
        return 0;
    } else {
        return std.time.nanoTimestamp();
    }
}

// Global metrics instance
var metrics = metrics_lib.initializeNoop(Metrics);
var g_initialized: bool = false;

const Metrics = struct {
    chain_onblock_duration_seconds: ChainHistogram,
    block_processing_duration_seconds: BlockProcessingHistogram,
    
    const ChainHistogram = metrics_lib.Histogram(f32, &[_]f32{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 });
    const BlockProcessingHistogram = metrics_lib.Histogram(f32, &[_]f32{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 });
};

/// Timer struct returned to the application.
pub const Timer = struct {
    start_time: i128,
    histogram: *const anyopaque, // We'll store which histogram to use
    is_chain: bool,

    /// Stops the timer and records the duration in the histogram.
    pub fn observe(self: Timer) void {
        const end_time = getTimestamp();
        const duration_ns = end_time - self.start_time;
        
        // For freestanding targets where we can't measure time, just record 0
        const duration_seconds = if (duration_ns == 0) 0.0 else @as(f32, @floatFromInt(duration_ns)) / 1_000_000_000.0;
        
        if (self.is_chain) {
            metrics.chain_onblock_duration_seconds.observe(duration_seconds);
        } else {
            metrics.block_processing_duration_seconds.observe(duration_seconds);
        }
    }
};

/// A wrapper struct that exposes a `start` function to match the existing API.
pub const Histogram = struct {
    is_chain: bool,

    pub fn start(self: *const Histogram) Timer {
        return Timer{
            .start_time = getTimestamp(),
            .histogram = undefined, // Not used in this implementation
            .is_chain = self.is_chain,
        };
    }
};

/// The public variables the application interacts with.
/// Calling `.start()` on these will start a new timer.
pub var chain_onblock_duration_seconds: Histogram = Histogram{ .is_chain = true };
pub var block_processing_duration_seconds: Histogram = Histogram{ .is_chain = false };

/// Initializes the metrics system. Must be called once at startup.
pub fn init(allocator: std.mem.Allocator) !void {
    _ = allocator; // Not needed for basic histograms
    if (g_initialized) return;
    
    metrics = .{
        .chain_onblock_duration_seconds = Metrics.ChainHistogram.init("chain_onblock_duration_seconds", .{
            .help = "Time taken to process a block in the chain's onBlock function."
        }, .{}),
        .block_processing_duration_seconds = Metrics.BlockProcessingHistogram.init("block_processing_duration_seconds", .{
            .help = "Time taken to process a block in the state transition function."
        }, .{}),
    };
    
    g_initialized = true;
}

/// Writes metrics to a writer (for Prometheus endpoint).
pub fn writeMetrics(writer: anytype) !void {
    if (!g_initialized) return error.NotInitialized;
    try metrics_lib.write(&metrics, writer);
}

/// Starts a simple HTTP server to serve metrics on /metrics endpoint.
pub fn startListener(allocator: std.mem.Allocator, port: u16) !void {
    if (!g_initialized) return error.NotInitialized;
    
    const ServerContext = struct {
        allocator: std.mem.Allocator,
        port: u16,

        fn run(self: *@This()) !void {
            const address = try std.net.Address.parseIp4("0.0.0.0", self.port);
            var server = try address.listen(.{});
            defer server.deinit();
            
            std.log.info("Metrics server listening on http://localhost:{d}/metrics", .{self.port});
            
            while (true) {
                const connection = server.accept() catch continue;
                defer connection.stream.close();
                
                // Simple HTTP response using std.http.Server
                var buffer: [4096]u8 = undefined;
                var http_server = std.http.Server.init(connection, &buffer);
                var request = http_server.receiveHead() catch continue;
                
                // Check if it's a request to /metrics
                if (std.mem.eql(u8, request.head.target, "/metrics")) {
                    var metrics_output = std.ArrayList(u8).init(self.allocator);
                    defer metrics_output.deinit();
                    
                    writeMetrics(metrics_output.writer()) catch {
                        _ = request.respond("Internal Server Error\n", .{}) catch {};
                        continue;
                    };
                    
                    _ = request.respond(metrics_output.items, .{
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
                        },
                    }) catch {};
                } else {
                    _ = request.respond("Not Found\n", .{ .status = .not_found }) catch {};
                }
            }
        }
    };

    const ctx = try allocator.create(ServerContext);
    ctx.* = .{
        .allocator = allocator,
        .port = port,
    };

    const thread = try std.Thread.spawn(.{}, ServerContext.run, .{ctx});
    thread.detach();
}

// Compatibility functions for the old API
pub fn chain_onblock_duration_seconds_start() Timer {
    return chain_onblock_duration_seconds.start();
}