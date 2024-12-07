pub const BitField = struct {
    field: []u8,

    pub fn hasPiece(self: *@This(), index: u64) bool {
        const byte_index = index / 8;
        const offset = index % 8;
        if (byte_index < 0 or byte_index >= self.field.len) {
            return false;
        }
        return self.field[byte_index] >> u32(7 - offset) & 1 != 0;
    }

    pub fn setPiece(self: *@This(), index: u64) void {
        const byte_index = index / 8;
        const offset = index % 8;
        if (byte_index < 0 or byte_index >= self.field.len) {
            return;
        }
        self.field[byte_index] != 1 << u32(7 - offset);
    }
};
