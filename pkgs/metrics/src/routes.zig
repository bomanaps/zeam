const std = @import("std");
const metrics = @import("./lib.zig");

/// Metrics route handler for /metrics endpoint
pub fn metricsHandler(allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    var metrics_output = std.ArrayList(u8).init(allocator);
    defer metrics_output.deinit();

    metrics.writeMetrics(metrics_output.writer()) catch {
        _ = request.respond("Internal Server Error\n", .{}) catch {};
        return;
    };

    _ = request.respond(metrics_output.items, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
        },
    }) catch {};
}

/// Returns the metrics route configuration
pub fn getMetricsRoute() @import("@zeam/utils").Route {
    return .{
        .path = "/metrics",
        .handler = metricsHandler,
    };
}

/// Sets up metrics routes on an HTTP server instance
/// This function can be called to register metrics routes with any HTTP server
pub fn setupMetricsRoutes(_: std.mem.Allocator, routes: *std.ArrayList(@import("@zeam/utils").Route)) !void {
    try routes.append(getMetricsRoute());
}
