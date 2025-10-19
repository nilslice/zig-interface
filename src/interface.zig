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

            // Any error union in the interface accepts any error set in the implementation
            // We only care that the payload types match
            return exp_info.error_union.payload == act_info.error_union.payload;
        }

        pub fn incompatibilities(comptime ImplType: type) []const Incompatibility {
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
                    if (!@hasDecl(ImplType, field.name)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .missing_method = field.name,
                        }};
                        continue;
                    }

                    const impl_fn = @TypeOf(@field(ImplType, field.name));
                    const expected_fn = @field(methods, field.name);

                    const impl_info = @typeInfo(impl_fn).@"fn";
                    const expected_info = @typeInfo(expected_fn).@"fn";

                    // Implementation has self parameter, interface signature doesn't
                    // So impl should have expected.len + 1 params
                    const expected_param_count = expected_info.params.len + 1;

                    if (impl_info.params.len != expected_param_count) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .wrong_param_count = .{
                                .method = field.name,
                                .expected = expected_param_count,
                                .got = impl_info.params.len,
                            },
                        }};
                    } else {
                        // Compare impl params[1..] (skip self) with interface params[0..]
                        for (impl_info.params[1..], expected_info.params, 0..) |impl_param, expected_param, i| {
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
                        const embed_problems = embed.incompatibilities(ImplType);
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

        pub fn satisfiedBy(comptime ImplType: type) void {
            comptime {
                const problems = incompatibilities(ImplType);
                if (problems.len > 0) {
                    const title = "Type '{s}' does not implement interface '{s}':\n";

                    // First compute the total size needed for our error message
                    var total_len: usize = std.fmt.count(title, .{
                        @typeName(ImplType),
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
                        @typeName(ImplType),
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

        /// Generates a VTable-based runtime type that enables runtime polymorphism.
        /// Returns a type that can store any implementation of this interface with type erasure.
        ///
        /// The generated type has:
        /// - `ptr`: *anyopaque pointer to the implementation
        /// - `vtable`: *const VTable with function pointers
        /// - `init()`: creates wrapper from implementation pointer and vtable (for manual usage)
        /// - `from()`: auto-generates VTable wrappers and creates wrapper (recommended)
        ///
        /// Methods are called through the vtable: `interface.vtable.methodName(interface.ptr, args...)`
        ///
        /// Example:
        /// ```zig
        /// const IWriter = Writer.Type();
        ///
        /// const MyWriter = struct {
        ///     pub fn write(self: *MyWriter, data: []const u8) !usize {
        ///         // implementation
        ///     }
        /// };
        ///
        /// var writer = MyWriter{};
        /// const iwriter = IWriter.from(&writer);  // Auto-generated wrappers!
        /// ```
        pub fn Type() type {
            comptime {
                // Generate VTable type with function pointers
                const VTableType = generateVTableType();

                return struct {
                    ptr: *anyopaque,
                    vtable: *const VTableType,

                    pub const VTable = VTableType;

                    /// Creates an interface wrapper from an implementation pointer and vtable.
                    ///
                    /// The implementation type is validated at compile time to ensure it satisfies
                    /// the interface requirements.
                    ///
                    /// Params:
                    ///   impl: Pointer to the concrete implementation
                    ///   vtable: Pointer to the VTable with wrapper functions
                    pub fn init(impl: anytype, vtable: *const VTableType) @This() {
                        const ImplPtr = @TypeOf(impl);
                        const impl_type_info = @typeInfo(ImplPtr);

                        // Verify it's a pointer
                        if (impl_type_info != .pointer) {
                            @compileError("init() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
                        }

                        const ImplType = impl_type_info.pointer.child;

                        // Validate that the type satisfies the interface at compile time
                        comptime Self.satisfiedBy(ImplType);

                        return .{
                            .ptr = impl,
                            .vtable = vtable,
                        };
                    }

                    /// Automatically generates VTable wrappers and creates an interface wrapper.
                    /// This eliminates the need to manually write *Impl wrapper functions.
                    ///
                    /// The wrappers are generated at compile time and cached per implementation type,
                    /// so there's no runtime overhead compared to manual wrappers.
                    ///
                    /// Params:
                    ///   impl: Pointer to the implementation instance
                    ///
                    /// Example:
                    /// ```zig
                    /// var pause_state = PauseState{};
                    /// const state = IState.from(&pause_state);
                    /// state.vtable.update(state.ptr, 0.16);
                    /// ```
                    pub fn from(impl: anytype) @This() {
                        const ImplPtr = @TypeOf(impl);
                        const impl_type_info = @typeInfo(ImplPtr);

                        // Verify it's a pointer
                        if (impl_type_info != .pointer) {
                            @compileError("from() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
                        }

                        const ImplType = impl_type_info.pointer.child;

                        // Validate that the type satisfies the interface at compile time
                        comptime Self.satisfiedBy(ImplType);

                        // Generate a unique wrapper struct with static VTable for this ImplType
                        // The compiler memoizes this, so each ImplType gets exactly one instance
                        const gen = struct {
                            fn generateWrapperForField(comptime T: type, comptime vtable_field: std.builtin.Type.StructField) *const anyopaque {
                                // Extract function signature from vtable field
                                const fn_ptr_info = @typeInfo(vtable_field.type);
                                const fn_info = @typeInfo(fn_ptr_info.pointer.child).@"fn";
                                const method_name = vtable_field.name;

                                // Check if the implementation method expects *T or T
                                const impl_method_info = @typeInfo(@TypeOf(@field(T, method_name)));
                                const impl_fn_info = impl_method_info.@"fn";
                                const first_param_info = @typeInfo(impl_fn_info.params[0].type.?);
                                const expects_pointer = first_param_info == .pointer;

                                // Generate wrapper matching the exact signature
                                const param_count = fn_info.params.len;
                                if (param_count < 1 or param_count > 5) {
                                    @compileError("Method '" ++ method_name ++ "' has " ++ @typeName(@TypeOf(param_count)) ++ " parameters. Only 1-5 parameters (including self pointer) are supported.");
                                }

                                // Create wrapper with exact parameter types from VTable signature
                                if (expects_pointer) {
                                    return switch (param_count) {
                                        1 => &struct {
                                            fn wrapper(ptr: *anyopaque) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self);
                                            }
                                        }.wrapper,
                                        2 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self, p1);
                                            }
                                        }.wrapper,
                                        3 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self, p1, p2);
                                            }
                                        }.wrapper,
                                        4 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self, p1, p2, p3);
                                            }
                                        }.wrapper,
                                        5 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?, p4: fn_info.params[4].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self, p1, p2, p3, p4);
                                            }
                                        }.wrapper,
                                        else => unreachable,
                                    };
                                } else {
                                    return switch (param_count) {
                                        1 => &struct {
                                            fn wrapper(ptr: *anyopaque) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self.*);
                                            }
                                        }.wrapper,
                                        2 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self.*, p1);
                                            }
                                        }.wrapper,
                                        3 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self.*, p1, p2);
                                            }
                                        }.wrapper,
                                        4 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self.*, p1, p2, p3);
                                            }
                                        }.wrapper,
                                        5 => &struct {
                                            fn wrapper(ptr: *anyopaque, p1: fn_info.params[1].type.?, p2: fn_info.params[2].type.?, p3: fn_info.params[3].type.?, p4: fn_info.params[4].type.?) callconv(fn_info.calling_convention) fn_info.return_type.? {
                                                const self: *T = @ptrCast(@alignCast(ptr));
                                                return @field(T, method_name)(self.*, p1, p2, p3, p4);
                                            }
                                        }.wrapper,
                                        else => unreachable,
                                    };
                                }
                            }

                            const vtable: VTableType = blk: {
                                var result: VTableType = undefined;
                                // Iterate over all VTable fields (includes embedded interface methods)
                                for (std.meta.fields(VTableType)) |vtable_field| {
                                    const wrapper_ptr = generateWrapperForField(ImplType, vtable_field);
                                    @field(result, vtable_field.name) = @ptrCast(@alignCast(wrapper_ptr));
                                }
                                break :blk result;
                            };
                        };

                        return .{
                            .ptr = impl,
                            .vtable = &gen.vtable,
                        };
                    }
                };
            }
        }

        fn generateVTableType() type {
            comptime {
                // Build array of struct fields for the VTable
                var fields: []const std.builtin.Type.StructField = &.{};

                // Helper function to add a method to the VTable
                const addMethod = struct {
                    fn add(method_field: std.builtin.Type.StructField, method_fn: anytype, field_list: []const std.builtin.Type.StructField) []const std.builtin.Type.StructField {
                        const fn_info = @typeInfo(method_fn).@"fn";

                        // Build parameter list: insert *anyopaque as first param (implicit self)
                        // Interface methods don't include self in their signature
                        var params: [fn_info.params.len + 1]std.builtin.Type.Fn.Param = undefined;
                        params[0] = .{
                            .is_generic = false,
                            .is_noalias = false,
                            .type = *anyopaque,
                        };

                        // Copy all interface parameters after the implicit self
                        for (fn_info.params, 1..) |param, i| {
                            params[i] = param;
                        }

                        // Create function pointer type
                        const FnType = @Type(.{
                            .@"fn" = .{
                                .calling_convention = fn_info.calling_convention,
                                .is_generic = false,
                                .is_var_args = false,
                                .return_type = fn_info.return_type,
                                .params = &params,
                            },
                        });

                        const FnPtrType = *const FnType;

                        // Add field to VTable
                        return field_list ++ &[_]std.builtin.Type.StructField{.{
                            .name = method_field.name,
                            .type = FnPtrType,
                            .default_value_ptr = null,
                            .is_comptime = false,
                            .alignment = @alignOf(FnPtrType),
                        }};
                    }
                }.add;

                // Add methods from embedded interfaces first
                if (has_embeds) {
                    for (std.meta.fields(Embeds)) |embed_field| {
                        const embed = @field(embedded_interfaces, embed_field.name);
                        // Recursively get the VTable type from the embedded interface
                        const EmbedVTable = embed.Type().VTable;
                        for (std.meta.fields(EmbedVTable)) |vtable_field| {
                            // Get the method signature from the embedded interface's methods
                            // We need to reconstruct the method from the vtable field
                            fields = fields ++ &[_]std.builtin.Type.StructField{vtable_field};
                        }
                    }
                }

                // Add methods from primary interface
                for (std.meta.fields(Methods)) |method_field| {
                    const method_fn = @field(methods, method_field.name);
                    fields = addMethod(method_field, method_fn, fields);
                }

                // Create the VTable struct type
                return @Type(.{
                    .@"struct" = .{
                        .layout = .auto,
                        .fields = fields,
                        .decls = &.{},
                        .is_tuple = false,
                    },
                });
            }
        }
    };
}

test "expected usage of embedded interfaces" {
    const Logger = Interface(.{
        .log = fn ([]const u8) void,
    }, .{});

    const Writer = Interface(.{
        .write = fn ([]const u8) anyerror!void,
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
        .log = fn ([]const u8, u8) void,
        .missing = fn () void,
    }, .{});

    const Writer = Interface(.{
        .write = fn ([]const u8) anyerror!void,
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

test "vtable interface type generation" {
    const IWriter = Interface(.{
        .write = fn ([]const u8) anyerror!usize,
    }, null);

    const Writer = IWriter.Type();

    // Verify the VTable type was generated correctly
    const VTableType = Writer.VTable;
    const vtable_fields = std.meta.fields(VTableType);

    try std.testing.expectEqual(@as(usize, 1), vtable_fields.len);
    try std.testing.expectEqualStrings("write", vtable_fields[0].name);
}

test "vtable interface runtime usage" {
    const IWriter = Interface(.{
        .write = fn ([]const u8) anyerror!usize,
    }, null);

    const Writer = IWriter.Type();

    const BufferWriter = struct {
        buffer: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .buffer = std.ArrayList(u8){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.buffer.deinit(self.allocator);
        }

        pub fn write(self: *@This(), data: []const u8) !usize {
            try self.buffer.appendSlice(self.allocator, data);
            return data.len;
        }

        pub fn getWritten(self: *const @This()) []const u8 {
            return self.buffer.items;
        }
    };

    var buffer_writer = BufferWriter.init(std.testing.allocator);
    defer buffer_writer.deinit();

    // Create interface wrapper with auto-generated VTable
    const writer_interface = Writer.from(&buffer_writer);

    // Use through the interface
    const written = try writer_interface.vtable.write(writer_interface.ptr, "Hello, ");
    try std.testing.expectEqual(@as(usize, 7), written);

    const written2 = try writer_interface.vtable.write(writer_interface.ptr, "World!");
    try std.testing.expectEqual(@as(usize, 6), written2);

    // Verify the data was written
    try std.testing.expectEqualStrings("Hello, World!", buffer_writer.getWritten());
}

test "state machine with heterogeneous state storage" {
    // Define State interface
    const IState = Interface(.{
        .onEnter = fn () void,
        .onExit = fn () void,
        .update = fn (f32) void,
    }, null);

    // Generate VTable-based runtime type
    const State = IState.Type();

    // Menu state implementation
    const MenuState = struct {
        entered: bool = false,
        exited: bool = false,
        updates: u32 = 0,

        pub fn onEnter(self: *@This()) void {
            self.entered = true;
        }

        pub fn onExit(self: *@This()) void {
            self.exited = true;
        }

        pub fn update(self: *@This(), delta: f32) void {
            _ = delta;
            self.updates += 1;
        }
    };

    // Gameplay state implementation
    const GameplayState = struct {
        score: u32 = 0,

        pub fn onEnter(self: *@This()) void {
            self.score = 0;
        }

        pub fn onExit(self: *@This()) void {
            _ = self;
        }

        pub fn update(self: *@This(), delta: f32) void {
            _ = delta;
            self.score += 10;
        }
    };

    // State manager with stack of interface objects
    const StateManager = struct {
        stack: std.ArrayList(State),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .stack = std.ArrayList(State){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.stack.deinit(self.allocator);
        }

        pub fn pushState(self: *@This(), state: State) !void {
            try self.stack.append(self.allocator, state);
            // Call onEnter on the new state
            const current = &self.stack.items[self.stack.items.len - 1];
            current.vtable.onEnter(current.ptr);
        }

        pub fn popState(self: *@This()) void {
            if (self.stack.items.len > 0) {
                const current = &self.stack.items[self.stack.items.len - 1];
                current.vtable.onExit(current.ptr);
                _ = self.stack.pop();
            }
        }

        pub fn update(self: *@This(), delta: f32) void {
            if (self.stack.items.len > 0) {
                const current = &self.stack.items[self.stack.items.len - 1];
                current.vtable.update(current.ptr, delta);
            }
        }
    };

    // Test the state machine
    var menu = MenuState{};
    var gameplay = GameplayState{};

    var manager = StateManager.init(std.testing.allocator);
    defer manager.deinit();

    // Push menu state - auto-generated VTable wrappers!
    try manager.pushState(State.from(&menu));
    try std.testing.expect(menu.entered);
    try std.testing.expectEqual(@as(u32, 0), menu.updates);

    // Update menu state
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 1), menu.updates);

    // Push gameplay state - auto-generated VTable wrappers!
    try manager.pushState(State.from(&gameplay));
    try std.testing.expectEqual(@as(u32, 0), gameplay.score);

    // Update gameplay state
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 10), gameplay.score);

    // Pop back to menu
    manager.popState();
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 2), menu.updates);
}

test "error union compatibility" {
    // Interface with anyerror union
    const Fallible = Interface(.{
        .doWork = fn (u32) anyerror!void,
    }, null);

    // Implementation with specific error set
    const SpecificErrorImpl = struct {
        pub fn doWork(self: @This(), value: u32) error{ OutOfMemory, InvalidInput }!void {
            _ = self;
            if (value == 0) return error.InvalidInput;
        }
    };

    // Implementation with different specific error set
    const DifferentErrorImpl = struct {
        pub fn doWork(self: @This(), value: u32) error{ FileNotFound, AccessDenied }!void {
            _ = self;
            if (value == 0) return error.FileNotFound;
        }
    };

    // Implementation with anyerror
    const AnyErrorImpl = struct {
        pub fn doWork(self: @This(), value: u32) anyerror!void {
            _ = self;
            if (value == 0) return error.SomeError;
        }
    };

    // All should be compatible - interface only cares about error union, not specific errors
    comptime Fallible.satisfiedBy(SpecificErrorImpl);
    comptime Fallible.satisfiedBy(DifferentErrorImpl);
    comptime Fallible.satisfiedBy(AnyErrorImpl);

    try std.testing.expect(Fallible.incompatibilities(SpecificErrorImpl).len == 0);
    try std.testing.expect(Fallible.incompatibilities(DifferentErrorImpl).len == 0);
    try std.testing.expect(Fallible.incompatibilities(AnyErrorImpl).len == 0);
}
