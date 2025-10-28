# Zig Interfaces & Validation

A comprehensive interface system for Zig supporting both **compile-time
validation** and **runtime polymorphism** through VTable generation.

## Features

This library provides two complementary approaches to interface-based design in
Zig:

**VTable-Based Runtime Polymorphism:**

- **Automatic VTable wrapper generation**
- Automatic VTable type generation from interface definitions
- Runtime polymorphism with function pointer dispatch
- Return interface types from functions and store in fields

**Compile-Time Interface Validation:**

- Zero-overhead generic functions with compile-time type checking
- Detailed error reporting for interface mismatches
- Interface embedding (composition)
- Complex type validation including structs, enums, arrays, and slices
- Flexible error union compatibility with `anyerror`

## Install

Add or update this library as a dependency in your zig project run the following
command:

```sh
zig fetch --save git+https://github.com/nilslice/zig-interface
```

Afterwards add the library as a dependency to any module in your _build.zig_:

```zig
// ...
const interface_dependency = b.dependency("interface", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "main",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
// import the exposed `interface` module from the dependency
exe.root_module.addImport("interface", interface_dependency.module("interface"));
// ...
```

In the end you can import the `interface` module. For example:

```zig
const Interface = @import("interface").Interface;

const Repository = Interface(.{
    .create = fn(User) anyerror!u32,
    .findById = fn(u32) anyerror!?User,
    .update = fn(User) anyerror!void,
    .delete = fn(u32) anyerror!void,
}, null);
```

## Usage

### VTable-Based Runtime Polymorphism

The primary use case for this library is creating type-erased interface objects
that enable runtime polymorphism. This is ideal for storing different
implementations in collections, returning interface types from functions, or
building plugin systems.

**1. Define an interface with required method signatures:**

```zig
const Repository = Interface(.{
    .create = fn(User) anyerror!u32,
    .findById = fn(u32) anyerror!?User,
    .update = fn(User) anyerror!void,
    .delete = fn(u32) anyerror!void,
}, null);
```

> Note: `Interface()` generates a type whose function set declared implicitly
> take an `*anyopaque` self-reference. This saves you from needing to include it
> in the declaration. However, `anyerror` must be included for any fallible
> function, but can be omitted if your function cannot return an error.

**2. Implement the interface methods in your type:**

```zig
const InMemoryRepository = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u32, User),
    next_id: u32,

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
        if (!self.users.contains(user.id)) return error.UserNotFound;
        try self.users.put(user.id, user);
    }

    pub fn delete(self: *InMemoryRepository, id: u32) !void {
        if (!self.users.remove(id)) return error.UserNotFound;
    }
};
```

**3. Use the interface for runtime polymorphism:**

```zig
// Create different repository implementations
var in_memory_repo = InMemoryRepository.init(allocator);
var sql_repo = SqlRepository.init(allocator, db_connection);

// Convert to interface objects
const repo1 = Repository.from(&in_memory_repo);
const repo2 = Repository.from(&sql_repo);

// Store in heterogeneous collection
var repositories = [_]Repository{ repo1, repo2 };

// Use through the interface - runtime polymorphism!
for (repositories) |repo| {
    const user = User{ .id = 0, .name = "Alice", .email = "alice@example.com" };
    const id = try repo.vtable.create(repo.ptr, user);
    const found = try repo.vtable.findById(repo.ptr, id);
}

// Return interface types from functions
fn getRepository(use_memory: bool, allocator: Allocator) Repository {
    if (use_memory) {
        var repo = InMemoryRepository.init(allocator);
        return Repository.from(&repo);
    } else {
        var repo = SqlRepository.init(allocator);
        return Repository.from(&repo);
    }
}
```

### Compile-Time Validation (Alternative Approach)

For generic functions where you know the concrete type at compile time, you can
use the interface for validation without the VTable overhead:

```zig
// Generic function that accepts any Repository implementation
fn createUser(repo: anytype, name: []const u8, email: []const u8) !User {
    // Validate at compile time that repo implements IRepository
    comptime Repository.validation.satisfiedBy(@TypeOf(repo.*));

    const user = User{ .id = 0, .name = name, .email = email };
    const id = try repo.create(user);
    return User{ .id = id, .name = name, .email = email };
}

// Works with any concrete implementation - no VTable needed
var in_memory = InMemoryRepository.init(allocator);
const user = try createUser(&in_memory, "Alice", "alice@example.com");
```

## Interface Embedding

Interfaces can embed other interfaces to combine their requirements. The
generated VTable will include all methods from embedded interfaces:

```zig
const Logger = Interface(.{
    .log = fn([]const u8) void,
    .getLogLevel = fn() u8,
}, null);

const Metrics = Interface(.{
    .increment = fn([]const u8) void,
    .getValue = fn([]const u8) u64,
}, .{ Logger });  // Embeds Logger interface

// Implementation must provide all methods
const MyMetrics = struct {
    log_level: u8,
    counters: std.StringHashMap(u64),

    // Logger methods
    pub fn log(self: MyMetrics, msg: []const u8) void { ... }
    pub fn getLogLevel(self: MyMetrics) u8 { return self.log_level; }

    // Metrics methods
    pub fn increment(self: *MyMetrics, name: []const u8) void { ... }
    pub fn getValue(self: MyMetrics, name: []const u8) u64 { ... }
};

// Use it with auto-generated wrappers:
var my_metrics = MyMetrics{ ... };
const metrics = Metrics.from(&my_metrics);
```

> Note: you can embed arbitrarily many interfaces!

## Error Reporting

The library provides detailed compile-time errors when implementations don't
match:

```zig
// Wrong parameter type ([]u8 vs []const u8)
const BadImpl = struct {
    pub fn writeAll(self: @This(), data: []u8) !void {
        _ = self;
        _ = data;
    }
};

// Results in compile error:
// error: Method 'writeAll' parameter 1 has incorrect type:
//    └─ Expected: []const u8
//    └─ Got: []u8
//       └─ Hint: Consider making the parameter type const
```

## Complex Types

The interface checker supports complex types including structs, enums, arrays,
and optionals:

```zig
const Processor = Interface(.{
    .process = fn(
        struct { config: Config, points: []const DataPoint },
        enum { ready, processing, error },
        []const struct {
            timestamp: i64,
            data: ?[]const DataPoint,
            status: Status,
        }
    ) anyerror!?ProcessingResult,
}, null);
...
```

## Choosing Between VTable and Compile-Time Approaches

Both approaches work from the same interface definition and can be used
together:

| Feature             | VTable Runtime Polymorphism                                     | Compile-Time Validation            |
| ------------------- | --------------------------------------------------------------- | ---------------------------------- |
| **Use Case**        | Heterogeneous collections, plugin systems, returning interfaces | Generic functions, static dispatch |
| **Performance**     | Function pointer indirection                                    | Zero overhead (monomorphization)   |
| **Binary Size**     | Smaller (shared dispatch code)                                  | Larger (per-type instantiation)    |
| **Flexibility**     | Store in arrays, return from functions                          | Known types at compile time        |
| **Type Visibility** | Type-erased (`*anyopaque`)                                      | Concrete type always known         |
| **Method Calls**    | `interface.vtable.method(interface.ptr, args)`                  | Direct: `instance.method(args)`    |
| **When to Use**     | Need runtime flexibility                                        | Need maximum performance           |

**Example using both:**

```zig
// Define once
const Repository = Interface(.{
    .save = fn(Data) anyerror!void,
}, null);

// Use compile-time validation for hot paths
fn processBatch(repo: anytype, items: []const Data) !void {
    comptime Repository.validation.satisfiedBy(@TypeOf(repo.*));
    for (items) |item| {
        try repo.save(item);  // Direct call, can be inlined
    }
}

// Use VTable for plugin registry
const PluginRegistry = struct {
    repositories: []Repository,

    fn addPlugin(self: *PluginRegistry, repo: Repository) void {
        self.repositories = self.repositories ++ &[_]Repository{repo};
    }

    fn saveToAll(self: PluginRegistry, data: Data) !void {
        for (self.repositories) |repo| {
            try repo.vtable.save(repo.ptr, data);
        }
    }
};
```
