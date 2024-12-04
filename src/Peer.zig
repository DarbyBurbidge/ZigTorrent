const std = @import("std");
const print = std.debug.print;

const consts = @import("./consts.zig");
const HASH_LEN = consts.HASH_LEN;
const MAX_BUF_SIZE = consts.MAX_BUF_SIZE;
const ID_IDX = 4;
const HOST_SIZE = 4;
const PREFIX_SIZE = 5;
const LEN_SIZE = 4;
const SEG_SIZE = 16 * 1024; // 16KB

pub const PeerState = struct {
    choked: bool,
    interested: bool,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
    // all data is u32 Big-Endian
};

pub const PeerMessage = struct {
    type: MessageType,
    piece_idx: ?u32,
    bitfield: ?[]u8,
    index: ?u32,
    begin: ?u32,
    length: ?u32,
    block: ?u32,
    port: ?u32,
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

// maintains Peer state, and handles connection and messaging logic for Peer
pub const Peer = struct {
    allocator: std.mem.Allocator,
    ip: [HOST_SIZE]u8,
    port: u16,
    conn_stream: ?std.net.Stream,
    state: PeerState,

    pub fn init(allocator: std.mem.Allocator, ip: [HOST_SIZE]u8, port: u16) !Peer {
        return Peer{
            .allocator = allocator,
            .ip = ip,
            .port = port,
            .conn_stream = undefined,
            .state = PeerState{
                .choked = true,
                .interested = false,
                .am_choking = true,
                .am_interested = false,
                .peer_choking = true,
                .peer_interested = false,
            },
        };
    }

    fn writeLenPrefix(self: *@This(), message_prefix: []u8, len: u32) ![]u8 {
        var length = [_]u8{0} ** LEN_SIZE;
        message_prefix = try self.allocator.alloc(u8, LEN_SIZE);
        std.mem.writeInt(u32, &length, len, .big);
        std.mem.copyForwards(u8, message_prefix, length[0..]);
        return message_prefix;
    }

    fn writeIDPrefix(self: *@This(), message_prefix: []u8, id: u8) ![]u8 {
        self.allocator.realloc(message_prefix, message_prefix.len + 1);
        message_prefix[ID_IDX] = id;
        return message_prefix;
    }

    // generates <length><id> portion of peer message, len necessary for things like bitfield and piece
    fn genMsgPfx(self: *@This(), msg_t: MessageType, len: u32) ![]u8 {
        var msg_pfx: []u8 = undefined;
        switch (msg_t) {
            .keep_alive => {
                try writeLenPrefix(self.allocator, &msg_pfx, 0);
            },
            .choke => {
                const id = 0;
                try writeLenPrefix(self.allocator, &msg_pfx, 1);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .unchoke => {
                const id = 1;
                try writeLenPrefix(self.allocator, &msg_pfx, 1);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .interested => {
                const id = 2;
                try writeLenPrefix(self.allocator, &msg_pfx, 1);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .not_interested => {
                const id = 3;
                try writeLenPrefix(self.allocator, &msg_pfx, 1);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .have => {
                const id = 4;
                try writeLenPrefix(self.allocator, &msg_pfx, 5);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .bitfield => {
                const id: u8 = 5;
                try writeLenPrefix(self.allocator, &msg_pfx, 1 + len);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .request => {
                const id: u8 = 6;
                try writeLenPrefix(self.allocator, &msg_pfx, 13);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .piece => {
                const id: u8 = 7;
                try writeLenPrefix(self.allocator, &msg_pfx, 9 + len);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .cancel => {
                const id: u8 = 8;
                try writeLenPrefix(self.allocator, &msg_pfx, 13);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
            .port => {
                const id: u8 = 9;
                try writeLenPrefix(self.allocator, &msg_pfx, 3);
                try writeIDPrefix(self.allocator, &msg_pfx, id);
            },
        }
        return msg_pfx;
    }

    // uses message_type to generate appropriate message for peer connection
    fn genMsg(self: *@This(), m_type: MessageType) ![]u8 {
        const msg = self.genMsgPfx(self.allocator, m_type);
        switch (m_type) {
            .keep_alive,
            .choke,
            .unchoke,
            .interested,
            .not_interested,
            => {
                void;
            },
            .have => {},
            .bitfield => {},
            .request => {
                //genReq(allocator, msg);
            },
            .piece => {},
            .cancel => {},
            .port => {},
        }
        return msg;
    }

    // generates initial handshake message to be sent to this peer
    fn genHandshake(self: *@This(), peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) ![]u8 {
        var handshake: []u8 = try self.allocator.alloc(u8, 68); // magic number 49 + 19
        handshake[0] = 19;
        std.mem.copyForwards(u8, handshake[1..], "BitTorrent protocol"[0..19]);
        std.mem.copyForwards(u8, handshake[28..], &info_hash);
        std.mem.copyForwards(u8, handshake[48..], &peer_id);
        return handshake;
    }

    // initializes the connection to this peer
    pub fn connect(self: *@This(), self_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) !void {
        const handshake = try self.genHandshake(self_id, info_hash);
        print("handshake: {s}\n", .{handshake});
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        const address = std.net.Address.initIp4(self.ip, self.port);

        self.conn_stream = try std.net.tcpConnectToAddress(address);
        const num_w = try self.conn_stream.?.write(handshake);
        if (num_w < handshake.len) {
            return error.WriteHandshakeFailed;
        }
        const num_r = try self.conn_stream.?.read(&buf);
        print("handshake response: {s}\n", .{buf[0..num_r]});
    }

    fn messageParse(m_buf: []u8) !PeerMessage {
        var message = PeerMessage{ .type = .keep_alive };
        if (std.fmt.parseInt(u32, m_buf[0..4], 10) == 0) {
            return message;
        }
        switch (m_buf[4]) {
            0 => {
                message.type = .choke;
            },
            1 => {
                message.type = .unchoke;
            },
            2 => {
                message.type = .interested;
            },
            3 => {
                message.type = .not_interested;
            },
            4 => {
                message.type = .have;
                message.piece_idx = m_buf[5..];
            },
            5 => {
                const length = std.fmt.parseInt(u32, m_buf[0..4], 10);
                message.type = .bitfield;
                message.bitfield = m_buf[5..length];
            },
            6 => {
                message.type = .request;
                message.index = m_buf[5..9];
                message.begin = m_buf[9..13];
                message.length = m_buf[13..17];
            },
            7 => {
                const length = std.fmt.parseInt(u32, m_buf[0..4], 10);
                message.type = .piece;
                message.index = m_buf[5..9];
                message.begin = m_buf[9..13];
                message.block = m_buf[13..length];
            },
            8 => {
                message.type = .cancel;
                message.index = m_buf[5..9];
                message.begin = m_buf[9..13];
                message.length = m_buf[13..17];
            },
            9 => {
                message.type = .port;
                message.port = m_buf[5..9];
            },
        }
        return message;
    }
};

pub fn manage_conn(peer: Peer) void {
    while (peer.conn_stream) |conn| {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        conn.read(&buf);
        peer.messageParse(&buf);
        const msg = peer.genMsg(.keep_alive);
        print("msg: {s}\n", .{msg});
    }
}
