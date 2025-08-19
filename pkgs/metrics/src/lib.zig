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

// Compatibility alias so call sites can use `metrics.block_processing_duration_seconds.start()`
pub const block_processing_duration_seconds = Timer;

// Chain onBlock processing duration (sample metric requested)
pub const chain_onblock_duration_seconds = Timer;

pub fn chain_onblock_duration_seconds_start() Timer {
    return Timer.start();
}
