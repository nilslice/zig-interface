const std = @import("std");
const Interface = @import("interface").Interface;

test "complex type support" {
    const IComplexTypes = Interface(.{
        .complexMethod = fn (struct { a: []const u8, b: ?i32 }, enum { a, b, c }, []const struct { x: u32, y: ?[]const u8 }) anyerror!void,
    }, null);

    // Correct implementation
    const GoodImpl = struct {
        pub fn complexMethod(
            self: @This(),
            first: struct { a: []const u8, b: ?i32 },
            second: enum { a, b, c },
            third: []const struct { x: u32, y: ?[]const u8 },
        ) !void {
            _ = self;
            _ = first;
            _ = second;
            _ = third;
        }
    };

    // Should compile without error
    comptime IComplexTypes.validation.satisfiedBy(GoodImpl);

    // Bad implementation - mismatched struct field type
    const BadImpl1 = struct {
        pub fn complexMethod(
            self: @This(),
            first: struct { a: []u8, b: ?i32 }, // []u8 instead of []const u8
            second: enum { a, b, c },
            third: []const struct { x: u32, y: ?[]const u8 },
        ) !void {
            _ = self;
            _ = first;
            _ = second;
            _ = third;
        }
    };

    // Bad implementation - missing enum value
    const BadImpl2 = struct {
        pub fn complexMethod(
            self: @This(),
            first: struct { a: []const u8, b: ?i32 },
            second: enum { a, b }, // missing 'c'
            third: []const struct { x: u32, y: ?[]const u8 },
        ) !void {
            _ = self;
            _ = first;
            _ = second;
            _ = third;
        }
    };

    // Bad implementation - different struct field name
    const BadImpl3 = struct {
        pub fn complexMethod(
            self: @This(),
            first: struct { a: []const u8, b: ?i32 },
            second: enum { a, b, c },
            third: []const struct { x: u32, y_value: ?[]const u8 }, // y_value instead of y
        ) !void {
            _ = self;
            _ = first;
            _ = second;
            _ = third;
        }
    };

    try std.testing.expect(IComplexTypes.validation.incompatibilities(BadImpl1).len > 0);
    try std.testing.expect(IComplexTypes.validation.incompatibilities(BadImpl2).len > 0);
    try std.testing.expect(IComplexTypes.validation.incompatibilities(BadImpl3).len > 0);
}

test "complex type support with embedding" {
    // Define all complex types we'll use
    const Config = struct {
        a: []const u8,
        b: ?i32,
    };

    const Status = enum { a, b, c };

    const DataPoint = struct {
        x: u32,
        y: ?[]const u8,
    };

    const ProcessingMode = enum { ready, processing, unknown };

    const HistoryEntry = struct {
        timestamp: i64,
        data: ?[]const DataPoint,
        status: Status,
    };

    const ProcessingResult = struct {
        result: []const DataPoint,
        status: Status,
    };

    const ProcessingInput = struct {
        config: Config,
        points: []const DataPoint,
    };

    // Base interfaces with complex types
    const IConfigurable = Interface(.{
        .configure = fn (Config) anyerror!void,
        .getConfig = fn () Config,
    }, null);

    const IStatusProvider = Interface(.{
        .getStatus = fn () Status,
        .setStatus = fn (Status) anyerror!void,
    }, null);

    const IDataHandler = Interface(.{
        .processData = fn ([]const DataPoint) anyerror!void,
        .getLastPoint = fn () ?DataPoint,
    }, null);

    // Complex interface that embeds all the above and adds its own complex methods
    const IComplexTypes = Interface(.{
        .complexMethod = fn (Config, Status, []const DataPoint) anyerror!void,
        .superComplex = fn (ProcessingInput, ProcessingMode, []const HistoryEntry) anyerror!?ProcessingResult,
    }, .{ IConfigurable, IStatusProvider, IDataHandler });

    // Correct implementation
    const GoodImpl = struct {
        current_config: Config = .{ .a = "", .b = null },
        current_status: Status = .a,
        last_point: ?DataPoint = null,

        // Configurable implementation
        pub fn configure(self: *@This(), cfg: Config) !void {
            self.current_config = cfg;
        }

        pub fn getConfig(self: @This()) Config {
            return self.current_config;
        }

        // StatusProvider implementation
        pub fn getStatus(self: @This()) Status {
            return self.current_status;
        }

        pub fn setStatus(self: *@This(), status: Status) !void {
            self.current_status = status;
        }

        // DataHandler implementation
        pub fn processData(self: *@This(), points: []const DataPoint) !void {
            if (points.len > 0) {
                self.last_point = points[points.len - 1];
            }
        }

        pub fn getLastPoint(self: @This()) ?DataPoint {
            return self.last_point;
        }

        // ComplexTypes implementation
        pub fn complexMethod(
            self: *@This(),
            config: Config,
            status: Status,
            points: []const DataPoint,
        ) !void {
            try self.configure(config);
            try self.setStatus(status);
            try self.processData(points);
        }

        pub fn superComplex(
            self: *@This(),
            input: ProcessingInput,
            mode: ProcessingMode,
            history: []const HistoryEntry,
        ) !?ProcessingResult {
            _ = self;
            _ = input;
            _ = mode;
            _ = history;
            return null;
        }
    };

    // Should compile without error
    comptime IComplexTypes.validation.satisfiedBy(GoodImpl);
    comptime IConfigurable.validation.satisfiedBy(GoodImpl);
    comptime IStatusProvider.validation.satisfiedBy(GoodImpl);
    comptime IDataHandler.validation.satisfiedBy(GoodImpl);

    // Bad implementation - missing embedded interface methods
    const BadImpl1 = struct {
        pub fn complexMethod(
            self: *@This(),
            config: Config,
            status: Status,
            points: []const DataPoint,
        ) !void {
            _ = self;
            _ = config;
            _ = status;
            _ = points;
        }

        pub fn superComplex(
            self: *@This(),
            input: ProcessingInput,
            mode: ProcessingMode,
            history: []const HistoryEntry,
        ) !?ProcessingResult {
            _ = self;
            _ = input;
            _ = mode;
            _ = history;
            return null;
        }
    };

    // Bad implementation - wrong embedded interface method signature
    const BadImpl2 = struct {
        pub fn configure(self: *@This(), cfg: Config) !void {
            _ = self;
            _ = cfg;
        }

        pub fn getConfig(self: @This()) ?Config { // Wrong return type
            _ = self;
            return null;
        }

        pub fn getStatus(self: @This()) Status {
            _ = self;
            return .a;
        }

        pub fn setStatus(self: *@This(), status: Status) !void {
            _ = self;
            _ = status;
        }

        pub fn processData(self: *@This(), points: []DataPoint) !void { // Missing const
            _ = self;
            _ = points;
        }

        pub fn getLastPoint(self: @This()) ?DataPoint {
            _ = self;
            return null;
        }

        pub fn complexMethod(
            self: *@This(),
            config: Config,
            status: Status,
            points: []const DataPoint,
        ) !void {
            _ = self;
            _ = config;
            _ = status;
            _ = points;
        }

        pub fn superComplex(
            self: *@This(),
            input: ProcessingInput,
            mode: ProcessingMode,
            history: []const HistoryEntry,
        ) !?ProcessingResult {
            _ = self;
            _ = input;
            _ = mode;
            _ = history;
            return null;
        }
    };

    // Test that bad implementations are caught
    try std.testing.expect(IComplexTypes.validation.incompatibilities(BadImpl1).len > 0);
    try std.testing.expect(IComplexTypes.validation.incompatibilities(BadImpl2).len > 0);
}
