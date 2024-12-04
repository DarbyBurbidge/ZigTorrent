const std = @import("std");
const getopt = @import("./getopt.zig");
const Peer = @import("./Peer.zig");
const Bencode = @import("./Bencode.zig");
const Torrent = @import("./Torrent.zig");
const FileManager = @import("./File.zig").FileManager;
const initiateFileManager = @import("./File.zig");
const consts = @import("./consts.zig");
const MAX_PATH = consts.MAX_PATH;
const MAX_FILE_SIZE = consts.MAX_FILE_SIZE;

const os = std.os;

var filename: ?[]const u8 = undefined;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
    var t_threads: []std.Thread = try allocator.alloc(std.Thread, t_iter.end_index + 1);
    i = 0;
    while (try t_iter.next()) |t_file| : (i += 1) {
        std.debug.print("dir contents: {s}, count: {d}\n", .{ t_file.name, i });
        if (std.mem.indexOf(u8, t_file.name, ".torrent")) |_| {
            t_threads[i] = try std.Thread.spawn(.{ .allocator = allocator }, asyncCallFM, .{ allocator, torrents, t_file });
        }
    }
    for (t_threads) |t_thread| {
        std.Thread.join(t_thread);
    }
    while (true) {}
}

fn asyncCallFM(allocator: std.mem.Allocator, torrents: std.fs.Dir, t_file: std.fs.Dir.Entry) void {
    var f_mgr = FileManager.init(allocator, torrents, t_file) catch return;
    f_mgr.beginTorrent() catch return;
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
