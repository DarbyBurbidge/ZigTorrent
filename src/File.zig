const std = @import("std");
const print = std.debug.print;
const RGen = std.Random.DefaultPrng;

const Torrent = @import("./Torrent.zig");
const Tracker = @import("./Tracker.zig");
const TrackerResponse = Tracker.TrackerResponse;
const Peer = @import("./Peer.zig").Peer;
const contactTracker = @import("./Tracker.zig").contactTracker;
const consts = @import("./consts.zig");
const containsHttp = @import("./utils.zig").containsHttp;
const MAX_FILE_SIZE = consts.MAX_FILE_SIZE;
const MAX_PATH = consts.MAX_PATH;
const HASH_LEN = consts.HASH_LEN;
const FILE_DIR = consts.FILE_DIR;
const TOR_DIR = consts.TOR_DIR;

pub const FileManager = struct {
    allocator: std.mem.Allocator,
    peer_id: [HASH_LEN]u8,
    t_file: Torrent.TorrentFile,
    f_file: std.fs.File.Stat,
    t_mtx: std.Thread.Mutex,
    f_mtx: std.Thread.Mutex,
    peers: std.ArrayList(Peer),

    pub fn init(allocator: std.mem.Allocator, t_dir: std.fs.Dir, t_file: std.fs.Dir.Entry) !FileManager {
        var t_buf = [_]u8{0} ** (MAX_FILE_SIZE);
        var ot_file = try t_dir.openFile(t_file.name, .{ .mode = .read_only });
        defer ot_file.close();
        const bytes_r = try ot_file.read(&t_buf);
        const t_obj = try Torrent.parseTorrentFile(t_buf[0..bytes_r], allocator);
        const f_stat = try setDestFile(t_obj.name);
        const peer_id = try setPeerId();
        return FileManager{
            .allocator = allocator,
            .peer_id = peer_id,
            .t_file = t_obj,
            .f_file = f_stat,
            .t_mtx = std.Thread.Mutex{},
            .f_mtx = std.Thread.Mutex{},
            .peers = std.ArrayList(Peer).init(allocator),
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
        var responses: []TrackerResponse = try self.allocator.alloc(TrackerResponse, self.t_file.announce.len);
        defer self.allocator.free(responses);

        for (self.t_file.announce, 0..) |u_announce, i| {
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
                for (peers) |peer| {
                    try self.peers.append(peer);
                }
            }
        }
        print("Gathered {} Peers\n", .{self.peers.items.len});
        _ = try self.download();
    }

    fn download(self: *@This()) ![]u8 {
        const dl_buf = self.allocator.alloc(u8, self.t_file.length / 8);
        for (self.peers.items) |u_peer| {
            var peer = u_peer;
            print("Starting Download for: {s}\n", .{self.t_file.name});
            peer.connect(self.peer_id, self.t_file.info_hash) catch |err| {
                print("{}\n", .{err});
            };
            print("Completed Handshake: {s}\n", .{u_peer.ip});
        }
        return dl_buf;
    }
};
