const std = @import("std");
const Interface = @import("interface").Interface;

// First define our data type
const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

// Define our Repository interface with multiple methods
// Interface() now returns the vtable-based type directly
const Repository = Interface(.{
    .create = fn (User) anyerror!u32,
    .findById = fn (u32) anyerror!?User,
    .update = fn (User) anyerror!void,
    .delete = fn (u32) anyerror!void,
    .findByEmail = fn ([]const u8) anyerror!?User,
}, null);

// Implement a simple in-memory repository
pub const InMemoryRepository = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u32, User),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) InMemoryRepository {
        return .{
            .allocator = allocator,
            .users = std.AutoHashMap(u32, User).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *InMemoryRepository) void {
        self.users.deinit();
    }

    // Repository implementation methods
    pub fn create(self: *InMemoryRepository, user: User) !u32 {
        var new_user = user;
        new_user.id = self.next_id;
        try self.users.put(self.next_id, new_user);
        self.next_id += 1;
        return new_user.id;
    }

    pub fn findById(self: InMemoryRepository, id: u32) !?User {
        return self.users.get(id);
    }

    pub fn update(self: *InMemoryRepository, user: User) !void {
        if (!self.users.contains(user.id)) {
            return error.UserNotFound;
        }
        try self.users.put(user.id, user);
    }

    pub fn delete(self: *InMemoryRepository, id: u32) !void {
        if (!self.users.remove(id)) {
            return error.UserNotFound;
        }
    }

    pub fn findByEmail(self: InMemoryRepository, email: []const u8) !?User {
        var it = self.users.valueIterator();
        while (it.next()) |user| {
            if (std.mem.eql(u8, user.email, email)) {
                return user.*;
            }
        }
        return null;
    }
};

// Function that works with any Repository implementation (compile-time duck typing)
fn createUser(repo: anytype, name: []const u8, email: []const u8) !User {
    // Use .validation.satisfiedBy() to verify interface compliance at compile time
    comptime Repository.validation.satisfiedBy(@TypeOf(repo.*));

    const user = User{
        .id = 0,
        .name = name,
        .email = email,
    };

    const id = try repo.create(user);
    return User{
        .id = id,
        .name = name,
        .email = email,
    };
}

// Function that works with any Repository implementation via vtable (runtime polymorphism)
fn dynCreateUser(repo: Repository, name: []const u8, email: []const u8) !User {
    const user = User{
        .id = 0,
        .name = name,
        .email = email,
    };

    const id = try repo.vtable.create(repo.ptr, user);
    return User{
        .id = id,
        .name = name,
        .email = email,
    };
}

test "repository interface" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    // Verify at comptime that our implementation satisfies the interface
    // Use .validation namespace for compile-time validation
    comptime Repository.validation.satisfiedBy(@TypeOf(repo));
    // or, can pass the concrete struct type directly:
    comptime Repository.validation.satisfiedBy(InMemoryRepository);

    // Test create and findById
    const user1 = try createUser(&repo, "John Doe", "john@example.com");
    const found = try repo.findById(user1.id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("John Doe", found.?.name);

    // Test findByEmail
    const by_email = try repo.findByEmail("john@example.com");
    try std.testing.expect(by_email != null);
    try std.testing.expectEqual(user1.id, by_email.?.id);

    // Test update
    var updated_user = user1;
    updated_user.name = "Johnny Doe";
    try repo.update(updated_user);
    const found_updated = try repo.findById(user1.id);
    try std.testing.expect(found_updated != null);
    try std.testing.expectEqualStrings("Johnny Doe", found_updated.?.name);

    // Test delete
    try repo.delete(user1.id);
    const not_found = try repo.findById(user1.id);
    try std.testing.expect(not_found == null);

    // Test error cases
    try std.testing.expectError(error.UserNotFound, repo.update(User{
        .id = 999,
        .name = "Not Found",
        .email = "none@example.com",
    }));
    try std.testing.expectError(error.UserNotFound, repo.delete(999));
}

test "dynamic repository interface" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    // Test create and findById
    const user1 = try dynCreateUser(Repository.from(&repo), "John Doe", "john@example.com");
    const found = try repo.findById(user1.id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("John Doe", found.?.name);

    // Test findByEmail
    const by_email = try repo.findByEmail("john@example.com");
    try std.testing.expect(by_email != null);
    try std.testing.expectEqual(user1.id, by_email.?.id);

    // Test update
    var updated_user = user1;
    updated_user.name = "Johnny Doe";
    try repo.update(updated_user);
    const found_updated = try repo.findById(user1.id);
    try std.testing.expect(found_updated != null);
    try std.testing.expectEqualStrings("Johnny Doe", found_updated.?.name);

    // Test delete
    try repo.delete(user1.id);
    const not_found = try repo.findById(user1.id);
    try std.testing.expect(not_found == null);

    // Test error cases
    try std.testing.expectError(error.UserNotFound, repo.update(User{
        .id = 999,
        .name = "Not Found",
        .email = "none@example.com",
    }));
    try std.testing.expectError(error.UserNotFound, repo.delete(999));
}
