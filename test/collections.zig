const std = @import("std");
const Interface = @import("interface").Interface;

// Define State interface for a state machine
// Generate VTable-based runtime type
const State = Interface(.{
    .onEnter = fn () void,
    .onExit = fn () void,
    .update = fn (f32) void,
}, null).Type();

// Menu state implementation
const MenuState = struct {
    name: []const u8,
    entered: bool = false,
    exited: bool = false,
    updates: u32 = 0,

    pub fn onEnter(self: *MenuState) void {
        self.entered = true;
    }

    pub fn onExit(self: *MenuState) void {
        self.exited = true;
    }

    pub fn update(self: *MenuState, delta: f32) void {
        _ = delta;
        self.updates += 1;
    }
};

// Gameplay state implementation
const GameplayState = struct {
    score: u32 = 0,
    time_elapsed: f32 = 0.0,

    pub fn onEnter(self: *GameplayState) void {
        self.score = 0;
        self.time_elapsed = 0.0;
    }

    pub fn onExit(self: *GameplayState) void {
        _ = self;
    }

    pub fn update(self: *GameplayState, delta: f32) void {
        self.time_elapsed += delta;
        self.score += 10;
    }
};

// Pause state implementation
const PauseState = struct {
    paused_at: f32 = 0.0,

    pub fn onEnter(self: *PauseState) void {
        _ = self;
    }

    pub fn onExit(self: *PauseState) void {
        _ = self;
    }

    pub fn update(self: *PauseState, delta: f32) void {
        self.paused_at += delta;
    }
};

// State manager with stack of interface objects
const StateManager = struct {
    stack: std.ArrayList(State),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StateManager {
        return .{
            .stack = std.ArrayList(State){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateManager) void {
        // Exit all states before cleanup
        while (self.stack.items.len > 0) {
            self.popState();
        }
        self.stack.deinit(self.allocator);
    }

    pub fn pushState(self: *StateManager, state: State) !void {
        try self.stack.append(self.allocator, state);
        // Call onEnter on the new state
        const current = &self.stack.items[self.stack.items.len - 1];
        current.vtable.onEnter(current.ptr);
    }

    pub fn popState(self: *StateManager) void {
        if (self.stack.items.len > 0) {
            const current = &self.stack.items[self.stack.items.len - 1];
            current.vtable.onExit(current.ptr);
            _ = self.stack.pop();
        }
    }

    pub fn update(self: *StateManager, delta: f32) void {
        if (self.stack.items.len > 0) {
            const current = &self.stack.items[self.stack.items.len - 1];
            current.vtable.update(current.ptr, delta);
        }
    }

    pub fn currentStateCount(self: StateManager) usize {
        return self.stack.items.len;
    }
};

test "state machine basic push and pop" {
    var menu = MenuState{ .name = "Main Menu" };
    var gameplay = GameplayState{};

    var manager = StateManager.init(std.testing.allocator);
    defer manager.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), manager.currentStateCount());

    // Push menu state - auto-generated wrappers!
    try manager.pushState(State.from(&menu));
    try std.testing.expectEqual(@as(usize, 1), manager.currentStateCount());
    try std.testing.expect(menu.entered);
    try std.testing.expect(!menu.exited);

    // Push gameplay state - auto-generated wrappers!
    try manager.pushState(State.from(&gameplay));
    try std.testing.expectEqual(@as(usize, 2), manager.currentStateCount());

    // Pop gameplay
    manager.popState();
    try std.testing.expectEqual(@as(usize, 1), manager.currentStateCount());

    // Pop menu
    manager.popState();
    try std.testing.expectEqual(@as(usize, 0), manager.currentStateCount());
    try std.testing.expect(menu.exited);
}

test "state machine update propagation" {
    var menu = MenuState{ .name = "Main Menu" };
    var gameplay = GameplayState{};

    var manager = StateManager.init(std.testing.allocator);
    defer manager.deinit();

    // Push menu and update it
    try manager.pushState(State.from(&menu));
    try std.testing.expectEqual(@as(u32, 0), menu.updates);

    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 1), menu.updates);

    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 2), menu.updates);

    // Push gameplay - it becomes the active state
    try manager.pushState(State.from(&gameplay));
    try std.testing.expectEqual(@as(u32, 0), gameplay.score);

    manager.update(0.016);
    // Gameplay updated, menu not updated
    try std.testing.expectEqual(@as(u32, 10), gameplay.score);
    try std.testing.expectEqual(@as(u32, 2), menu.updates);

    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 20), gameplay.score);
    try std.testing.expectEqual(@as(u32, 2), menu.updates);
}

test "state machine complex transitions" {
    var menu = MenuState{ .name = "Main Menu" };
    var gameplay = GameplayState{};
    var pause = PauseState{};

    var manager = StateManager.init(std.testing.allocator);
    defer manager.deinit();

    // Menu -> Gameplay -> Pause -> Gameplay -> Menu
    try manager.pushState(State.from(&menu));
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 1), menu.updates);

    try manager.pushState(State.from(&gameplay));
    manager.update(0.016);
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 20), gameplay.score);

    try manager.pushState(State.from(&pause));
    manager.update(0.016);
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), pause.paused_at, 0.001);
    // Gameplay shouldn't update while paused
    try std.testing.expectEqual(@as(u32, 20), gameplay.score);

    // Unpause
    manager.popState();
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 30), gameplay.score);

    // Back to menu
    manager.popState();
    manager.update(0.016);
    try std.testing.expectEqual(@as(u32, 2), menu.updates);
}

test "heterogeneous collection of states" {
    var menu1 = MenuState{ .name = "Main Menu" };
    var menu2 = MenuState{ .name = "Options Menu" };
    var gameplay1 = GameplayState{};
    var gameplay2 = GameplayState{};
    var pause = PauseState{};

    // Create an array of different state types
    const states = [_]State{
        State.from(&menu1),
        State.from(&gameplay1),
        State.from(&pause),
        State.from(&menu2),
        State.from(&gameplay2),
    };

    // All states can be called through the same interface
    for (states) |state| {
        state.vtable.onEnter(state.ptr);
        state.vtable.update(state.ptr, 0.016);
        state.vtable.onExit(state.ptr);
    }

    // Verify they were all called
    try std.testing.expect(menu1.entered);
    try std.testing.expect(menu1.exited);
    try std.testing.expect(menu2.entered);
    try std.testing.expect(menu2.exited);
    try std.testing.expectEqual(@as(u32, 1), menu1.updates);
    try std.testing.expectEqual(@as(u32, 1), menu2.updates);
    try std.testing.expectEqual(@as(u32, 10), gameplay1.score);
    try std.testing.expectEqual(@as(u32, 10), gameplay2.score);
}

test "state manager with multiple instance types" {
    var menu = MenuState{ .name = "Main" };
    var gameplay = GameplayState{};
    var pause = PauseState{};

    var manager = StateManager.init(std.testing.allocator);
    defer manager.deinit();

    // Push different types in sequence
    try manager.pushState(State.from(&menu));
    try manager.pushState(State.from(&gameplay));
    try manager.pushState(State.from(&pause));

    try std.testing.expectEqual(@as(usize, 3), manager.currentStateCount());

    // Update only affects top of stack
    manager.update(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pause.paused_at, 0.001);
    try std.testing.expectEqual(@as(u32, 0), gameplay.score);
    try std.testing.expectEqual(@as(u32, 0), menu.updates);
}
