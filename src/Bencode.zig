// Code Attributed to gaultier
// https://github.com/gaultier/zig-bencode
// which is no longer maintained
//
// w/ minor tweaks by Darby Burbidge
// in order to bring code up-to-date
// w/ Zig v0.14.0-dev.1911+3bf89f55c

const std = @import("std");

const MAX_LEN = 4096;

fn outputUnicodeEscape(
    codepoint: u21,
    out_stream: anytype,
) !void {
    if (codepoint <= 0xFFFF) {
        // If the character is in the Basic Multilingual Plane (U+0000 through U+FFFF),
        // then it may be represented as a six-character sequence: a reverse solidus, followed
        // by the lowercase letter u, followed by four hexadecimal digits that encode the character's code point.
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(codepoint, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    } else {
        std.debug.assert(codepoint <= 0x10FFFF);
        // To escape an extended character that is not in the Basic Multilingual Plane,
        // the character is represented as a 12-character sequence, encoding the UTF-16 surrogate pair.
        const high: u16 = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
        const low: u16 = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(high, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(low, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    }
}

pub fn dump(value: Value, indent: usize) anyerror!void {
    var out_stream = std.io.getStdOut().writer();

    switch (value) {
        .Integer => |n| {
            try out_stream.print("{}", .{n});
        },
        .String => |s| {
            var i: usize = 0;

            try out_stream.print("\"", .{});
            if (std.unicode.utf8ValidateSlice(s)) {
                while (i < s.len) : (i += 1) {
                    switch (s[i]) {
                        // normal ascii character
                        0x20...0x21, 0x23...0x2E, 0x30...0x5B, 0x5D...0x7F => |c| try out_stream.writeByte(c),
                        // only 2 characters that *must* be escaped
                        '\\' => try out_stream.writeAll("\\\\"),
                        '\"' => try out_stream.writeAll("\\\""),
                        // solidus is optional to escape
                        '/' => {
                            try out_stream.writeByte('/');
                        },
                        // control characters with short escapes
                        // TODO: option to switch between unicode and 'short' forms?
                        0x8 => try out_stream.writeAll("\\b"),
                        0xC => try out_stream.writeAll("\\f"),
                        '\n' => try out_stream.writeAll("\\n"),
                        '\r' => try out_stream.writeAll("\\r"),
                        '\t' => try out_stream.writeAll("\\t"),
                        else => {
                            const ulen = std.unicode.utf8ByteSequenceLength(s[i]) catch unreachable;
                            // control characters (only things left with 1 byte length) should always be printed as unicode escapes
                            if (ulen == 1) {
                                const codepoint = std.unicode.utf8Decode(s[i .. i + ulen]) catch unreachable;
                                try outputUnicodeEscape(codepoint, out_stream);
                            } else {
                                try out_stream.writeAll(s[i .. i + ulen]);
                            }
                            i += ulen - 1;
                        },
                    }
                }
            } else {
                for (s) |c| {
                    try out_stream.print("\\x{X}", .{c});
                }
            }
            try out_stream.print("\"", .{});
        },
        .Array => |arr| {
            for (arr.items) |v| {
                try out_stream.print("\n", .{});
                try out_stream.writeByteNTimes(' ', indent);
                try out_stream.print("- ", .{});
                try dump(v, indent + 2);
            }
        },
        .Map => |*map| {
            for (map.items) |kv| {
                try out_stream.print("\n", .{});
                try out_stream.writeByteNTimes(' ', indent);
                try out_stream.print("\"{}\": ", .{kv.key});
                try dump(kv.value, indent + 2);
            }
        },
    }
}
pub const ValueTree = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *ValueTree) void {
        self.arena.deinit();
    }

    pub fn parse(input: *[]const u8, allocator: std.mem.Allocator) !ValueTree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a_allocator = arena.allocator();
        errdefer arena.deinit();
        const value = try parseInternal(input, a_allocator, 0);

        return ValueTree{ .arena = arena, .root = value };
    }

    fn parseInternal(input: *[]const u8, allocator: std.mem.Allocator, rec_count: usize) anyerror!Value {
        if (rec_count == 100) return error.RecursionLimitReached;

        if (peek(input.*)) |c| {
            return switch (c) {
                'i' => Value{ .Integer = try parseNumber(isize, input) },
                '0'...'9' => Value{ .String = try parseBytes([]const u8, u8, allocator, input) },
                'l' => {
                    var arr = Array.init(allocator);
                    errdefer arr.deinit();

                    try expectChar(input, 'l');
                    while (!match(input, 'e')) {
                        const v = try parseInternal(input, allocator, rec_count + 1);
                        try arr.append(v);
                    }
                    return Value{ .Array = arr };
                },
                'd' => {
                    var map = Map.init(allocator);

                    try expectChar(input, 'd');
                    while (!match(input, 'e')) {
                        const k = try parseBytes([]const u8, u8, allocator, input);
                        const v = try parseInternal(input, allocator, rec_count + 1);

                        if (mapLookup(map, k) != null) return error.DuplicateDictionaryKeys; // EEXISTS

                        try map.append(KV{ .key = try allocator.dupe(u8, k), .value = v });
                    }
                    return Value{ .Map = map };
                },
                else => error.UnexpectedChar,
            };
        } else return error.UnexpectedChar;
    }

    pub fn stringify(self: *@This(), out_stream: anytype) @TypeOf(out_stream).Error!void {
        return self.root.stringify(out_stream);
    }

    pub fn slicify(self: *@This()) []u8 {
        return self.root.slicify();
    }
};

pub const KV = struct {
    key: []const u8,
    value: Value,
};

pub const Map = std.ArrayList(KV);
pub const Array = std.ArrayList(Value);

pub fn mapLookup(map: Map, key: []const u8) ?*Value {
    for (map.items) |*kv| {
        if (std.mem.eql(u8, key, kv.key)) return &kv.value;
    }
    return null;
}

/// Represents a bencode value
pub const Value = union(enum) {
    Integer: isize,
    String: []const u8,
    Array: Array,
    Map: Map,

    pub fn stringifyValue(self: Value, out_stream: anytype) @TypeOf(out_stream).Error!void {
        switch (self) {
            .Integer => |value| {
                try out_stream.writeByte('i');
                try std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
                try out_stream.writeByte('e');
            },
            .Map => |map| {
                try out_stream.writeByte('d');
                for (map.items) |kv| {
                    try out_stream.writeAll(kv.key);
                    try stringifyValue(kv.value, out_stream);
                }

                try out_stream.writeByte('e');
                return;
            },
            .String => |s| {
                try std.fmt.formatIntValue(s.len, "", std.fmt.FormatOptions{}, out_stream);
                try out_stream.writeByte(':');
                try out_stream.writeAll(s[0..]);
                return;
            },
            .Array => |array| {
                try out_stream.writeByte('l');
                for (array.items) |x| {
                    try x.stringifyValue(out_stream);
                }
                try out_stream.writeByte('e');
                return;
            },
        }
    }
};

fn findFirstIndexOf(s: []const u8, needle: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

fn expectChar(s: *[]const u8, needle: u8) !void {
    if (s.*.len > 0 and s.*[0] == needle) {
        s.* = s.*[1..];
        return;
    }
    return error.UnexpectedChar;
}

fn parseNumber(comptime T: type, s: *[]const u8) anyerror!T {
    try expectChar(s, 'i');

    const optional_end_index = findFirstIndexOf(s.*[0..], 'e');
    if (optional_end_index) |end_index| {
        if (s.*[0..end_index].len == 0) return error.NoDigitsInNumber;
        const n = try std.fmt.parseInt(T, s.*[0..end_index], 10);

        if (s.*[0] == '0' and n != 0) return error.ForbiddenHeadingZeroInNumber;
        if (s.*[0] == '-' and n == 0) return error.ForbiddenNegativeZeroNumber;

        s.* = s.*[end_index..];
        try expectChar(s, 'e');

        return n;
    } else {
        return error.MissingTerminatingNumberToken;
    }
}

fn peek(s: []const u8) ?u8 {
    return if (s.len > 0) s[0] else null;
}

fn match(s: *[]const u8, needle: u8) bool {
    if (peek(s.*)) |c| {
        if (c == needle) {
            s.* = s.*[1..];
            return true;
        }
    }
    return false;
}

fn parseArray(comptime T: type, childType: type, allocator: std.mem.Allocator, s: *[]const u8, rec_count: usize) anyerror!T {
    try expectChar(s, 'l');

    var arraylist = std.ArrayList(childType).init(allocator);
    errdefer {
        arraylist.deinit();
    }

    while (!match(s, 'e')) {
        const item = try ValueTree.parseInternal(childType, allocator, s, rec_count + 1);
        try arraylist.append(item);
    }

    return arraylist.toOwnedSlice();
}

fn parseBytes(comptime T: type, childType: type, allocator: std.mem.Allocator, s: *[]const u8) anyerror!T {
    const optional_end_index = findFirstIndexOf(s.*[0..], ':');
    if (optional_end_index) |end_index| {
        if (s.*[0..end_index].len == 0) return error.MissingLengthBytes;

        const n = try std.fmt.parseInt(usize, s.*[0..end_index], 10);
        s.* = s.*[end_index..];
        try expectChar(s, ':');

        if (s.*.len < n) return error.InvalidByteLength;

        const bytes: []const u8 = s.*[0..n];
        var arraylist = std.ArrayList(childType).init(allocator);
        errdefer {
            arraylist.deinit();
        }
        try arraylist.appendSlice(bytes);

        s.* = s.*[n..];

        return arraylist.toOwnedSlice();
    }
    return error.MissingSeparatingStringToken;
}

pub fn stringify(value: anytype, out_stream: anytype) @TypeOf(out_stream).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            try out_stream.writeByte('i');
            try std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
            try out_stream.writeByte('e');
        },
        .@"union" => {
            if (comptime std.meta.hasFn(T, "bencodeStringify")) {
                return value.bencodeStringify(out_stream);
            }

            const info = @typeInfo(T).@"union";
            if (info.tag_type) |UnionTagType| {
                inline for (info.fields, 0..info.fields.len) |u_field, index| {
                    if (@intFromEnum(@as(UnionTagType, value)) == index) {
                        return try stringify(@field(value, u_field.name), out_stream);
                    }
                }
            } else {
                @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .@"struct" => |S| {
            if (comptime std.meta.hasFn(T, "bencodeStringify")) {
                return value.bencodeStringify(out_stream);
            }

            try out_stream.writeByte('d');
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.type == void) continue;

                try stringify(Field.name, out_stream);
                try stringify(@field(value, Field.name), out_stream);
            }
            try out_stream.writeByte('e');
            return;
        },
        .error_set => return stringify(@as([]const u8, @errorName(value)), out_stream),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return stringify(@as(Slice, value), out_stream);
                },
                else => {
                    // TODO: avoid loops?
                    //return stringify(value.*, out_stream);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                if (ptr_info.child == u8) {
                    try std.fmt.formatIntValue(value.len, "", std.fmt.FormatOptions{}, out_stream);
                    try out_stream.writeByte(':');
                    try out_stream.writeAll(value[0..]);
                    return;
                }

                try out_stream.writeByte('l');
                for (value) |x| {
                    try stringify(x, out_stream);
                }
                try out_stream.writeByte('e');
                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .array => return stringify(&value, out_stream),
        .vector => |info| {
            const array: [info.len]info.child = value;
            return stringify(&array, out_stream);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn isArray(v: Value) bool {
    return switch (v) {
        .Array => true,
        else => false,
    };
}

pub fn isInteger(v: Value) bool {
    return switch (v) {
        .Integer => true,
        else => false,
    };
}
pub fn isString(v: Value) bool {
    return switch (v) {
        .String => true,
        else => false,
    };
}
pub fn isMap(v: Value) bool {
    return switch (v) {
        .Map => true,
        else => false,
    };
}
