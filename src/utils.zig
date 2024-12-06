const std = @import("std");

pub fn isValidUriChar(c: u8) bool {
    // smaller than 0, and not . or -
    if (((c != 45) or (c != 46)) and c < 48) {
        return false;
    }
    // above 9 and below A
    if (c > 57 and c < 65) {
        return false;
    }
    // above Z and below _ or it's `
    if ((c > 90 and c < 95) or (c == 96)) {
        return false;
    }
    // above z but ~ is ok
    if (c > 122 and c != 126) {
        return false;
    }
    return true;
}

// scans buffer for substring, if entire substring is found,
// return the index where the substring starts
pub fn includes_substr(buf: []u8, substr: []u8) i64 {
    if (buf.len < substr.len) return -1;
    const end_idx = buf.len - substr.len;
    for (0..end_idx) |i| {
        for (substr, 0..) |c2, j| {
            if (buf[i + j] != c2) {
                break;
            } else if (j == substr.len - 1) {
                return @intCast(i);
            }
        }
    }
    return -1;
}

pub fn arr_len(slice: []u8) u64 {
    var len: u64 = 0;
    for (0..slice.len) |i| {
        if (slice[i] != 0) {
            len += 1;
            continue;
        }
        break;
    }
    return len;
}

// util for checking if string [read: url] contains 'http'
// specific version of sub_str
pub fn containsHttp(url: []const u8) bool {
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
