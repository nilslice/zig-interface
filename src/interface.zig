const std = @import("std");
const builtin = @import("builtin");

pub fn Interface(comptime methods: anytype, comptime embedded: anytype) type {
    const embedded_interfaces = switch (@typeInfo(@TypeOf(embedded))) {
        .null => embedded,
        .@"struct" => |s| if (s.is_tuple) embedded else .{embedded},
        else => .{embedded},
    };

    const has_embeds = @TypeOf(embedded_interfaces) != @TypeOf(null);

    // Generate VTable type with function pointers
    const VTableType = generateVTableType(methods, embedded_interfaces, has_embeds);

    // Create the validation namespace
    const ValidationNamespace = CreateValidationNamespace(methods, embedded_interfaces, has_embeds);

    // Return the VTable-based interface type directly
    return struct {
        ptr: *anyopaque,
        vtable: *const VTableType,

        pub const VTable = VTableType;
        pub const validation = ValidationNamespace;

        /// Creates an interface wrapper from an implementation pointer and vtable.
        pub fn init(impl: anytype, vtable_ptr: *const VTableType) @This() {
            const ImplPtr = @TypeOf(impl);
            const impl_type_info = @typeInfo(ImplPtr);

            // Verify it's a pointer
            if (impl_type_info != .pointer) {
                @compileError("init() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
            }

            const ImplType = impl_type_info.pointer.child;

            // Validate that the type satisfies the interface at compile time
            comptime validation.satisfiedBy(ImplType);

            return .{
                .ptr = impl,
                .vtable = vtable_ptr,
            };
        }

        /// Automatically generates VTable wrappers and creates an interface wrapper.
        pub fn from(impl: anytype) @This() {
            const ImplPtr = @TypeOf(impl);
            const impl_type_info = @typeInfo(ImplPtr);

            // Verify it's a pointer
            if (impl_type_info != .pointer) {
                @compileError("from() requires a pointer to an implementation, got: " ++ @typeName(ImplPtr));
            }

            const ImplType = impl_type_info.pointer.child;

            // Validate that the type satisfies the interface at compile time
            comptime validation.satisfiedBy(ImplType);

            // Generate a unique wrapper struct with static VTable for this ImplType
            const gen = struct {
                fn generateWrapperForField(comptime T: type, comptime method_name: [:0]const u8, comptime fn_ptr_type: type) *const anyopaque {
                    // Extract function signature from vtable field
                    const fn_ptr_info = @typeInfo(fn_ptr_type);
                    const fn_info = @typeInfo(fn_ptr_info.pointer.child).@"fn";
                    const param_types = fn_info.param_types;
                    const cc = fn_info.attrs.@"callconv";
                    const Ret = fn_info.return_type.?;

                    // Check if the implementation method expects *T or T
                    const impl_method_info = @typeInfo(@TypeOf(@field(T, method_name)));
                    const impl_fn_info = impl_method_info.@"fn";
                    const first_param_info = @typeInfo(impl_fn_info.param_types[0].?);
                    const expects_pointer = first_param_info == .pointer;

                    // Generate wrapper matching the exact signature
                    const param_count = param_types.len;
                    if (param_count < 1 or param_count > 5) {
                        @compileError("Method '" ++ method_name ++ "' has too many parameters. Only 1-5 parameters (including self pointer) are supported.");
                    }

                    // Create wrapper with exact parameter types from VTable signature
                    if (expects_pointer) {
                        return switch (param_count) {
                            1 => &struct {
                                fn wrapper(ptr: *anyopaque) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self);
                                }
                            }.wrapper,
                            2 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1);
                                }
                            }.wrapper,
                            3 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1, p2);
                                }
                            }.wrapper,
                            4 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?, p3: param_types[3].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1, p2, p3);
                                }
                            }.wrapper,
                            5 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?, p3: param_types[3].?, p4: param_types[4].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self, p1, p2, p3, p4);
                                }
                            }.wrapper,
                            else => unreachable,
                        };
                    } else {
                        return switch (param_count) {
                            1 => &struct {
                                fn wrapper(ptr: *anyopaque) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*);
                                }
                            }.wrapper,
                            2 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1);
                                }
                            }.wrapper,
                            3 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1, p2);
                                }
                            }.wrapper,
                            4 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?, p3: param_types[3].?) callconv(cc) Ret {
                                    const self: *T = @ptrCast(@alignCast(ptr));
                                    return @field(T, method_name)(self.*, p1, p2, p3);
                                }
                            }.wrapper,
                            5 => &struct {
                                fn wrapper(ptr: *anyopaque, p1: param_types[1].?, p2: param_types[2].?, p3: param_types[3].?, p4: param_types[4].?) callconv(cc) Ret {
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
                    const vtable_info = @typeInfo(VTableType).@"struct";
                    for (vtable_info.field_names, vtable_info.field_types) |field_name, field_type| {
                        const wrapper_ptr = generateWrapperForField(ImplType, field_name, field_type);
                        @field(result, field_name) = @ptrCast(@alignCast(wrapper_ptr));
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

/// Compares two types structurally to determine if they're compatible
fn isTypeCompatible(comptime T1: type, comptime T2: type) bool {
    const info1 = @typeInfo(T1);
    const info2 = @typeInfo(T2);

    // If types are identical, they're compatible
    if (T1 == T2) return true;

    // If type categories don't match, they're not compatible
    if (@backingInt(info1) != @backingInt(info2)) return false;

    return switch (info1) {
        .@"struct" => |s1| blk: {
            const s2 = @typeInfo(T2).@"struct";
            if (s1.field_names.len != s2.field_names.len) break :blk false;
            if (s1.is_tuple != s2.is_tuple) break :blk false;

            for (s1.field_names, s1.field_types, s2.field_names, s2.field_types) |n1, t1, n2, t2| {
                if (!std.mem.eql(u8, n1, n2)) break :blk false;
                if (!isTypeCompatible(t1, t2)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => |e1| blk: {
            const e2 = @typeInfo(T2).@"enum";
            if (e1.field_names.len != e2.field_names.len) break :blk false;

            for (e1.field_names, e1.field_values, e2.field_names, e2.field_values) |n1, v1, n2, v2| {
                if (!std.mem.eql(u8, n1, n2)) break :blk false;
                if (v1 != v2) break :blk false;
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
            if (p1.attrs.@"const" != p2.attrs.@"const") break :blk false;
            if (p1.attrs.@"volatile" != p2.attrs.@"volatile") break :blk false;
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
    if (exp_info == .pointer and got_info == .pointer) {
        const exp_ptr = exp_info.pointer;
        const got_ptr = got_info.pointer;
        if (exp_ptr.attrs.@"const" and !got_ptr.attrs.@"const") {
            return "Consider making the parameter type const (e.g., []const u8 instead of []u8)";
        }
    }

    // Check for optional vs non-optional mismatches
    if (exp_info == .optional and got_info != .optional) {
        return "The expected type is optional. Consider wrapping the parameter in '?'";
    }
    if (exp_info != .optional and got_info == .optional) {
        return "The expected type is non-optional. Remove the '?' from the parameter type";
    }

    // Check for enum type mismatches
    if (exp_info == .@"enum" and got_info == .@"enum") {
        return "Check that the enum values and field names match exactly";
    }

    // Check for struct field mismatches
    if (exp_info == .@"struct" and got_info == .@"struct") {
        const exp_s = exp_info.@"struct";
        const got_s = got_info.@"struct";
        if (exp_s.field_names.len != got_s.field_names.len) {
            return "The structs have different numbers of fields";
        }
        // Could add more specific field comparison hints here
        return "Check that all struct field names and types match exactly";
    }

    // Generic catch-all for pointer size mismatches
    if (exp_info == .pointer and got_info == .pointer) {
        const exp_ptr = exp_info.pointer;
        const got_ptr = got_info.pointer;
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
    const base = std.fmt.comptimePrint(
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
        return base ++ std.fmt.comptimePrint("\n   {s}Hint: {s}", .{ indent, hint });
    }

    return base;
}

fn structFieldNames(comptime T: type) []const [:0]const u8 {
    return @typeInfo(T).@"struct".field_names;
}

fn generateVTableType(comptime methods: anytype, comptime embedded_interfaces: anytype, comptime has_embeds: bool) type {
    comptime {
        const FieldAttributes = std.builtin.Type.Struct.FieldAttributes;
        const VField = struct {
            name: [:0]const u8,
            type: type,
            attrs: FieldAttributes,
        };

        var fields: []const VField = &.{};

        // Helper function to add a method to the VTable
        const addMethod = struct {
            fn add(method_name: [:0]const u8, method_fn: anytype, field_list: []const VField) []const VField {
                const fn_info = @typeInfo(method_fn).@"fn";

                // Build parameter type list: insert *anyopaque as first param (implicit self)
                var param_types: [fn_info.param_types.len + 1]type = undefined;
                param_types[0] = *anyopaque;
                for (fn_info.param_types, 1..) |param_type, i| {
                    param_types[i] = param_type.?;
                }

                const FnType = @Fn(
                    &param_types,
                    &@splat(.{}),
                    fn_info.return_type.?,
                    .{ .@"callconv" = fn_info.attrs.@"callconv" },
                );
                const FnPtrType = *const FnType;

                return field_list ++ &[_]VField{.{
                    .name = method_name,
                    .type = FnPtrType,
                    .attrs = .{
                        .@"align" = @alignOf(FnPtrType),
                    },
                }};
            }
        }.add;

        // Helper to check if a field name already exists
        const hasField = struct {
            fn check(field_name: []const u8, field_list: []const VField) bool {
                for (field_list) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        return true;
                    }
                }
                return false;
            }
        }.check;

        // Add methods from embedded interfaces first
        if (has_embeds) {
            for (structFieldNames(@TypeOf(embedded_interfaces))) |embed_name| {
                const embed = @field(embedded_interfaces, embed_name);
                const embed_info = @typeInfo(embed.VTable).@"struct";
                for (embed_info.field_names, embed_info.field_types, embed_info.field_attrs) |name, field_type, attrs| {
                    // Skip if we already have this field (indicates a conflict that validation should catch)
                    if (!hasField(name, fields)) {
                        fields = fields ++ &[_]VField{.{
                            .name = name,
                            .type = field_type,
                            .attrs = attrs,
                        }};
                    }
                }
            }
        }

        // Add methods from primary interface
        for (structFieldNames(@TypeOf(methods))) |method_name| {
            const method_fn = @field(methods, method_name);
            // Only add if not already present from embedded interfaces
            if (!hasField(method_name, fields)) {
                fields = addMethod(method_name, method_fn, fields);
            }
        }

        var field_names: [fields.len][]const u8 = undefined;
        var field_types: [fields.len]type = undefined;
        var field_attrs: [fields.len]FieldAttributes = undefined;
        for (fields, 0..) |field, i| {
            field_names[i] = field.name;
            field_types[i] = field.type;
            field_attrs[i] = field.attrs;
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn CreateValidationNamespace(comptime methods: anytype, comptime embedded_interfaces: anytype, comptime has_embeds: bool) type {
    return struct {
        const Methods = @TypeOf(methods);
        const Embeds = @TypeOf(embedded_interfaces);

        /// Represents all possible interface implementation problems
        pub const Incompatibility = union(enum) {
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
                var method_count: usize = structFieldNames(Methods).len;

                // Count methods from embedded interfaces
                if (has_embeds) {
                    for (structFieldNames(Embeds)) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        method_count += embed.validation.collectMethodNames().len;
                    }
                }

                // Now create array of correct size
                var names: [method_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary interface methods
                for (structFieldNames(Methods)) |name| {
                    names[index] = name;
                    index += 1;
                }

                // Add embedded interface methods
                if (has_embeds) {
                    for (structFieldNames(Embeds)) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        const embed_methods = embed.validation.collectMethodNames();
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
                if (@hasField(Methods, method_name)) {
                    interface_count += 1;
                }

                // Count embedded interfaces
                if (has_embeds) {
                    for (structFieldNames(Embeds)) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        if (embed.validation.hasMethod(method_name)) {
                            interface_count += 1;
                        }
                    }
                }

                if (interface_count <= 1) return null;

                var interfaces: [interface_count][]const u8 = undefined;
                var index: usize = 0;

                // Add primary interface
                if (@hasField(Methods, method_name)) {
                    interfaces[index] = "primary";
                    index += 1;
                }

                // Add embedded interfaces
                if (has_embeds) {
                    for (structFieldNames(Embeds)) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        if (embed.validation.hasMethod(method_name)) {
                            interfaces[index] = @typeName(embed);
                            index += 1;
                        }
                    }
                }

                return &interfaces;
            }
        }

        /// Checks if this interface has a specific method
        pub fn hasMethod(comptime method_name: []const u8) bool {
            comptime {
                // Check primary interface
                if (@hasField(Methods, method_name)) {
                    return true;
                }

                // Check embedded interfaces
                if (has_embeds) {
                    for (structFieldNames(Embeds)) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        if (embed.validation.hasMethod(method_name)) {
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

            // Non-error-union returns: use structural compatibility (same as params)
            if (exp_info != .error_union or act_info != .error_union) {
                return isTypeCompatible(Expected, Actual);
            }

            // Payload must be structurally compatible. Interface `anyerror` accepts any
            // implementation error set; otherwise require an identical error set.
            if (!isTypeCompatible(exp_info.error_union.payload, act_info.error_union.payload)) {
                return false;
            }
            const exp_set = exp_info.error_union.error_set;
            const act_set = act_info.error_union.error_set;
            return exp_set == anyerror or exp_set == act_set;
        }

        /// Returns interface mismatches for `ImplType`. Must be evaluated at comptime.
        pub fn incompatibilities(comptime ImplType: type) []const Incompatibility {
            return comptime blk: {
                var problems: []const Incompatibility = &.{};

                // First check for method ambiguity across all interfaces
                var reported_ambiguous: []const []const u8 = &.{};
                for (collectMethodNames()) |method_name| {
                    var already_reported = false;
                    for (reported_ambiguous) |seen| {
                        if (std.mem.eql(u8, seen, method_name)) {
                            already_reported = true;
                            break;
                        }
                    }
                    if (already_reported) continue;

                    if (findMethodConflicts(method_name)) |conflicting_interfaces| {
                        reported_ambiguous = reported_ambiguous ++ &[_][]const u8{method_name};
                        problems = problems ++ &[_]Incompatibility{.{
                            .ambiguous_method = .{
                                .method = method_name,
                                .interfaces = conflicting_interfaces,
                            },
                        }};
                    }
                }

                // If we have ambiguous methods, return early
                if (problems.len > 0) break :blk problems;

                // Check primary interface methods
                for (structFieldNames(@TypeOf(methods))) |name| {
                    if (!@hasDecl(ImplType, name)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .missing_method = name,
                        }};
                        continue;
                    }

                    const impl_fn = @TypeOf(@field(ImplType, name));
                    const expected_fn = @field(methods, name);

                    const impl_type_info = @typeInfo(impl_fn);
                    if (impl_type_info != .@"fn") {
                        problems = problems ++ &[_]Incompatibility{.{
                            .missing_method = name,
                        }};
                        continue;
                    }

                    const impl_info = impl_type_info.@"fn";
                    const expected_info = @typeInfo(expected_fn).@"fn";

                    // Implementation has self parameter, interface signature doesn't
                    const expected_param_count = expected_info.param_types.len + 1;

                    if (impl_info.param_types.len != expected_param_count) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .wrong_param_count = .{
                                .method = name,
                                .expected = expected_param_count,
                                .got = impl_info.param_types.len,
                            },
                        }};
                    } else {
                        // Compare impl params[1..] (skip self) with interface params[0..]
                        for (impl_info.param_types[1..], expected_info.param_types, 0..) |impl_param, expected_param, i| {
                            if (!isTypeCompatible(impl_param.?, expected_param.?)) {
                                problems = problems ++ &[_]Incompatibility{.{
                                    .param_type_mismatch = .{
                                        .method = name,
                                        .param_index = i + 1,
                                        .expected = expected_param.?,
                                        .got = impl_param.?,
                                    },
                                }};
                            }
                        }
                    }

                    if (!isCompatibleErrorSet(expected_info.return_type.?, impl_info.return_type.?)) {
                        problems = problems ++ &[_]Incompatibility{.{
                            .return_type_mismatch = .{
                                .method = name,
                                .expected = expected_info.return_type.?,
                                .got = impl_info.return_type.?,
                            },
                        }};
                    }
                }

                // Check embedded interfaces
                if (has_embeds) {
                    for (structFieldNames(@TypeOf(embedded_interfaces))) |embed_name| {
                        const embed = @field(embedded_interfaces, embed_name);
                        const embed_problems = embed.validation.incompatibilities(ImplType);
                        problems = problems ++ embed_problems;
                    }
                }

                break :blk problems;
            };
        }

        fn formatIncompatibility(incompatibility: Incompatibility) []const u8 {
            const indent = if (builtin.target.os.tag == .windows) "   \\- " else "   └─ ";
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

                .ambiguous_method => |info| blk: {
                    // Join interface names for a readable error (cannot format []const []const u8 with {s})
                    var joined: []const u8 = "";
                    for (info.interfaces, 0..) |iface, i| {
                        if (i == 0) {
                            joined = iface;
                        } else {
                            joined = joined ++ ", " ++ iface;
                        }
                    }
                    break :blk std.fmt.comptimePrint("Method '{s}' is ambiguous - it appears in multiple interfaces: {s}\n" ++
                        "{s}Hint: This method needs to be uniquely implemented or the ambiguity resolved", .{
                        info.method,
                        joined,
                        indent,
                    });
                },
            };
        }

        pub fn satisfiedBy(comptime ImplType: type) void {
            comptime {
                const problems = incompatibilities(ImplType);
                if (problems.len > 0) {
                    const title = "Type '{s}' does not implement the expected interface(s). To fix:\n";

                    // First compute the total size needed for our error message
                    var total_len: usize = std.fmt.count(title, .{@typeName(ImplType)});

                    // Add space for each problem's length
                    for (1.., problems) |i, problem| {
                        total_len += std.fmt.count("{d}. {s}\n", .{ i, formatIncompatibility(problem) });
                    }

                    // Now create a fixed-size array of the exact size we need
                    var errors: [total_len]u8 = undefined;
                    var written: usize = 0;

                    written += (std.fmt.bufPrint(errors[written..], title, .{@typeName(ImplType)}) catch unreachable).len;

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
