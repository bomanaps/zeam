const std = @import("std");

// Simple no-op metrics implementation
pub const Timer = struct {
    pub fn start() @This() {
        return .{};
    }
    
    pub fn observe(_: @This()) void {
        // No-op implementation
    }
};

pub fn start() !void {
    // No-op implementation
    std.log.info("Metrics server not started (using no-op implementation)", .{});
}

// Export a function to create a new timer
pub fn block_processing_duration_seconds_start() Timer {
    return Timer.start();
}
