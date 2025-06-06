const std = @import("std");

/// Compares two types structurally to determine if they're compatible
fn isTypeCompatible(comptime T1: type, comptime T2: type) bool {
    const info1 = @typeInfo(T1);
    const info2 = @typeInfo(T2);

    // If types are identical, they're compatible
    if (T1 == T2) return true;

    // If type categories don't match, they're not compatible
    if (@intFromEnum(info1) != @intFromEnum(info2)) return false;

    return switch (info1) {
        .@"struct" => |s1| blk: {
            const s2 = @typeInfo(T2).@"struct";
            if (s1.fields.len != s2.fields.len) break :blk false;
            if (s1.is_tuple != s2.is_tuple) break :blk false;

            for (s1.fields, s2.fields) |f1, f2| {
                if (!std.mem.eql(u8, f1.name, f2.name)) break :blk false;
                if (!isTypeCompatible(f1.type, f2.type)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => |e1| blk: {
            const e2 = @typeInfo(T2).@"enum";
            if (e1.fields.len != e2.fields.len) break :blk false;

            for (e1.fields, e2.fields) |f1, f2| {
                if (!std.mem.eql(u8, f1.name, f2.name)) break :blk false;
                if (f1.value != f2.value) break :blk false;
            }
            break :blk true;
        },
        .array => |a1| blk: {
            const a2 = @typeInfo(T2).array;
            if (a1.len != a2.len) break :blk false;
            break :blk isTypeCompatible(a1.child, a2.child);
        },
        .pointer => |p1| blk: {
            const p2 = @typeInfo(T2).pointer;
            if (p1.size != p2.size) break :blk false;
            if (p1.is_const != p2.is_const) break :blk false;
            if (p1.is_volatile != p2.is_volatile) break :blk false;
            break :blk isTypeCompatible(p1.child, p2.child);
        },
        .optional => |o1| blk: {
            const o2 = @typeInfo(T2).optional;
            break :blk isTypeCompatible(o1.child, o2.child);
        },
        else => T1 == T2,
    };
}

/// Generates helpful hints for type mismatches
fn generateTypeHint(comptime expected: type, comptime got: type) ?[]const u8 {
    const exp_info = @typeInfo(expected);
    const got_info = @typeInfo(got);

    // Check for common slice constness issues
    if (exp_info == .Pointer and got_info == .Pointer) {
        const exp_ptr = exp_info.Pointer;
        const got_ptr = got_info.Pointer;
        if (exp_ptr.is_const and !got_ptr.is_const) {
            return "Consider making the parameter type const (e.g., []const u8 instead of []u8)";
        }
    }

    // Check for optional vs non-optional mismatches
    if (exp_info == .Optional and got_info != .Optional) {
        return "The expected type is optional. Consider wrapping the parameter in '?'";
    }
    if (exp_info != .Optional and got_info == .Optional) {
        return "The expected type is non-optional. Remove the '?' from the parameter type";
    }

    // Check for enum type mismatches
    if (exp_info == .Enum and got_info == .Enum) {
        return "Check that the enum values and field names match exactly";
    }

    // Check for struct field mismatches
    if (exp_info == .Struct and got_info == .Struct) {
        const exp_s = exp_info.Struct;
        const got_s = got_info.Struct;
        if (exp_s.fields.len != got_s.fields.len) {
            return "The structs have different numbers of fields";
        }
        // Could add more specific field comparison hints here
        return "Check that all struct field names and types match exactly";
    }

    // Generic catch-all for pointer size mismatches
    if (exp_info == .Pointer and got_info == .Pointer) {
        const exp_ptr = exp_info.Pointer;
        const got_ptr = got_info.Pointer;
        if (exp_ptr.size != got_ptr.size) {
            return "Check pointer type (single item vs slice vs many-item)";
        }
    }

    return null;
}

/// Formats type mismatch errors with helpful hints
fn formatTypeMismatch(
    comptime expected: type,
    comptime got: type,
    indent: []const u8,
) []const u8 {
    var result = std.fmt.comptimePrint(
        "{s}Expected: {s}\n{s}Got: {s}",
        .{
            indent,
            @typeName(expected),
            indent,
            @typeName(got),
        },
    );

    // Add hint if available
    if (generateTypeHint(expected, got)) |hint| {
        result = result ++ std.fmt.comptimePrint("\n   {s}Hint: {s}", .{ indent, hint });
    }

    return result;
}

/// Creates a verifiable interface type that can be used to define method requirements
/// for other types. Interfaces can embed other interfaces, combining their requirements.
///
/// The interface consists of method signatures that implementing types must match exactly.
/// Method signatures must use `anytype` for the self parameter to allow any implementing type.
///
/// Supports:
/// - Complex types (structs, enums, arrays, slices)
/// - Error unions with specific or `anyerror`
/// - Optional types and comptime checking
/// - Interface embedding (combining multiple interfaces)
/// - Detailed error reporting for mismatched implementations
///
/// Params:
///   methods: A struct of function signatures that define the interface
///   embedded: A tuple of other interfaces to embed, or null for no embedding
///
/// Example:
/// ```
/// const Writer = Interface(.{
///     .writeAll = fn(anytype, []const u8) anyerror!void,
/// }, null);
///
/// const Logger = Interface(.{
///     .log = fn(anytype, []const u8) void,
/// }, .{ Writer });  // Embeds Writer interface
///
/// // Usage in functions:
/// fn write(w: anytype, data: []const u8) !void {
///     comptime Writer.satisfiedBy(@TypeOf(w));
///     try w.writeAll(data);
/// }
/// ```
///
/// Common incompatibilities reported:
/// - Missing required methods
/// - Wrong parameter counts or types
/// - Incorrect return types
/// - Method name conflicts in embedded interfaces
/// - Non-const slices where const is required
///
pub fn Interface(comptime methods: anytype, comptime embedded: anytype) type {
    const embedded_interfaces = switch (@typeInfo(@TypeOf(embedded))) {
        .null => embedded,
        .@"struct" => |s| if (s.is_tuple) embedded else .{embedded},
        else => .{embedded},
    };

    // Handle the case where null is passed for embedded_interfaces
    const has_embeds = @TypeOf(embedded_interfaces) != @TypeOf(null);

    return struct {
        const Self = @This();
        const name = @typeName(Self);

        // Store these at the type level so they're accessible to helper functions
        const Methods = @TypeOf(methods);
        const Embeds = @TypeOf(embedded_interfaces);

        /// Represents all possible interface implementation problems
        const Incompatibility = union(enum) {
            missing_method: []const u8,
            wrong_param_count: struct {
                method: []const u8,
                expected: usize,
                got: usize,
            },
            param_type_mismatch: struct {
                method: []const u8,
                param_index: usize,
                expected: type,
                got: type,
            },
            return_type_mismatch: struct {
                method: []const u8,
                expected: type,
                got: type,
            },
            ambiguous_method: struct {
                method: []const u8,
                interfaces: []const []const u8,
            },
        };

        /// Collects all method names from this interface and its embedded interfaces
        fn collectMethodNames() []const []const u8 {
            comptime {
                var method_count: usize = 0;

                // Count methods from primary interface
                for (std.meta.fields(Methods)) |_| {
                    method_count += 1;
                }

                // Count methods from embedded interfaces
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        method_count += embed.collectMethodNames().len;
                    }
                }

                // Now create array of correct size
                var names: [method_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary interface methods
                for (std.meta.fields(Methods)) |field| {
                    names[index] = field.name;
                    index += 1;
                }

                // Add embedded interface methods
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        const embed_methods = embed.collectMethodNames();
                        @memcpy(names[index..][0..embed_methods.len], embed_methods);
                        index += embed_methods.len;
                    }
                }

                return &names;
            }
        }

        /// Checks if a method exists in multiple interfaces and returns the list of interfaces if so
        fn findMethodConflicts(comptime method_name: []const u8) ?[]const []const u8 {
            comptime {
                var interface_count: usize = 0;

                // Count primary interface
                if (@hasDecl(Methods, method_name)) {
                    interface_count += 1;
                }

                // Count embedded interfaces
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        if (embed.hasMethod(method_name)) {
                            interface_count += 1;
                        }
                    }
                }

                if (interface_count <= 1) return null;

                var interfaces: [interface_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary interface
                if (@hasDecl(Methods, method_name)) {
                    interfaces[index] = name;
                    index += 1;
                }

                // Add embedded interfaces
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        if (embed.hasMethod(method_name)) {
                            interfaces[index] = @typeName(@TypeOf(embed));
                            index += 1;
                        }
                    }
                }

                return &interfaces;
            }
        }

        /// Checks if this interface has a specific method
        fn hasMethod(comptime method_name: []const u8) bool {
            comptime {
                // Check primary interface
                if (@hasDecl(Methods, method_name)) {
                    return true;
                }

                // Check embedded interfaces
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        if (embed.hasMethod(method_name)) {
                            return true;
                        }
                    }
                }

                return false;
            }
        }

        fn isCompatibleErrorSet(comptime Expected: type, comptime Actual: type) bool {
            const exp_info = @typeInfo(Expected);
            const act_info = @typeInfo(Actual);

            if (exp_info != .error_union or act_info != .error_union) {
                return Expected == Actual;
            }

            if (exp_info.error_union.error_set == anyerror) {
                return exp_info.error_union.payload == act_info.error_union.payload;
            }
            return Expected == Actual;
        }

        pub fn incompatibilities(comptime Type: type) []const Incompatibility {
            comptime {
                var problems: []const Incompatibility = &.{};

                // First check for method ambiguity across all interfaces
                for (Self.collectMethodNames()) |method_name| {
                    if (Self.findMethodConflicts(method_name)) |conflicting_interfaces| {
                        problems = problems ++ &[_]Incompatibility{.{
                            .ambiguous_method = .{
                                .method = method_name,
                                .interfaces = conflicting_interfaces,
                            },
                        }};
                    }
                }

                // If we have ambiguous methods, return early
                if (problems.len > 0) return problems;

                // Check primary interface methods
                for (std.meta.fields(@TypeOf(methods))) |field| {
                    if (!@hasDecl(Type, field.name)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .missing_method = field.name,
                        }};
                        continue;
                    }

                    const impl_fn = @TypeOf(@field(Type, field.name));
                    const expected_fn = @field(methods, field.name);

                    const impl_info = @typeInfo(impl_fn).@"fn";
                    const expected_info = @typeInfo(expected_fn).@"fn";

                    if (impl_info.params.len != expected_info.params.len) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .wrong_param_count = .{
                                .method = field.name,
                                .expected = expected_info.params.len,
                                .got = impl_info.params.len,
                            },
                        }};
                    } else {
                        for (impl_info.params[1..], expected_info.params[1..], 0..) |impl_param, expected_param, i| {
                            if (!isTypeCompatible(impl_param.type.?, expected_param.type.?)) {
                                problems = problems ++ &[_]Incompatibility{.{
                                    .param_type_mismatch = .{
                                        .method = field.name,
                                        .param_index = i + 1,
                                        .expected = expected_param.type.?,
                                        .got = impl_param.type.?,
                                    },
                                }};
                            }
                        }
                    }

                    if (!isCompatibleErrorSet(expected_info.return_type.?, impl_info.return_type.?)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .return_type_mismatch = .{
                                .method = field.name,
                                .expected = expected_info.return_type.?,
                                .got = impl_info.return_type.?,
                            },
                        }};
                    }
                }

                // Check embedded interfaces
                if (has_embeds) {
                    for (std.meta.fields(@TypeOf(embedded_interfaces))) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        const embed_problems = embed.incompatibilities(Type);
                        problems = problems ++ embed_problems;
                    }
                }

                return problems;
            }
        }

        fn formatIncompatibility(incompatibility: Incompatibility) []const u8 {
            const indent = "   └─ ";
            return switch (incompatibility) {
                .missing_method => |method| std.fmt.comptimePrint("Missing required method: {s}\n{s}Add the method with the correct signature to your implementation", .{ method, indent }),

                .wrong_param_count => |info| std.fmt.comptimePrint("Method '{s}' has incorrect number of parameters:\n" ++
                    "{s}Expected {d} parameters\n" ++
                    "{s}Got {d} parameters\n" ++
                    "   {s}Hint: Remember that the first parameter should be the self/receiver type", .{
                    info.method,
                    indent,
                    info.expected,
                    indent,
                    info.got,
                    indent,
                }),

                .param_type_mismatch => |info| std.fmt.comptimePrint("Method '{s}' parameter {d} has incorrect type:\n{s}", .{
                    info.method,
                    info.param_index,
                    formatTypeMismatch(info.expected, info.got, indent),
                }),

                .return_type_mismatch => |info| std.fmt.comptimePrint("Method '{s}' return type is incorrect:\n{s}", .{
                    info.method,
                    formatTypeMismatch(info.expected, info.got, indent),
                }),

                .ambiguous_method => |info| std.fmt.comptimePrint("Method '{s}' is ambiguous - it appears in multiple interfaces: {s}\n" ++
                    "   {s}Hint: This method needs to be uniquely implemented or the ambiguity resolved", .{
                    info.method,
                    info.interfaces,
                    indent,
                }),
            };
        }

        pub fn satisfiedBy(comptime Type: type) void {
            comptime {
                const problems = incompatibilities(Type);
                if (problems.len > 0) {
                    const title = "Type '{s}' does not implement interface '{s}':\n";

                    // First compute the total size needed for our error message
                    var total_len: usize = std.fmt.count(title, .{
                        @typeName(Type),
                        name,
                    });

                    // Add space for each problem's length
                    for (1.., problems) |i, problem| {
                        total_len += std.fmt.count("{d}. {s}\n", .{ i, formatIncompatibility(problem) });
                    }

                    // Now create a fixed-size array of the exact size we need
                    var errors: [total_len]u8 = undefined;
                    var written: usize = 0;

                    written += (std.fmt.bufPrint(errors[written..], title, .{
                        @typeName(Type),
                        name,
                    }) catch unreachable).len;

                    // Write each problem
                    for (1.., problems) |i, problem| {
                        written += (std.fmt.bufPrint(errors[written..], "{d}. {s}\n", .{ i, formatIncompatibility(problem) }) catch unreachable).len;
                    }

                    @compileError(errors[0..written]);
                }
            }
        }
    };
}

test "expected usage of embedded interfaces" {
    const Logger = Interface(.{
        .log = fn (anytype, []const u8) void,
    }, .{});

    const Writer = Interface(.{
        .write = fn (anytype, []const u8) anyerror!void,
    }, .{Logger});

    const Implementation = struct {
        pub fn write(self: @This(), data: []const u8) !void {
            _ = self;
            _ = data;
        }

        pub fn log(self: @This(), msg: []const u8) void {
            _ = self;
            _ = msg;
        }
    };

    comptime Writer.satisfiedBy(Implementation);

    try std.testing.expect(Writer.incompatibilities(Implementation).len == 0);
}

test "expected failure case of embedded interfaces" {
    const Logger = Interface(.{
        .log = fn (anytype, []const u8, u8) void,
        .missing = fn (anytype) void,
    }, .{});

    const Writer = Interface(.{
        .write = fn (anytype, []const u8) anyerror!void,
    }, .{Logger});

    const Implementation = struct {
        pub fn write(self: @This(), data: []const u8) !void {
            _ = self;
            _ = data;
        }

        pub fn log(self: @This(), msg: []const u8) void {
            _ = self;
            _ = msg;
        }
    };

    try std.testing.expect(Writer.incompatibilities(Implementation).len == 2);
}
