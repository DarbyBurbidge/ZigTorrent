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

const TrackerQuery = struct { info_hash: []u8, peer_id: []u8, port: u64, uploaded: u32, downloaded: u32, compact: u32, left: u64 };

pub const TrackerResponse = struct { interval: u64, peers: ?[]Peer };

pub fn contactTracker(allocator: std.mem.Allocator, url: []const u8, peer_id: []u8, info_hash: [20]u8, length: u64, response: *TrackerResponse, resp_mtx: *std.Thread.Mutex) void {
    var encoded_hash = [_]u8{0} ** 100;
    var hash_stream = std.io.fixedBufferStream(&encoded_hash);
    std.Uri.Component.percentEncode(hash_stream.writer(), &info_hash, isValid) catch |err| {
        print("{}\n", .{err});
    };
    const h_encode_s: u64 = arr_len(&encoded_hash);
    var encoded_id = [_]u8{0} ** 100;
    var id_stream = std.io.fixedBufferStream(&encoded_id);
    std.Uri.Component.percentEncode(id_stream.writer(), peer_id, isValid) catch |err| {
        print("{}\n", .{err});
    };
    const id_encode_s: u64 = arr_len(&encoded_id);
    const port: u64 = TRACKER_PORT;
    const request = createRequestSlice(allocator, url, .{ .info_hash = encoded_hash[0..h_encode_s], .peer_id = encoded_id[0..id_encode_s], .port = port, .uploaded = 0, .downloaded = 0, .compact = 1, .left = length }) catch return;
    defer allocator.free(request);
    print("{s}\n", .{request});

    const uri = std.Uri.parse(request) catch return;
    var client = std.http.Client{ .allocator = allocator };
    var buf = [_]u8{0} ** MAX_BUF_SIZE;

    // send request to tracker
    if (client.open(.GET, uri, .{ .server_header_buffer = &buf, .headers = .{}, .keep_alive = false })) |*u_req| {
        var b_buf = [_]u8{0} ** MAX_BUF_SIZE;
        var req = u_req.*;
        req.send() catch return;
        req.finish() catch return;
        req.wait() catch return;
        //print("status={d}\n", .{req.response.status});
        //print("{?s}\n", .{ uri.host.?.percent_encoded });
        const rd_bytes = req.response.parser.read(req.connection.?, &b_buf, false) catch return;
        //print("parser.get(): {s}\n\n", .{b_buf[0..rd_bytes]});
        var peers = "5:peers".*;
        const peer_idx = includes(b_buf[0..rd_bytes], &peers);
        if (peer_idx > 0) {
            const t_response = buildResponseStruct(allocator, b_buf[0..rd_bytes]) catch return;
            errdefer freeResponse(allocator, t_response);
            resp_mtx.lock();
            defer resp_mtx.unlock();
            response.interval = t_response.interval;
            response.peers = t_response.peers;
            return;
        }
    } else |_| {
        print("Error: CouldNotContactTracker\n", .{});
        return;
    }
    print("Error: TrackerResponseContainedNoPeers\n", .{});
    return;
}

fn buildResponseStruct(allocator: std.mem.Allocator, buf: []u8) !TrackerResponse {
    var p_buf = buf;
    var peers: []Peer = undefined;
    var interval: u64 = 0;
    const tree = try Bencode.ValueTree.parse(&p_buf, allocator);
    if (Bencode.mapLookup(tree.root.Map, "interval")) |t_interval| {
        interval = @intCast(t_interval.Integer);
    }
    if (Bencode.mapLookup(tree.root.Map, "peers")) |t_peers| {
        print("peer length: {}\n", .{t_peers.String.len});
        const num_peers = t_peers.String.len / 6;
        peers = try allocator.alloc(Peer, num_peers);
        for (0..num_peers) |i| {
            const ip = t_peers.String[(i * 6)..(i * 6 + 4)];
            const port = t_peers.String[(i * 6 + 4)..(i * 6 + 6)];
            const ip_sized = ip[0..4];
            const port_sized = std.mem.readInt(u16, port[0..2], .big);
            peers[i] = try Peer.init(allocator, ip_sized.*, port_sized);
        }
    }
    return TrackerResponse{ .interval = interval, .peers = peers };
}

fn freeResponse(allocator: std.mem.Allocator, t_response: TrackerResponse) void {
    allocator.free(t_response.peers);
}

pub fn createRequestSlice(allocator: std.mem.Allocator, host: []const u8, params: TrackerQuery) ![]u8 {
    const query = try std.fmt.allocPrint(allocator, "?info_hash={s}&peer_id={s}&port={}&uploaded={}&downloaded={}&compact={}&left={}", .{ params.info_hash, params.peer_id, params.port, params.uploaded, params.downloaded, params.compact, params.left });
    defer allocator.free(query);
    const request = try std.fmt.allocPrint(allocator, "{s}{s}", .{ host, query });
    return request;
}
