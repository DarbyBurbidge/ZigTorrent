const std = @import("std");
const print = std.debug.print;
const readInt = std.mem.readInt;

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
    bitfield: ?[]u8, // need bit handling
    index: ?u32,
    begin: ?u32,
    length: ?u32,
    block: ?[]u8,
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

    fn writeLenPrefix(self: *@This(), len: u32) ![]u8 {
        var length = [_]u8{0} ** LEN_SIZE;
        const message_prefix = try self.allocator.alloc(u8, LEN_SIZE);
        std.mem.writeInt(u32, &length, len, .big);
        std.mem.copyForwards(u8, message_prefix, length[0..]);
        return message_prefix;
    }

    fn writeIDPrefix(self: *@This(), message_prefix: []u8, id: u8) ![]u8 {
        const new_prefix = try self.allocator.realloc(message_prefix, message_prefix.len + 1);
        new_prefix[ID_IDX] = id;
        return new_prefix;
    }

    // generates <length><id> portion of peer message, len necessary for things like bitfield and piece
    fn genMsgPfx(self: *@This(), msg_t: MessageType, len: u32) ![]u8 {
        var msg_pfx: []u8 = undefined;
        switch (msg_t) {
            .keep_alive => {
                msg_pfx = try self.writeLenPrefix(0);
            },
            .choke => {
                const id = 0;
                msg_pfx = try self.writeLenPrefix(1);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .unchoke => {
                const id = 1;
                msg_pfx = try self.writeLenPrefix(1);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .interested => {
                const id = 2;
                msg_pfx = try self.writeLenPrefix(1);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .not_interested => {
                const id = 3;
                msg_pfx = try self.writeLenPrefix(1);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .have => {
                const id = 4;
                msg_pfx = try self.writeLenPrefix(5);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .bitfield => {
                const id: u8 = 5;
                msg_pfx = try self.writeLenPrefix(1 + len);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .request => {
                const id: u8 = 6;
                msg_pfx = try self.writeLenPrefix(13);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .piece => {
                const id: u8 = 7;
                msg_pfx = try self.writeLenPrefix(9 + len);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            .cancel => {
                const id: u8 = 8;
                msg_pfx = try self.writeLenPrefix(13);
                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            },
            //            .port => {
            //                const id: u8 = 9;
            //                msg_pfx = try self.writeLenPrefix(3);
            //                msg_pfx = try self.writeIDPrefix(msg_pfx, id);
            //            },
        }
        return msg_pfx;
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
    // If there's an issue writing or reading the handshake, connection is closed and made null
    pub fn connect(self: *@This(), self_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8) !void {
        const handshake = try self.genHandshake(self_id, info_hash);
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        const address = std.net.Address.initIp4(self.ip, self.port);
        print("connect ip: {}.{}.{}.{}\n", .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3] });

        self.conn_stream = std.net.tcpConnectToAddress(address) catch undefined;
        print("Peer Connection Established: {}.{}.{}.{}\n", .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3] });
        if (self.conn_stream) |conn| {
            const num_w = conn.write(handshake) catch 0;
            if (num_w < handshake.len) {
                self.conn_stream = undefined;
                print("Error: WriteHandshakeFailed\n", .{});
            }
            const num_r = conn.read(&buf) catch 0;
            if (num_r > 0) {
                // validating handshake
                print("Peer Handshake Recieved\n", .{});
            } else {
                self.conn_stream = undefined;
                print("Error: ReadHandshakeFailed\n", .{});
            }
        }
    }

    fn sendUnchoke(self: *@This()) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            self.state.am_choking = false;
            const prefix = try self.genMsgPfx(.unchoke, 0);
            const bytes_w = conn.write(prefix) catch 0;
            if (bytes_w > 0) {
                print("Sent Unchoke\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendChoke(self: *@This()) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            self.state.am_choking = true;
            const prefix = try self.genMsgPfx(.choke, 0);
            const bytes_w = conn.write(prefix) catch 0;
            if (bytes_w > 0) {
                print("Sent Choke\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendInterested(self: *@This()) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            self.state.am_interested = true;
            const prefix = try self.genMsgPfx(.interested, 0);
            const bytes_w = conn.write(prefix) catch 0;
            if (bytes_w > 0) {
                print("Sent Interested\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendNotInterested(self: *@This()) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            self.state.am_interested = false;
            const prefix = try self.genMsgPfx(.not_interested, 0);
            const bytes_w = conn.write(prefix) catch 0;
            if (bytes_w > 0) {
                print("Sent Not Interested\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendHave(self: *@This(), p_idx: u32) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.have, 0);
            const msg = [_]u8{0} ** 9;
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], @bitCast(p_idx));
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent Have\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No Response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendBitField(self: *@This(), b_field: []u8) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.bitfield, b_field.len);
            const msg = try self.allocator.alloc(u8, b_field.len);
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], b_field);
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent BitField\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No Response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendRequest(self: *@This(), idx: u32, begin: u32, length: u32) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.request, 0);
            const msg = [_]u8{0} ** 17;
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], @bitCast(idx));
            std.mem.copyForwards(u8, msg[9..], @bitCast(begin));
            std.mem.copyForwards(u8, msg[13..], @bitCast(length));
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent Request\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendPiece(self: *@This(), idx: u32, begin: u32, block: []u8) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.not_interested, block.len);
            const msg = try self.allocator.alloc(u8, 13 + block.len);
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], @bitCast(idx));
            std.mem.copyForwards(u8, msg[9..], @bitCast(begin));
            std.mem.copyForwards(u8, msg[13..], block);
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent Piece\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendCancel(self: *@This(), idx: u32, begin: u32, length: u32) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.not_interested, 0);
            const msg = [_]u8{0} ** 17;
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], @bitCast(idx));
            std.mem.copyForwards(u8, msg[9..], @bitCast(begin));
            std.mem.copyForwards(u8, msg[13..], @bitCast(length));
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent Cancel\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No response\n", .{});
        }
        return error.NoConnection;
    }

    fn sendPort(self: *@This(), port: u32) !PeerMessage {
        var buf = [_]u8{0} ** MAX_BUF_SIZE;
        if (self.conn_stream) |conn| {
            const prefix = try self.genMsgPfx(.bitfield, 0);
            const msg = [_]u8{0} ** 7;
            std.mem.copyForwards(u8, msg, prefix);
            std.mem.copyForwards(u8, msg[5..], @bitCast(port));
            const bytes_w = conn.write(msg) catch 0;
            if (bytes_w > 0) {
                print("Sent Port\n", .{});
            }
            const bytes_r = conn.read(&buf) catch 0;
            if (bytes_r > 0) {
                return messageParse(buf[0..bytes_r]);
            }
            print("No Response\n", .{});
        }
        return error.NoConnection;
    }
};

// manages the peer connection
// returns void because it's intended to be multithreaded
// errors must be caught here
const FileBuffer = @import("./File.zig").FileBuffer;
const FileBitField = @import("./File.zig").FileBitField;
pub fn manageConn(peer: *Peer, peer_id: [HASH_LEN]u8, info_hash: [HASH_LEN]u8, file_buf: *FileBuffer, f_bfield: *FileBitField) void {
    _ = file_buf;
    _ = f_bfield;
    print("Starting Handshake: {}.{}.{}.{}\n", .{ peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3] });
    peer.connect(peer_id, info_hash) catch |err| {
        print("{}\n", .{err});
    };
    print("Completed Handshake: {}.{}.{}.{}\n", .{ peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3] });
    while (peer.conn_stream) |conn| {
        var buf = [_]u8{0} ** MAX_BUF_SIZE; // 32KB
        const bytes_r = conn.read(&buf) catch 0;
        if (bytes_r > 0) {
            const p_msg = messageParse(&buf);
            print("Message Received: {any}\n", .{p_msg});
            if (peer.sendUnchoke()) |response| {
                print("{any}\n", .{response});
            } else |err| {
                print("uc_error: {}\n", .{err});
            }
            if (peer.sendInterested()) |response| {
                print("{any}\n", .{response});
            } else |err| {
                print("int_error: {}\n", .{err});
            }
        }
    }
}

fn messageParse(m_buf: []u8) PeerMessage {
    var message = PeerMessage{
        .type = .keep_alive,
        .piece_idx = undefined,
        .bitfield = undefined,
        .index = undefined,
        .begin = undefined,
        .block = undefined,
        .length = undefined,
        //        .port = undefined,
    };
    if (0 == readInt(i32, m_buf[0..4], .big)) {
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
            message.piece_idx = readInt(u32, m_buf[5..9], .big);
        },
        5 => {
            const length = readInt(u32, m_buf[0..4], .big);
            message.type = .bitfield;
            message.bitfield = m_buf[5..length];
        },
        6 => {
            message.type = .request;
            message.index = readInt(u32, m_buf[5..9], .big);
            message.begin = readInt(u32, m_buf[9..13], .big);
            message.length = readInt(u32, m_buf[13..17], .big);
        },
        7 => {
            const length = readInt(u32, m_buf[0..4], .big);
            message.type = .piece;
            message.index = readInt(u32, m_buf[5..9], .big);
            message.begin = readInt(u32, m_buf[9..13], .big);
            message.block = m_buf[13..length];
        },
        8 => {
            message.type = .cancel;
            message.index = readInt(u32, m_buf[5..9], .big);
            message.begin = readInt(u32, m_buf[9..13], .big);
            message.length = readInt(u32, m_buf[13..17], .big);
        },
        //        9 => {
        //            message.type = .port;
        //            message.port = readInt(u32, m_buf[5..9], .big);
        //        },
        else => {
            print("Error: ErroneousMessage\n", .{});
        },
    }
    return message;
}
