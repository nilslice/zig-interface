const std = @import("std");
const Interface = @import("interface").Interface;

// Simple interface to test VTable generation
const IWriter = Interface(.{
    .write = fn ([]const u8) anyerror!usize,
}, null);

// Generate the VTable-based runtime type
const Writer = IWriter.Type();

// Test implementation - Simplified with auto-generated wrappers
const BufferWriter = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BufferWriter {
        return .{
            .buffer = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferWriter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn write(self: *BufferWriter, data: []const u8) !usize {
        try self.buffer.appendSlice(self.allocator, data);
        return data.len;
    }

    pub fn getWritten(self: *const BufferWriter) []const u8 {
        return self.buffer.items;
    }
};

test "vtable interface type generation" {
    // Verify the interface type was created
    const VTableType = Writer.VTable;
    const vtable_fields = std.meta.fields(VTableType);

    try std.testing.expectEqual(@as(usize, 1), vtable_fields.len);
    try std.testing.expectEqualStrings("write", vtable_fields[0].name);
}

test "vtable interface runtime usage with from()" {
    var buffer_writer = BufferWriter.init(std.testing.allocator);
    defer buffer_writer.deinit();

    // Create interface wrapper using from() - no manual wrappers needed!
    const writer_interface = Writer.from(&buffer_writer);

    // Use through the interface
    const written = try writer_interface.vtable.write(writer_interface.ptr, "Hello, ");
    try std.testing.expectEqual(@as(usize, 7), written);

    const written2 = try writer_interface.vtable.write(writer_interface.ptr, "World!");
    try std.testing.expectEqual(@as(usize, 6), written2);

    // Verify the data was written
    try std.testing.expectEqualStrings("Hello, World!", buffer_writer.getWritten());
}

test "vtable interface with multiple implementations" {
    // First implementation
    var buffer_writer1 = BufferWriter.init(std.testing.allocator);
    defer buffer_writer1.deinit();

    var buffer_writer2 = BufferWriter.init(std.testing.allocator);
    defer buffer_writer2.deinit();

    // Create interface wrappers - auto-generated VTables
    const writer1 = Writer.from(&buffer_writer1);
    const writer2 = Writer.from(&buffer_writer2);

    // Write to different writers through same interface
    _ = try writer1.vtable.write(writer1.ptr, "First");
    _ = try writer2.vtable.write(writer2.ptr, "Second");

    try std.testing.expectEqualStrings("First", buffer_writer1.getWritten());
    try std.testing.expectEqualStrings("Second", buffer_writer2.getWritten());
}
