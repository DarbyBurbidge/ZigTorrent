const std = @import("std");
const print = std.debug.print;

const consts = @import("./consts.zig");
const HASH_LEN = consts.HASH_LEN;
const ID_IDX = 4;
const HOST_SIZE = 4;
const PORT_SIZE = 2;
const PREFIX_SIZE = 5;

pub const Peer = struct { ip: [HOST_SIZE]u8, port: [PORT_SIZE]u8 };
pub const PeerConn = struct {
    choked: bool,
    interested: bool,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
    // default
    // am_c = 1
    // am_i = 0
    // p_c = 1
    // p_i = 0
    //
    // all data is u32 Big-Endian
};

const MessageType = union(enum) {
    keep_alive,
    choke,
    unchoke,
    interested,
    not_interested,
    have,
    bitfield,
    request,
    piece,
    cancel,
    port,
};

// generates <length><id> portion of peer message, len necessary for things like bitfield and piece
fn generateMessagePrefix(allocator: std.mem.Allocator, message_type: MessageType, len: u64) ![]u8 {
    var message_prefix: []u8 = undefined;
    switch (message_type) {
        .keep_alive => {
            var length = [_]u8{0} ** 4;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE - 1); // no id byte
            std.mem.writeInt(u32, &length, 1, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
        },
        .choke => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 0;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 1, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .unchoke => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 1;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 1, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .interested => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 2;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 1, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .not_interested => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 3;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 1, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .have => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 4;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 5, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .bitfield => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 5;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 1 + len, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .request => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 6;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 13, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .piece => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 7;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 9 + len, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .cancel => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 8;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 13, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
        .port => {
            var length = [_]u8{0} ** 4;
            const id: u8 = 9;
            message_prefix = try allocator.alloc(u8, PREFIX_SIZE);
            std.mem.writeInt(u32, &length, 3, .big);
            std.mem.copyForwards(u8, message_prefix, length[0..]);
            message_prefix[ID_IDX] = id;
        },
    }
    return message_prefix;
}

fn generateMessage(allocator: std.mem.Allocator, prefix: MessageType) {
    return message;
}

fn generateHandshake(allocator: std.mem.Allocator, peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) ![]u8 {
    var handshake: []u8 = try allocator.alloc(u8, 68); // magic number 49 + 19
    handshake[0] = 19;
    std.mem.copyForwards(u8, handshake[1..], "BitTorrent protocol"[0..19]);
    std.mem.copyForwards(u8, handshake[28..], &info_hash);
    std.mem.copyForwards(u8, handshake[48..], &peer_id);
    return handshake;
}

pub fn peerConnection(allocator: std.mem.Allocator, peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) !void {
    const handshake = try generateHandshake(allocator, peer_id, info_hash);
    print("handshake: {any}\n", .{handshake});
    const m_prefix = try generateMessagePrefix(allocator, .keep_alive);
    print("m_prefix: {any}\n", .{m_prefix});
    return;
}
