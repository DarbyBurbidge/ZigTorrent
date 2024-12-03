const std = @import("std");
const assert = std.debug.assert;

const Bencode = @import("./Bencode.zig");
const utils = @import("./utils.zig");
const consts = @import("./consts.zig");
const includes = utils.includes_substr;
const MAX_FILE_SIZE = consts.MAX_FILE_SIZE;
const HASH_LEN = consts.HASH_LEN;

pub const TorrentFile = struct {
    announce: [][]u8,
    comment: []u8,
    creation_date: u64,
    info_hash: [HASH_LEN]u8,
    length: u64,
    name: []u8,
    piece_length: u64,
    pieces: [][HASH_LEN]u8,
};

pub fn parseTorrentFile(buf: []u8, allocator: *std.mem.Allocator) !TorrentFile {
    var announce: [][]u8 = undefined;
    var comment: []u8 = undefined;
    var creation_date: u64 = undefined;
    var info_hash = [_]u8{0} ** HASH_LEN;
    var length: u64 = undefined;
    var name: []u8 = undefined;
    var piece_length: u64 = undefined;
    var pieces: [][HASH_LEN]u8 = undefined;
    var p_buf = buf;

    const tree = try Bencode.ValueTree.parse(&p_buf, allocator);
    if (Bencode.mapLookup(tree.root.Map, "announce")) |t_announce| {
        if (Bencode.mapLookup(tree.root.Map, "announce-list")) |t_announce_list| {
            var i: u32 = 0;
            announce = try allocator.alloc([]u8, t_announce_list.Array.items.len + 1);
            i += 1;
            for (t_announce_list.Array.items) |item| {
                for (item.Array.items) |entry| {
                    announce[i] = try allocator.dupe(u8, entry.String[0..]);
                    i += 1;
                }
            }
        } else {
            announce = try allocator.alloc([]u8, 1);
        }
        announce[0] = try allocator.dupe(u8, t_announce.String[0..]);
    }
    if (Bencode.mapLookup(tree.root.Map, "comment")) |t_comment| {
        std.debug.print("comment: {s}\n", .{t_comment.String});
        comment = try allocator.dupe(u8, t_comment.String[0..]);
    }
    if (Bencode.mapLookup(tree.root.Map, "creation date")) |t_date| {
        creation_date = @intCast(t_date.Integer);
    }
    if (Bencode.mapLookup(tree.root.Map, "info")) |t_info| {
        var t_info_str = [_]u8{0} ** MAX_FILE_SIZE;
        var stream = std.io.fixedBufferStream(&t_info_str);
        var s_substr = "4:info".*;
        var e_substr = "8:url-list".*;
        const s_idx = includes(buf, &s_substr) + s_substr.len;
        const e_idx = includes(buf, &e_substr);
        //std.debug.print("info indices: {}, {}\n", .{ s_idx, buf[@intCast(e_idx)] });
        if (s_idx > 0 and e_idx > 0) {
            const write_len = try stream.write(buf[@intCast(s_idx)..@intCast(e_idx)]);
            std.crypto.hash.Sha1.hash(t_info_str[0..write_len], &info_hash, .{});
            //std.debug.print("hash: {x}\n", .{&info_hash});
        }

        if (Bencode.mapLookup(t_info.Map, "length")) |info_length| {
            length = @intCast(info_length.Integer);
        }
        if (Bencode.mapLookup(t_info.Map, "name")) |info_name| {
            name = try allocator.dupe(u8, info_name.String[0..]);
        }
        if (Bencode.mapLookup(t_info.Map, "piece length")) |info_p_length| {
            piece_length = @intCast(info_p_length.Integer);
        }
        if (Bencode.mapLookup(t_info.Map, "pieces")) |info_pieces| {
            const num_pieces = info_pieces.String.len / HASH_LEN;
            assert(info_pieces.String.len == num_pieces * HASH_LEN);
            pieces = try allocator.alloc([HASH_LEN]u8, num_pieces);
            for (0..num_pieces) |hash_idx| {
                for (0..HASH_LEN) |byte_idx| {
                    pieces[hash_idx][byte_idx] = info_pieces.String[hash_idx * HASH_LEN + byte_idx];
                }
                //pieces[hash_idx] = try allocator.dupe(u8, info_pieces.String[hash_idx * HASH_LEN .. hash_idx * HASH_LEN + HASH_LEN]);
            }
            //std.debug.print("{s}\n", .{info_pieces.String});
        }
    }
    return TorrentFile{
        .announce = announce,
        .comment = comment[0..],
        .creation_date = creation_date,
        .info_hash = info_hash,
        .length = length,
        .name = name[0..],
        .piece_length = piece_length,
        .pieces = pieces[0..][0..],
    };
}
