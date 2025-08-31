const std = @import("std");

/// HTTP route handler function type
pub const RouteHandler = fn (allocator: std.mem.Allocator, request: *std.http.Server.Request) anyerror!void;

/// HTTP route definition
pub const Route = struct {
    path: []const u8,
    handler: RouteHandler,
};

/// HTTP server configuration
pub const ServerConfig = struct {
    port: u16,
    address: []const u8 = "0.0.0.0",
    allocator: std.mem.Allocator,
    routes: []const Route,
};

/// HTTP server context for background operation
const ServerContext = struct {
    config: ServerConfig,

    fn run(self: *@This()) !void {
        const address = try std.net.Address.parseIp4(self.config.address, self.config.port);
        var server = try address.listen(.{});
        defer server.deinit();

        std.log.info("HTTP server listening on http://{}:{d}", .{ self.config.address, self.config.port });

        while (true) {
            const connection = server.accept() catch continue;
            defer connection.stream.close();

            // Simple HTTP response using std.http.Server
            var buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(connection, &buffer);
            var request = http_server.receiveHead() catch continue;

            // Find matching route
            var route_found = false;
            for (self.config.routes) |route| {
                if (std.mem.eql(u8, request.head.target, route.path)) {
                    route.handler(self.config.allocator, &request) catch |err| {
                        std.log.err("Route handler error: {}", .{err});
                        _ = request.respond("Internal Server Error\n", .{}) catch {};
                    };
                    route_found = true;
                    break;
                }
            }

            if (!route_found) {
                _ = request.respond("Not Found\n", .{ .status = .not_found }) catch {};
            }
        }
    }
};

/// Starts an HTTP server in a background thread with the given configuration
pub fn startServer(config: ServerConfig) !void {
    const ctx = try config.allocator.create(ServerContext);
    ctx.* = .{
        .config = config,
    };

    const thread = try std.Thread.spawn(.{}, ServerContext.run, .{ctx});
    thread.detach();
}

/// Helper function to send a text response
pub fn sendTextResponse(request: *std.http.Server.Request, content: []const u8) !void {
    _ = request.respond(content, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    }) catch {};
}

/// Helper function to send a JSON response
pub fn sendJsonResponse(request: *std.http.Server.Request, content: []const u8) !void {
    _ = request.respond(content, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        },
    }) catch {};
}

/// Helper function to send Prometheus metrics response
pub fn sendMetricsResponse(request: *std.http.Server.Request, content: []const u8) !void {
    _ = request.respond(content, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
        },
    }) catch {};
}
