const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const ssz = @import("ssz");
const types = @import("@zeam/types");
const xev = @import("xev");
const Multiaddr = @import("multiformats").multiaddr.Multiaddr;

const interface = @import("./interface.zig");
const NetworkInterface = interface.NetworkInterface;

/// Writes failed deserialization bytes to disk for debugging purposes
/// Returns true if the file was successfully created, false otherwise
/// If timestamp is null, generates a new timestamp automatically
fn writeFailedBytes(message_bytes: []const u8, message_type: []const u8, allocator: Allocator, timestamp: ?i64) bool {
    // Create dumps directory if it doesn't exist
    std.fs.cwd().makeDir("deserialization_dumps") catch |e| switch (e) {
        error.PathAlreadyExists => {}, // Directory already exists, continue
        else => {
            std.debug.print("Failed to create dumps directory: {any}\n", .{e});
            return false;
        },
    };

    // Generate timestamp-based filename
    const actual_timestamp = timestamp orelse std.time.timestamp();
    const filename = std.fmt.allocPrint(allocator, "deserialization_dumps/failed_{s}_{d}.bin", .{ message_type, actual_timestamp }) catch |e| {
        std.debug.print("Failed to allocate filename: {any}\n", .{e});
        return false;
    };
    defer allocator.free(filename);

    // Write bytes to file
    const file = std.fs.cwd().createFile(filename, .{ .truncate = true }) catch |e| {
        std.debug.print("Failed to create file {s}: {any}\n", .{ filename, e });
        return false;
    };
    defer file.close();

    file.writeAll(message_bytes) catch |e| {
        std.debug.print("Failed to write bytes to file {s}: {any}\n", .{ filename, e });
        return false;
    };

    std.debug.print("Written {d} bytes to {s} for debugging\n", .{ message_bytes.len, filename });
    return true;
}

export fn handleMsgFromRustBridge(zigHandler: *EthLibp2p, topic_id: u32, message_ptr: [*]const u8, message_len: usize) void {
    const topic = switch (topic_id) {
        0 => interface.GossipTopic.block,
        1 => interface.GossipTopic.vote,
        else => {
            std.debug.print("\n!!!! Ignoring Invalid topic_id={d} sent in handleMsgFromRustBridge !!!!\n", .{topic_id});
            return;
        },
    };

    const message_bytes: []const u8 = message_ptr[0..message_len];
    const message: interface.GossipMessage = switch (topic) {
        .block => blockmessage: {
            var message_data: types.SignedBeamBlock = undefined;
            ssz.deserialize(types.SignedBeamBlock, message_bytes, &message_data, zigHandler.allocator) catch |e| {
                std.debug.print("!!!! Error in deserializing the signed block message e={any} !!!!\n", .{e});
                _ = writeFailedBytes(message_bytes, "block", zigHandler.allocator, null);
                return;
            };

            break :blockmessage .{ .block = message_data };
        },
        .vote => votemessage: {
            var message_data: types.SignedVote = undefined;
            ssz.deserialize(types.SignedVote, message_bytes, &message_data, zigHandler.allocator) catch |e| {
                std.debug.print("!!!! Error in deserializing the signed vote message e={any} !!!!\n", .{e});
                _ = writeFailedBytes(message_bytes, "vote", zigHandler.allocator, null);
                return;
            };
            break :votemessage .{ .vote = message_data };
        },
    };

    std.debug.print("\nnetwork-{d}:: !!!handleMsgFromRustBridge topic={any}:: message={any} from bytes={any} \n", .{ zigHandler.params.networkId, topic, message, message_bytes });

    // TODO: figure out why scheduling on the loop is not working
    zigHandler.gossipHandler.onGossip(&message, false) catch |e| {
        std.debug.print("!!!! onGossip handling of message failed with error e={any} !!!!\n", .{e});
    };
}

export fn releaseAddresses(zigHandler: *EthLibp2p, listenAddresses: [*:0]const u8, connectAddresses: [*:0]const u8) void {
    const listen_slice = std.mem.span(listenAddresses);
    zigHandler.allocator.free(listen_slice);

    const connect_slice = std.mem.span(connectAddresses);
    // because connectAddresses can be empty string "" which not allocate memory in the heap
    if (connect_slice.len > 0) {
        zigHandler.allocator.free(connect_slice);
    }
}

// TODO: change listen port and connect port both to list of multiaddrs
pub extern fn create_and_run_network(networkId: u32, a: *EthLibp2p, listenAddresses: [*:0]const u8, connectAddresses: [*:0]const u8) void;
pub extern fn publish_msg_to_rust_bridge(networkId: u32, topic_id: u32, message_ptr: [*]const u8, message_len: usize) void;

pub const EthLibp2pParams = struct {
    networkId: u32,
    listen_addresses: []const Multiaddr,
    connect_peers: ?[]const Multiaddr,
};

pub const EthLibp2p = struct {
    allocator: Allocator,
    gossipHandler: interface.GenericGossipHandler,
    params: EthLibp2pParams,
    rustBridgeThread: ?Thread = null,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        loop: *xev.Loop,
        params: EthLibp2pParams,
    ) !Self {
        return Self{ .allocator = allocator, .params = params, .gossipHandler = try interface.GenericGossipHandler.init(allocator, loop, params.networkId) };
    }

    pub fn run(self: *Self) !void {
        const listen_addresses_str = try multiaddrsToString(self.allocator, self.params.listen_addresses);
        const connect_peers_str = if (self.params.connect_peers) |peers|
            try multiaddrsToString(self.allocator, peers)
        else
            "";
        self.rustBridgeThread = try Thread.spawn(.{}, create_and_run_network, .{ self.params.networkId, self, listen_addresses_str.ptr, connect_peers_str.ptr });
    }

    pub fn publish(ptr: *anyopaque, data: *const interface.GossipMessage) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // publish
        const topic = data.getTopic();
        const topic_id: u32 = switch (topic) {
            .block => 0,
            .vote => 1,
        };

        // TODO: deinit the message later ob once done
        const message = switch (topic) {
            .block => blockbytes: {
                var serialized = std.ArrayList(u8).init(self.allocator);
                try ssz.serialize(types.SignedBeamBlock, data.block, &serialized);

                break :blockbytes serialized.items;
            },
            .vote => votebytes: {
                var serialized = std.ArrayList(u8).init(self.allocator);
                try ssz.serialize(types.SignedVote, data.vote, &serialized);

                break :votebytes serialized.items;
            },
        };
        std.debug.print("\n\nnetwork-{d}:: calling publish_msg_to_rust_bridge with byes={any} for data={any}\n\n", .{ self.params.networkId, message, data });
        publish_msg_to_rust_bridge(self.params.networkId, topic_id, message.ptr, message.len);
    }

    pub fn subscribe(ptr: *anyopaque, topics: []interface.GossipTopic, handler: interface.OnGossipCbHandler) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.gossipHandler.subscribe(topics, handler);
    }

    pub fn onGossip(ptr: *anyopaque, data: *const interface.GossipMessage) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.gossipHandler.onGossip(data, false);
    }

    pub fn reqResp(ptr: *anyopaque, obj: *interface.ReqRespRequest) anyerror!void {
        _ = ptr;
        _ = obj;
    }

    pub fn onReq(ptr: *anyopaque, data: *interface.ReqRespRequest) anyerror!void {
        _ = ptr;
        _ = data;
    }

    pub fn getNetworkInterface(self: *Self) NetworkInterface {
        return .{ .gossip = .{
            .ptr = self,
            .publishFn = publish,
            .subscribeFn = subscribe,
            .onGossipFn = onGossip,
        }, .reqresp = .{
            .ptr = self,
            .reqRespFn = reqResp,
            .onReqFn = onReq,
        } };
    }

    fn multiaddrsToString(allocator: Allocator, addrs: []const Multiaddr) ![:0]u8 {
        if (addrs.len == 0) {
            return try allocator.dupeZ(u8, "");
        }

        var addr_strings = std.ArrayList([]const u8).init(allocator);
        defer {
            for (addr_strings.items) |addr_str| {
                allocator.free(addr_str);
            }
            addr_strings.deinit();
        }

        for (addrs) |addr| {
            const addr_str = try addr.toString(allocator);
            try addr_strings.append(addr_str);
        }

        const joined = try std.mem.join(allocator, ",", addr_strings.items);
        defer allocator.free(joined);

        const result = try allocator.dupeZ(u8, joined);

        return result;
    }
};

test "writeFailedBytes creates file with correct content" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Ensure directory exists before test (CI-safe)
    std.fs.cwd().makeDir("deserialization_dumps") catch {};

    // Use a predictable timestamp for deterministic filename
    const test_timestamp: i64 = 1234567890;

    // Test case 1: Valid data that should succeed
    const valid_bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    const result1 = writeFailedBytes(&valid_bytes, "test", allocator, test_timestamp);
    testing.expect(result1 == true) catch {
        std.debug.print("writeFailedBytes should return true for valid data\n", .{});
    };

    // Now verify the file was created and contains correct content
    const expected_filename = "deserialization_dumps/failed_test_1234567890.bin";
    const file = std.fs.cwd().openFile(expected_filename, .{}) catch |e| {
        std.debug.print("Failed to open created file: {any}\n", .{e});
        testing.expect(false) catch {};
        return;
    };
    defer file.close();

    // Read all file contents
    const file_contents = file.readToEndAlloc(allocator, 1024) catch |e| {
        std.debug.print("Failed to read file contents: {any}\n", .{e});
        testing.expect(false) catch {};
        return;
    };
    defer allocator.free(file_contents);

    // Verify the file contains exactly the bytes we provided
    testing.expectEqualSlices(u8, &valid_bytes, file_contents) catch {
        std.debug.print("File contents don't match expected bytes. Expected: {any}, Got: {any}\n", .{ &valid_bytes, file_contents });
    };

    // Test case 2: Empty data that should still succeed
    const empty_bytes = [_]u8{};
    const result2 = writeFailedBytes(&empty_bytes, "empty", allocator, test_timestamp);
    testing.expect(result2 == true) catch {
        std.debug.print("writeFailedBytes should return true for empty data\n", .{});
    };

    // Verify empty file was created
    const empty_filename = "deserialization_dumps/failed_empty_1234567890.bin";
    const empty_file = std.fs.cwd().openFile(empty_filename, .{}) catch |e| {
        std.debug.print("Failed to open empty file: {any}\n", .{e});
        testing.expect(false) catch {};
        return;
    };
    defer empty_file.close();

    const empty_contents = empty_file.readToEndAlloc(allocator, 1024) catch |e| {
        std.debug.print("Failed to read empty file contents: {any}\n", .{e});
        testing.expect(false) catch {};
        return;
    };
    defer allocator.free(empty_contents);

    testing.expectEqualSlices(u8, &empty_bytes, empty_contents) catch {
        std.debug.print("Empty file contents don't match expected bytes. Expected: {any}, Got: {any}\n", .{ &empty_bytes, empty_contents });
    };

    // Cleanup after we're done with the directory
    std.fs.cwd().deleteTree("deserialization_dumps") catch {};
}
