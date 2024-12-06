const std = @import("std");
const print = std.debug.print;
const RGen = std.Random.DefaultPrng;

const Torrent = @import("./Torrent.zig");
const Tracker = @import("./Tracker.zig");
const TrackerResponse = Tracker.TrackerResponse;
const Peer = @import("./Peer.zig").Peer;
const manageConn = @import("./Peer.zig").manageConn;
const contactTracker = @import("./Tracker.zig").contactTracker;
const consts = @import("./consts.zig");
const containsHttp = @import("./utils.zig").containsHttp;
const MAX_FILE_SIZE = consts.MAX_FILE_SIZE;
const MAX_PATH = consts.MAX_PATH;
const HASH_LEN = consts.HASH_LEN;
const FILE_DIR = consts.FILE_DIR;
const TOR_DIR = consts.TOR_DIR;

pub const FileBuffer = struct {
    mtx: std.Thread.Mutex,
    buf: []u8,
};

pub const FileBitField = struct {
    mtx: std.Thread.Mutex,
    b_field: []u1,
};

pub const FileManager = struct {
    allocator: std.mem.Allocator,
    peer_id: [HASH_LEN]u8,
    t_file: Torrent.TorrentFile,
    f_file: std.fs.File.Stat,
    f_buf: FileBuffer,
    f_bfield: FileBitField,
    t_mtx: std.Thread.Mutex,
    peers: std.ArrayList(Peer),
    p_threads: std.ArrayList(std.Thread),

    pub fn init(allocator: std.mem.Allocator, t_dir: std.fs.Dir, t_file: std.fs.Dir.Entry) !FileManager {
        var t_buf = [_]u8{0} ** (MAX_FILE_SIZE);
        var ot_file = try t_dir.openFile(t_file.name, .{ .mode = .read_only });
        defer ot_file.close();
        const bytes_r = try ot_file.read(&t_buf);
        const t_obj = try Torrent.parseTorrentFile(t_buf[0..bytes_r], allocator);
        const f_stat = try setDestFile(t_obj.name);
        const peer_id = try setPeerId();
        print("in File init, length: {}\n", .{t_obj.length});
        return FileManager{
            .allocator = allocator,
            .peer_id = peer_id,
            .t_file = t_obj,
            .f_file = f_stat,
            .f_buf = FileBuffer{
                .mtx = std.Thread.Mutex{},
                .buf = try allocator.alloc(u8, t_obj.length),
            },
            .f_bfield = FileBitField{
                .mtx = std.Thread.Mutex{},
                .b_field = try allocator.alloc(u1, t_obj.length / t_obj.piece_length),
            },
            .t_mtx = std.Thread.Mutex{},
            .peers = std.ArrayList(Peer).init(allocator),
            .p_threads = std.ArrayList(std.Thread).init(allocator),
        };
    }

    // get stat of file, if it doesn't exist, create it
    fn setDestFile(name: []u8) !std.fs.File.Stat {
        var path_buf = [_]u8{0} ** MAX_PATH;
        const path_slice = try std.fmt.bufPrint(
            &path_buf,
            "./files/{s}",
            .{name},
        );
        std.debug.print("path: {s}\n", .{path_slice});
        const o_file = std.fs.cwd().createFile(
            path_slice,
            .{ .exclusive = true },
        );
        if (o_file) |u_o_file| {
            u_o_file.close();
        } else |err| {
            err catch {};
        }
        const f_stat = try std.fs.cwd().statFile(path_slice);
        return f_stat;
    }

    fn setPeerId() ![HASH_LEN]u8 {
        var peer_id = [_]u8{0} ** HASH_LEN;
        var rnd = RGen.init(@intCast(std.time.timestamp()));
        for (0..peer_id.len) |i| {
            peer_id[i] = rnd.random().uintAtMost(u8, 255);
        }
        return peer_id;
    }

    const TrackerThread = struct { thread: std.Thread, response: *TrackerResponse };

    // initiate torrenting by contacting tracker
    // if it returns peers, add them to the list of peers and
    // stop looking if we have more than 30 peers
    pub fn beginTorrent(self: *@This()) !void {
        var t_threads = std.ArrayList(TrackerThread).init(self.allocator);
        defer t_threads.deinit();
        var r_mtx = std.Thread.Mutex{};
        var responses: []TrackerResponse = try self.allocator.alloc(TrackerResponse, self.t_file.announce.items.len);
        defer self.allocator.free(responses);

        for (self.t_file.announce.items, 0..) |u_announce, i| {
            responses[i] = TrackerResponse{
                .interval = 0,
                .peers = undefined,
            };
            if (containsHttp(u_announce)) {
                print("Contacting Tracker\n", .{});
                const maybe_thread: ?std.Thread = std.Thread.spawn(
                    .{},
                    contactTracker,
                    .{
                        self.allocator,
                        u_announce,
                        &self.peer_id,
                        self.t_file.info_hash,
                        self.t_file.length,
                        &responses[i],
                        &r_mtx,
                    },
                ) catch undefined;
                if (maybe_thread) |thread| {
                    try t_threads.append(TrackerThread{
                        .thread = thread,
                        .response = &responses[i],
                    });
                }
            }
        }
        for (t_threads.items) |tracker_t| {
            tracker_t.thread.join();
            if (tracker_t.response.peers) |peers| {
                print("Tracker Responded\n", .{});
                // for each new peer, scan existing peers and only include if unique
                for (peers) |peer| {
                    var exists = true;
                    for (self.peers.items) |s_peer| {
                        for (0..peer.ip.len) |i| {
                            if (peer.ip[i] != s_peer.ip[i]) {
                                exists = false;
                            }
                        }
                    }
                    if (!exists or self.peers.items.len == 0) {
                        try self.peers.append(peer);
                    }
                }
            }
        }
        print("Gathered {} Peers\n", .{self.peers.items.len});
        _ = try self.contactPeers();
    }

    // Spawn Peer Threads and start Peer Management
    fn contactPeers(self: *@This()) !void {
        var threads = std.ArrayList(std.Thread).init(self.allocator);
        for (0..self.peers.items.len) |i| {
            print("Initiating Peer Connection Manager: {x}, {}\n", .{ self.peers.items[i].ip, i });
            const new_manager = try std.Thread.spawn(.{}, manageConn, .{ &self.peers.items[i], self.peer_id, self.t_file.info_hash, &self.f_buf, &self.f_bfield });
            try threads.append(new_manager);
        }
        for (threads.items) |thread| {
            thread.join();
        }
    }
};
