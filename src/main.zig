const std = @import("std");
const getopt = @import("./getopt.zig");
const Peer = @import("./Peer.zig");
const Bencode = @import("./Bencode.zig");
const Torrent = @import("./Torrent.zig");

const os = std.os;

const MAX_PATH = 4096;
const MAX_FILE_SIZE = 1048576;

var filename: ?[]const u8 = undefined;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var verbose = false;
    var opts = getopt.getopt("vf:");
    while (opts.next()) |maybe_opt| {
        if (maybe_opt) |opt| {
            std.debug.print("arg: {?s}\n", .{opt.arg});
            switch (opt.opt) {
                'v' => {
                    verbose = true;
                },
                'f' => {
                    if (verbose) {
                        std.debug.print("filename: {?s}\n", .{opt.arg});
                    }
                    filename = opt.arg;
                    std.debug.print("filename: {?s}\n", .{filename});
                },
                else => unreachable,
            }
        } else break;
    } else |err| {
        switch (err) {
            getopt.Error.InvalidOption => std.debug.print("invalid option: {c}\n", .{opts.optopt}),
            getopt.Error.MissingArgument => std.debug.print("option requires an argument: {c}\n", .{opts.optopt}),
        }
    }
    std.debug.print("remaining args: {?s}\n", .{opts.args()});

    var cwd = [_]u8{0} ** MAX_PATH;
    var t_dir = [_]u8{0} ** MAX_PATH;
    var f_dir = [_]u8{0} ** MAX_PATH;
    var t_dirname = "/torrents".*;
    var f_dirname = "/files".*;
    std.debug.print("cwd: {s}, len: {d}\n", .{ cwd, cwd.len });
    const count = os.linux.getcwd(&cwd, cwd.len);
    std.debug.print("cwd: {s}, len: {d}, count: {d}\n", .{ cwd, cwd.len, count });
    _ = try arrncpy(&t_dir, &cwd, 0, 0, count);
    _ = try arrncpy(&f_dir, &cwd, 0, 0, count);
    std.debug.print("t_dir: {s}, len: {d}\n", .{ t_dir, t_dir.len });
    std.debug.print("f_dir: {s}, len: {d}\n", .{ f_dir, f_dir.len });
    _ = try arrncpy(&t_dir, &t_dirname, count, 0, t_dirname.len);
    _ = try arrncpy(&f_dir, &f_dirname, count, 0, f_dirname.len);
    std.debug.print("t_dir: {s}, len: {d}\n", .{ t_dir, t_dir.len });
    std.debug.print("f_dir: {s}, len: {d}\n", .{ f_dir, f_dir.len });

    std.debug.print("cwd: {s}, len: {d}, count: {d}\n", .{ cwd, cwd.len, count });

    // open directory and list contents
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    std.debug.print("dir_fd: {}\n", .{dir.fd});
    defer dir.close();
    var dir_iter = dir.iterate();
    var i: usize = 0;
    while (try dir_iter.next()) |contents| : (i += 1) {
        std.debug.print("dir contents: {s}, count: {d}\n", .{ contents.name, i });
    }

    var torrents = try std.fs.cwd().openDir("./torrents", .{ .iterate = true });
    var t_iter = torrents.iterate();
    while (try t_iter.next()) |contents| : (i += 1) {
        std.debug.print("dir contents: {s}, count: {d}\n", .{ contents.name, i });
        if (std.mem.indexOf(u8, contents.name, ".torrent")) |_| {
            var file_buf = [_]u8{0} ** (MAX_FILE_SIZE);
            var t_file = try torrents.openFile(contents.name, .{ .mode = .read_only });
            const read_bytes = try t_file.read(&file_buf);
            const buf: []u8 = file_buf[0..read_bytes];
            const torrent_file = try Torrent.parseTorrentFile(buf, &allocator);

            const contactTracker = @import("./Tracker.zig").contactTracker;
            std.debug.print("{s}", .{torrent_file.info_hash});
            for (torrent_file.announce) |u_announce| {
                if (usesHttp(u_announce)) {
                    _ = try std.Thread.spawn(.{ .allocator = allocator }, contactTracker, .{ &allocator, u_announce, torrent_file.info_hash, torrent_file.length });
                    //try contactTracker(&allocator, u_announce, torrent_file.info_hash, torrent_file.length);
                }
                std.time.sleep(std.time.ns_per_s / 4);
            }
        }
    }
}

pub fn usesHttp(url: []u8) bool {
    const http = "http";
    if (url.len < http.len) {
        return false;
    }
    for (0..http.len) |i| {
        if (http[i] != url[i]) {
            return false;
        }
    }
    return true;
}

pub fn arrncpy(dest: []u8, src: []u8, dest_start: usize, src_start: usize, src_end: usize) !usize {
    var dest_idx: usize = 0;
    for (src_start..src_end) |i| {
        dest_idx = dest_start + (i - src_start);
        if (dest_idx > dest.len) {
            return error.DestinationOOB;
        } else if (src_end > src.len) {
            return error.SourceOOB;
        }
        dest[dest_idx] = src[i];
    }
    return dest_idx - dest_start;
}
