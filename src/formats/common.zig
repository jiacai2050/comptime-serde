const std = @import("std");

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}
