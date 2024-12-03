const std = @import("std");
const net = std.net;
const os = std.os.linux;
const StreamServer = net.StreamServer;
const Address = net.Address;
const print = std.debug.print;

const Peer = @import("./Peer.zig").Peer;
const Bencode = @import("./Bencode.zig");
const utils = @import("./utils.zig");
const consts = @import("./consts.zig");
const isValid = utils.isValidUriChar;
const arr_len = utils.arr_len;
const includes = utils.includes_substr;
const TRACKER_PORT = consts.TRACKER_PORT;
const MAX_BUF_SIZE = consts.MAX_BUF_SIZE;
const HASH_LEN = consts.HASH_LEN;

const stdout = std.io.getStdOut();
const RGen = std.Random.DefaultPrng;

const TrackerQuery = struct { info_hash: []u8, peer_id: []u8, port: u64, uploaded: u32, downloaded: u32, compact: u32, left: u64 };

const TrackerResponse = struct { interval: u64, peers: []Peer };

pub fn contactTracker(allocator: *std.mem.Allocator, url: []u8, info_hash: [20]u8, length: u64) !void {
    var peer_id = [_]u8{0} ** HASH_LEN;
    var rnd = RGen.init(@intCast(std.time.timestamp()));
    for (0..peer_id.len) |i| {
        peer_id[i] = rnd.random().uintAtMost(u8, 255);
    }

    var encoded_hash = [_]u8{0} ** 100;
    var hash_stream = std.io.fixedBufferStream(&encoded_hash);
    try std.Uri.Component.percentEncode(hash_stream.writer(), &info_hash, isValid);
    const h_encode_s: u64 = arr_len(&encoded_hash);
    var encoded_id = [_]u8{0} ** 100;
    var id_stream = std.io.fixedBufferStream(&encoded_id);
    try std.Uri.Component.percentEncode(id_stream.writer(), &peer_id, isValid);
    const id_encode_s: u64 = arr_len(&encoded_id);
    const port: u64 = TRACKER_PORT;
    const request = try createRequestSlice(allocator.*, url, .{ .info_hash = encoded_hash[0..h_encode_s], .peer_id = encoded_id[0..id_encode_s], .port = port, .uploaded = 0, .downloaded = 0, .compact = 1, .left = length });
    //print("{s}\n", .{request});

    const uri = try std.Uri.parse(request);
    var client = std.http.Client{ .allocator = allocator.* };
    var buf = [_]u8{0} ** MAX_BUF_SIZE;

    if (std.http.Client.open(&client, .GET, uri, .{ .server_header_buffer = &buf, .headers = .{} })) |*u_req| {
        var b_buf = [_]u8{0} ** MAX_BUF_SIZE;
        var req = u_req.*;
        try req.send();
        try req.finish();
        try req.wait();
        print("status={d}\n", .{req.response.status});
        print("{?s} {s}\n", .{ uri.host.?.percent_encoded, req.response.parser.header_bytes_buffer });
        const rd_bytes = try req.response.parser.read(req.connection.?, &b_buf, false);
        print("parser.get(): {s}\n\n", .{b_buf[0..rd_bytes]});
        var peers = "5:peers".*;
        const peer_idx = includes(b_buf[0..rd_bytes], &peers);
        if (peer_idx > 0) {
            const t_response = try buildResponseStruct(allocator, b_buf[0..rd_bytes]);
            print("{any}\n", .{t_response});
            for (t_response.peers) |_| {}
        }
    } else |_| {
        // TODO: Log error
        //print("{}\n", .{err});
    }
    return;
}

fn buildResponseStruct(allocator: *std.mem.Allocator, buf: []u8) !TrackerResponse {
    var p_buf = buf;
    var peers: []Peer = undefined;
    var interval: u64 = 0;
    const tree = try Bencode.ValueTree.parse(&p_buf, allocator);
    if (Bencode.mapLookup(tree.root.Map, "interval")) |t_interval| {
        interval = @intCast(t_interval.Integer);
    }
    if (Bencode.mapLookup(tree.root.Map, "peers")) |t_peers| {
        print("peers: {s}\n", .{t_peers.String[0..]});
        print("peer length: {}\n", .{t_peers.String.len});
        const num_peers = t_peers.String.len / 6;
        peers = try allocator.alloc(Peer, num_peers);
        for (0..num_peers) |i| {
            const ip = t_peers.String[(i * 6)..(i * 6 + 4)];
            const port = t_peers.String[(i * 6 + 4)..(i * 6 + 6)];
            const ip_sized = ip[0..4];
            const port_sized = port[0..2];
            peers[i] = try Peer.init(allocator.*, ip_sized.*, port_sized.*);
        }
    }
    return TrackerResponse{ .interval = interval, .peers = peers };
}

pub fn createRequestSlice(allocator: std.mem.Allocator, host: []u8, params: TrackerQuery) ![]u8 {
    const query = try std.fmt.allocPrint(allocator, "?info_hash={s}&peer_id={s}&port={}&uploaded={}&downloaded={}&compact={}&left={}", .{ params.info_hash, params.peer_id, params.port, params.uploaded, params.downloaded, params.compact, params.left });
    const request = try std.fmt.allocPrint(allocator, "{s}{s}", .{ host, query });
    return request;
}
