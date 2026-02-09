const std = @import("std");
const Interface = @import("interface").Interface;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

test "interface embedding" {
    // Base interfaces
    const Logger = Interface(.{
        .log = fn ([]const u8) void,
        .getLogLevel = fn () u8,
    }, null);

    const Metrics = Interface(.{
        .increment = fn ([]const u8) void,
        .getValue = fn ([]const u8) u64,
    }, .{Logger});

    // Complex interface that embeds both Logger and Metrics
    const MonitoredRepository = Interface(.{
        .create = fn (User) anyerror!u32,
        .findById = fn (u32) anyerror!?User,
        .update = fn (User) anyerror!void,
        .delete = fn (u32) anyerror!void,
    }, .{Metrics});

    // Implementation that satisfies all interfaces
    const TrackedRepository = struct {
        allocator: std.mem.Allocator,
        users: std.AutoHashMap(u32, User),
        next_id: u32,
        log_level: u8,
        metrics: std.StringHashMap(u64),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .users = std.AutoHashMap(u32, User).init(allocator),
                .next_id = 1,
                .log_level = 0,
                .metrics = std.StringHashMap(u64).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.metrics.deinit();
            self.users.deinit();
        }

        // Logger interface implementation
        pub fn log(self: Self, message: []const u8) void {
            _ = self;
            _ = message;
            // In real code: actual logging
        }

        pub fn getLogLevel(self: Self) u8 {
            return self.log_level;
        }

        // Metrics interface implementation
        pub fn increment(self: *Self, key: []const u8) void {
            if (self.metrics.get(key)) |value| {
                self.metrics.put(key, value + 1) catch {};
            } else {
                self.metrics.put(key, 1) catch {};
            }
        }

        pub fn getValue(self: Self, key: []const u8) u64 {
            return self.metrics.get(key) orelse 0;
        }

        // Repository interface implementation
        pub fn create(self: *Self, user: User) !u32 {
            self.log("Creating new user");
            self.increment("users.created");

            var new_user = user;
            new_user.id = self.next_id;
            try self.users.put(self.next_id, new_user);
            self.next_id += 1;
            return new_user.id;
        }

        pub fn findById(self: *Self, id: u32) !?User {
            self.increment("users.lookup");
            return self.users.get(id);
        }

        pub fn update(self: *Self, user: User) !void {
            self.log("Updating user");
            self.increment("users.updated");

            if (!self.users.contains(user.id)) {
                return error.UserNotFound;
            }
            try self.users.put(user.id, user);
        }

        pub fn delete(self: *Self, id: u32) !void {
            self.log("Deleting user");
            self.increment("users.deleted");

            if (!self.users.remove(id)) {
                return error.UserNotFound;
            }
        }
    };

    // Test that our implementation satisfies all interfaces
    comptime MonitoredRepository.validation.satisfiedBy(TrackedRepository);
    comptime Logger.validation.satisfiedBy(TrackedRepository);
    comptime Metrics.validation.satisfiedBy(TrackedRepository);

    // Test the actual implementation
    var repo = try TrackedRepository.init(std.testing.allocator);
    defer repo.deinit();

    // Create a user and verify metrics
    const user = User{ .id = 0, .name = "Test User", .email = "test@example.com" };
    const id = try repo.create(user);
    try std.testing.expectEqual(@as(u64, 1), repo.getValue("users.created"));

    // Look up the user and verify metrics
    const found = try repo.findById(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 1), repo.getValue("users.lookup"));

    // Test logging level
    try std.testing.expectEqual(@as(u8, 0), repo.getLogLevel());
}

test "interface embedding with conflicts" {
    // Two interfaces with conflicting method names
    const IBasicLogger = Interface(.{
        .log = fn ([]const u8) void,
    }, null);

    const IMetricLogger = Interface(.{
        .log = fn ([]const u8, u64) void,
    }, null);

    // This should fail to compile due to conflicting 'log' methods
    const IConflictingLogger = Interface(.{
        .write = fn ([]const u8) void,
    }, .{ IBasicLogger, IMetricLogger });

    // Implementation that tries to satisfy both
    const BadImplementation = struct {
        pub fn write(self: @This(), message: []const u8) void {
            _ = self;
            _ = message;
        }

        pub fn log(self: @This(), message: []const u8) void {
            _ = self;
            _ = message;
        }
    };

    // This should fail compilation with an ambiguous method error
    comptime {
        if (IConflictingLogger.validation.incompatibilities(BadImplementation).len == 0) {
            @compileError("Should have detected conflicting 'log' methods");
        }
    }
}

test "nested interface embedding" {
    // Base interface
    const ICloser = Interface(.{
        .close = fn () void,
    }, null);

    // Mid-level interface that embeds Closer
    const IWriter = Interface(.{
        .write = fn ([]const u8) anyerror!void,
    }, .{ICloser});

    // Top-level interface that embeds Writer
    const IFileWriter = Interface(.{
        .flush = fn () anyerror!void,
    }, .{IWriter});

    // Implementation that satisfies all interfaces
    const Implementation = struct {
        pub fn close(self: @This()) void {
            _ = self;
        }

        pub fn write(self: @This(), data: []const u8) !void {
            _ = self;
            _ = data;
        }

        pub fn flush(self: @This()) !void {
            _ = self;
        }
    };

    // Should satisfy all interfaces
    comptime IFileWriter.validation.satisfiedBy(Implementation);
    comptime IWriter.validation.satisfiedBy(Implementation);
    comptime ICloser.validation.satisfiedBy(Implementation);
}

test "high-level: runtime polymorphism with embedded interfaces" {
    // Define a practical monitoring system using embedded interfaces
    const Logger = Interface(.{
        .log = fn ([]const u8) void,
        .setLevel = fn (u8) void,
    }, null);

    const Metrics = Interface(.{
        .recordCount = fn ([]const u8, u64) void,
        .getCount = fn ([]const u8) u64,
    }, .{Logger});

    const Repository = Interface(.{
        .save = fn (User) anyerror!u32,
        .load = fn (u32) anyerror!?User,
    }, .{Metrics});

    // Implementation 1: In-memory repository with full monitoring
    const InMemoryRepo = struct {
        allocator: std.mem.Allocator,
        users: std.AutoHashMap(u32, User),
        metrics: std.StringHashMap(u64),
        next_id: u32,
        log_level: u8,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .users = std.AutoHashMap(u32, User).init(allocator),
                .metrics = std.StringHashMap(u64).init(allocator),
                .next_id = 1,
                .log_level = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.users.deinit();
            self.metrics.deinit();
        }

        pub fn log(self: Self, msg: []const u8) void {
            _ = self;
            _ = msg;
            // In production: write to log
        }

        pub fn setLevel(self: *Self, level: u8) void {
            self.log_level = level;
        }

        pub fn recordCount(self: *Self, key: []const u8, value: u64) void {
            self.metrics.put(key, value) catch {};
        }

        pub fn getCount(self: Self, key: []const u8) u64 {
            return self.metrics.get(key) orelse 0;
        }

        pub fn save(self: *Self, user: User) !u32 {
            self.log("Saving user to memory");
            self.recordCount("saves", self.getCount("saves") + 1);

            var new_user = user;
            new_user.id = self.next_id;
            try self.users.put(self.next_id, new_user);
            self.next_id += 1;
            return new_user.id;
        }

        pub fn load(self: *Self, id: u32) !?User {
            self.recordCount("loads", self.getCount("loads") + 1);
            return self.users.get(id);
        }
    };

    // Implementation 2: Cache repository (simpler, just tracks hits/misses)
    const CacheRepo = struct {
        cache: std.AutoHashMap(u32, User),
        hits: u64,
        misses: u64,
        log_enabled: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .cache = std.AutoHashMap(u32, User).init(allocator),
                .hits = 0,
                .misses = 0,
                .log_enabled = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
        }

        pub fn log(self: Self, msg: []const u8) void {
            if (self.log_enabled) {
                _ = msg;
                // In production: write to cache log
            }
        }

        pub fn setLevel(self: *Self, level: u8) void {
            self.log_enabled = level > 0;
        }

        pub fn recordCount(self: *Self, key: []const u8, value: u64) void {
            if (std.mem.eql(u8, key, "hits")) {
                self.hits = value;
            } else if (std.mem.eql(u8, key, "misses")) {
                self.misses = value;
            }
        }

        pub fn getCount(self: Self, key: []const u8) u64 {
            if (std.mem.eql(u8, key, "hits")) return self.hits;
            if (std.mem.eql(u8, key, "misses")) return self.misses;
            return 0;
        }

        pub fn save(self: *Self, user: User) !u32 {
            self.log("Caching user");
            try self.cache.put(user.id, user);
            return user.id;
        }

        pub fn load(self: *Self, id: u32) !?User {
            if (self.cache.get(id)) |user| {
                self.recordCount("hits", self.hits + 1);
                return user;
            } else {
                self.recordCount("misses", self.misses + 1);
                return null;
            }
        }
    };

    // Implementation 3: No-op repository for testing
    const NoOpRepo = struct {
        call_count: u64,

        pub fn init() @This() {
            return .{ .call_count = 0 };
        }

        pub fn log(_: @This(), _: []const u8) void {}
        pub fn setLevel(_: *@This(), _: u8) void {}
        pub fn recordCount(_: *@This(), _: []const u8, _: u64) void {}
        pub fn getCount(_: @This(), _: []const u8) u64 {
            return 0;
        }

        pub fn save(self: *@This(), _: User) !u32 {
            self.call_count += 1;
            return 999;
        }

        pub fn load(self: *@This(), _: u32) !?User {
            self.call_count += 1;
            return null;
        }
    };

    // Verify all implementations satisfy the interface
    comptime Repository.validation.satisfiedBy(InMemoryRepo);
    comptime Repository.validation.satisfiedBy(CacheRepo);
    comptime Repository.validation.satisfiedBy(NoOpRepo);

    // Create instances
    var in_memory = try InMemoryRepo.init(std.testing.allocator);
    defer in_memory.deinit();

    var cache = CacheRepo.init(std.testing.allocator);
    defer cache.deinit();

    var noop = NoOpRepo.init();

    // Convert to interface objects for runtime polymorphism
    const repo1 = Repository.from(&in_memory);
    const repo2 = Repository.from(&cache);
    const repo3 = Repository.from(&noop);

    // Store in heterogeneous collection
    const repositories = [_]Repository{ repo1, repo2, repo3 };

    // Use all repositories polymorphically
    const test_user = User{ .id = 0, .name = "Alice", .email = "alice@example.com" };

    for (repositories) |repo| {
        _ = try repo.vtable.save(repo.ptr, test_user);
        repo.vtable.log(repo.ptr, "Operation complete");
    }

    // Verify each implementation behaved correctly
    try std.testing.expectEqual(@as(u64, 1), in_memory.getCount("saves"));
    try std.testing.expectEqual(@as(u32, 1), noop.call_count);

    // Test loading through interface
    const loaded = try repo1.vtable.load(repo1.ptr, 1);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("Alice", loaded.?.name);
}

test "high-level: repository fallback chain with embedded interfaces" {
    // Demonstrate a practical pattern: fallback chain of repositories
    const Logger = Interface(.{
        .log = fn ([]const u8) void,
    }, null);

    const Repository = Interface(.{
        .get = fn ([]const u8) anyerror!?[]const u8,
        .put = fn ([]const u8, []const u8) anyerror!void,
    }, .{Logger});

    // L1 Cache - fast, limited capacity
    const L1Cache = struct {
        data: std.StringHashMap([]const u8),
        hits: usize,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .data = std.StringHashMap([]const u8).init(allocator),
                .hits = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.data.deinit();
        }

        pub fn log(_: @This(), msg: []const u8) void {
            _ = msg;
        }

        pub fn get(self: *@This(), key: []const u8) !?[]const u8 {
            if (self.data.get(key)) |value| {
                self.hits += 1;
                return value;
            }
            return null;
        }

        pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            try self.data.put(key, value);
        }
    };

    // L2 Cache - slower, larger capacity
    const L2Cache = struct {
        data: std.StringHashMap([]const u8),
        hits: usize,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .data = std.StringHashMap([]const u8).init(allocator),
                .hits = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.data.deinit();
        }

        pub fn log(_: @This(), msg: []const u8) void {
            _ = msg;
        }

        pub fn get(self: *@This(), key: []const u8) !?[]const u8 {
            if (self.data.get(key)) |value| {
                self.hits += 1;
                return value;
            }
            return null;
        }

        pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            try self.data.put(key, value);
        }
    };

    // Backing store
    const BackingStore = struct {
        data: std.StringHashMap([]const u8),
        reads: usize,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .data = std.StringHashMap([]const u8).init(allocator),
                .reads = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.data.deinit();
        }

        pub fn log(_: @This(), msg: []const u8) void {
            _ = msg;
        }

        pub fn get(self: *@This(), key: []const u8) !?[]const u8 {
            self.reads += 1;
            return self.data.get(key);
        }

        pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
            try self.data.put(key, value);
        }
    };

    comptime Repository.validation.satisfiedBy(L1Cache);
    comptime Repository.validation.satisfiedBy(L2Cache);
    comptime Repository.validation.satisfiedBy(BackingStore);

    // Set up the fallback chain
    var l1 = L1Cache.init(std.testing.allocator);
    defer l1.deinit();

    var l2 = L2Cache.init(std.testing.allocator);
    defer l2.deinit();

    var backing = BackingStore.init(std.testing.allocator);
    defer backing.deinit();

    // Pre-populate backing store
    try backing.put("key1", "value1");
    try backing.put("key2", "value2");

    // Create interface chain
    const chain = [_]Repository{
        Repository.from(&l1),
        Repository.from(&l2),
        Repository.from(&backing),
    };

    // Function to get value through fallback chain
    const getValue = struct {
        fn get(repos: []const Repository, key: []const u8) !?[]const u8 {
            for (repos) |repo| {
                if (try repo.vtable.get(repo.ptr, key)) |value| {
                    return value;
                }
            }
            return null;
        }
    }.get;

    // First access - should hit backing store
    const val1 = try getValue(&chain, "key1");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("value1", val1.?);
    try std.testing.expectEqual(@as(usize, 0), l1.hits);
    try std.testing.expectEqual(@as(usize, 0), l2.hits);
    try std.testing.expectEqual(@as(usize, 1), backing.reads);

    // Populate L2 cache
    try chain[1].vtable.put(chain[1].ptr, "key1", "value1");

    // Second access - should hit L2
    const val2 = try getValue(&chain, "key1");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqual(@as(usize, 1), l2.hits);

    // Populate L1 cache
    try chain[0].vtable.put(chain[0].ptr, "key1", "value1");

    // Third access - should hit L1
    const val3 = try getValue(&chain, "key1");
    try std.testing.expect(val3 != null);
    try std.testing.expectEqual(@as(usize, 1), l1.hits);

    // Still only 1 backing store read
    try std.testing.expectEqual(@as(usize, 1), backing.reads);
}

test "hasMethod finds primary interface methods" {
    const IWriter = Interface(.{
        .write = fn ([]const u8) anyerror!usize,
        .flush = fn () anyerror!void,
    }, null);

    const has_write = comptime IWriter.validation.hasMethod("write");
    const has_flush = comptime IWriter.validation.hasMethod("flush");
    const has_close = comptime IWriter.validation.hasMethod("close");

    try std.testing.expect(has_write);
    try std.testing.expect(has_flush);
    try std.testing.expect(!has_close);
}

test "detects ambiguity between primary and embedded method of same name" {
    const IBase = Interface(.{
        .process = fn ([]const u8) void,
    }, null);

    // Primary interface also defines 'process' with the SAME signature.
    // This should be flagged as ambiguous, just like two embedded interfaces
    // with the same method name are (see "interface embedding with conflicts" test).
    const IDerived = Interface(.{
        .process = fn ([]const u8) void,
    }, .{IBase});

    const Impl = struct {
        pub fn process(self: @This(), data: []const u8) void {
            _ = self;
            _ = data;
        }
    };

    const problems = comptime IDerived.validation.incompatibilities(Impl);
    // Since both signatures match the implementation, the ONLY way
    // to get problems.len > 0 is through ambiguity detection.
    try std.testing.expect(problems.len > 0);
}
