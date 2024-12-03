const std = @import("std");
const print = std.debug.print;

const consts = @import("./consts.zig");
const HASH_LEN = consts.HASH_LEN;
const ID_IDX = 4;
const HOST_SIZE = 4;
const PORT_SIZE = 2;
const PREFIX_SIZE = 5;
const LEN_SIZE = 4;
const SEG_SIZE = 16 * 1024; // 16KB

pub const PeerConn = struct {
    choked: bool,
    interested: bool,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
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

pub const Peer = struct {
    allocator: std.mem.Allocator,
    ip: [HOST_SIZE]u8,
    port: [PORT_SIZE]u8,
    conn: PeerConn,

    pub fn init(allocator: std.mem.Allocator, ip: [HOST_SIZE]u8, port: [PORT_SIZE]u8) !Peer {
        return Peer{ .allocator = allocator, .ip = ip, .port = port, .conn = PeerConn{ .choked = true, .interested = false, .am_choking = true, .am_interested = false, .peer_choking = true, .peer_interested = false } };
    }

    fn writeLenPrefix(self: *@This(), message_prefix: []u8, len: u32) ![]u8 {
        var length = [_]u8{0} ** LEN_SIZE;
        message_prefix = try self.allocator.alloc(u8, LEN_SIZE);
        std.mem.writeInt(u32, &length, len, .big);
        std.mem.copyForwards(u8, message_prefix, length[0..]);
        return message_prefix;
    }

    // generates <length><id> portion of peer message, len necessary for things like bitfield and piece
    fn generateMessagePrefix(self: *@This(), message_type: MessageType, len: u32) ![]u8 {
        var message_prefix: []u8 = undefined;
        switch (message_type) {
            .keep_alive => {
                try writeLenPrefix(self.allocator, message_prefix, 0);
            },
            .choke => {
                const id = 0;
                try writeLenPrefix(self.allocator, message_prefix, 1);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .unchoke => {
                const id = 1;
                try writeLenPrefix(self.allocator, message_prefix, 1);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .interested => {
                const id = 2;
                try writeLenPrefix(self.allocator, message_prefix, 1);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .not_interested => {
                const id = 3;
                try writeLenPrefix(self.allocator, message_prefix, 1);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .have => {
                const id = 4;
                try writeLenPrefix(self.allocator, message_prefix, 5);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .bitfield => {
                const id: u8 = 5;
                try writeLenPrefix(self.allocator, message_prefix, 1 + len);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .request => {
                const id: u8 = 6;
                try writeLenPrefix(self.allocator, message_prefix, 13);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .piece => {
                const id: u8 = 7;
                try writeLenPrefix(self.allocator, message_prefix, 9 + len);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .cancel => {
                const id: u8 = 8;
                try writeLenPrefix(self.allocator, message_prefix, 13);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
            .port => {
                const id: u8 = 9;
                try writeLenPrefix(self.allocator, message_prefix, 3);
                self.allocator.realloc(message_prefix, message_prefix.len + 1);
                message_prefix[ID_IDX] = id;
            },
        }
        return message_prefix;
    }

    fn generateMessage(self: *@This(), m_type: MessageType) ![]u8 {
        _ = self.generateMessagePrefix(self.allocator, m_type);
        const message: []u8 = undefined;
        switch (m_type) {
            .keep_alive => {},
            .choke => {},
            .unchoke => {},
            .interested => {},
            .not_interested => {},
            .have => {},
            .bitfield => {},
            .request => {},
            .piece => {},
            .cancel => {},
            .port => {},
        }
        return message;
    }

    fn generateHandshake(self: *@This(), peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) ![]u8 {
        var handshake: []u8 = try self.allocator.alloc(u8, 68); // magic number 49 + 19
        handshake[0] = 19;
        std.mem.copyForwards(u8, handshake[1..], "BitTorrent protocol"[0..19]);
        std.mem.copyForwards(u8, handshake[28..], &info_hash);
        std.mem.copyForwards(u8, handshake[48..], &peer_id);
        return handshake;
    }

    fn connect(self: *@This(), peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) !void {
        const handshake = try generateHandshake(self.allocator, peer_id, info_hash);
        print("handshake: {any}\n", .{handshake});
        const m_prefix = try generateMessagePrefix(self.allocator, .keep_alive);
        print("m_prefix: {any}\n", .{m_prefix});
        return;
    }
};
