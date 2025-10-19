const std = @import("std");
const Interface = @import("interface").Interface;

// Define our Generative AI API interface
const IGenerativeAI = Interface(.{
    .generate = fn ([]const u8) anyerror![]const u8,
    .embed = fn ([]const u8) anyerror![256]f16,
    .query = fn ([]const u8) anyerror![][]const u8,
}, null);

// OpenAI Mock Implementation
pub const OpenAIMock = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAIMock {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAIMock) void {
        _ = self;
    }

    pub fn generate(self: *OpenAIMock, prompt: []const u8) ![]const u8 {
        _ = self;
        _ = prompt;
        return "This is a mock response from OpenAI API";
    }

    pub fn embed(self: *OpenAIMock, input: []const u8) ![256]f16 {
        _ = self;
        _ = input;
        var embeddings: [256]f16 = undefined;
        for (&embeddings, 0..) |*val, i| {
            val.* = @floatFromInt(@as(i16, @intCast(i)));
        }
        return embeddings;
    }

    pub fn query(self: *OpenAIMock, input: []const u8) ![][]const u8 {
        _ = input;
        const results = try self.allocator.alloc([]const u8, 3);
        results[0] = "OpenAI result 1";
        results[1] = "OpenAI result 2";
        results[2] = "OpenAI result 3";
        return results;
    }
};

// Anthropic Mock Implementation
pub const AnthropicMock = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnthropicMock {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnthropicMock) void {
        _ = self;
    }

    pub fn generate(self: *AnthropicMock, prompt: []const u8) ![]const u8 {
        _ = self;
        _ = prompt;
        return "This is a mock response from Anthropic Claude API";
    }

    pub fn embed(self: *AnthropicMock, input: []const u8) ![256]f16 {
        _ = self;
        _ = input;
        var embeddings: [256]f16 = undefined;
        for (&embeddings, 0..) |*val, i| {
            // Use a different pattern than OpenAI to distinguish them
            val.* = @floatFromInt(@as(i16, @intCast(255 - i)));
        }
        return embeddings;
    }

    pub fn query(self: *AnthropicMock, input: []const u8) ![][]const u8 {
        _ = input;
        const results = try self.allocator.alloc([]const u8, 2);
        results[0] = "Anthropic result 1";
        results[1] = "Anthropic result 2";
        return results;
    }
};

// Generic Inference API wrapper that uses VTable-based runtime polymorphism
pub const Inference = struct {
    interface: IGenerativeAI.Type(),

    const Self = @This();

    pub fn init(interface: IGenerativeAI.Type()) Self {
        return .{ .interface = interface };
    }

    pub fn generate(self: *Self, prompt: []const u8) ![]const u8 {
        return try self.interface.vtable.generate(self.interface.ptr, prompt);
    }

    pub fn embed(self: *Self, input: []const u8) ![256]f16 {
        return try self.interface.vtable.embed(self.interface.ptr, input);
    }

    pub fn query(self: *Self, input: []const u8) ![][]const u8 {
        return try self.interface.vtable.query(self.interface.ptr, input);
    }
};

// Example function that works with any Generative AI implementation
fn processPrompt(api: anytype, prompt: []const u8) ![]const u8 {
    comptime IGenerativeAI.satisfiedBy(@TypeOf(api.*));
    return try api.generate(prompt);
}

test "OpenAI mock satisfies interface" {
    var openai = OpenAIMock.init(std.testing.allocator);
    defer openai.deinit();

    // Verify at comptime that our implementation satisfies the interface
    comptime IGenerativeAI.satisfiedBy(OpenAIMock);

    // Test generate
    const response = try openai.generate("Test prompt");
    try std.testing.expectEqualStrings("This is a mock response from OpenAI API", response);

    // Test embed
    const embeddings = try openai.embed("Test input");
    try std.testing.expectEqual(@as(f16, 0.0), embeddings[0]);
    try std.testing.expectEqual(@as(f16, 255.0), embeddings[255]);

    // Test query
    const results = try openai.query("Test query");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("OpenAI result 1", results[0]);
}

test "Anthropic mock satisfies interface" {
    var anthropic = AnthropicMock.init(std.testing.allocator);
    defer anthropic.deinit();

    // Verify at comptime that our implementation satisfies the interface
    comptime IGenerativeAI.satisfiedBy(AnthropicMock);

    // Test generate
    const response = try anthropic.generate("Test prompt");
    try std.testing.expectEqualStrings("This is a mock response from Anthropic Claude API", response);

    // Test embed
    const embeddings = try anthropic.embed("Test input");
    try std.testing.expectEqual(@as(f16, 255.0), embeddings[0]);
    try std.testing.expectEqual(@as(f16, 0.0), embeddings[255]);

    // Test query
    const results = try anthropic.query("Test query");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Anthropic result 1", results[0]);
}

test "processPrompt works with both implementations" {
    // Test with OpenAI
    var openai = OpenAIMock.init(std.testing.allocator);
    defer openai.deinit();

    const openai_response = try processPrompt(&openai, "Hello");
    try std.testing.expectEqualStrings("This is a mock response from OpenAI API", openai_response);

    // Test with Anthropic
    var anthropic = AnthropicMock.init(std.testing.allocator);
    defer anthropic.deinit();

    const anthropic_response = try processPrompt(&anthropic, "Hello");
    try std.testing.expectEqualStrings("This is a mock response from Anthropic Claude API", anthropic_response);
}

test "Inference wrapper with VTable-based providers" {
    const Provider = IGenerativeAI.Type();

    // Create OpenAI inference instance using VTable
    var openai_provider = OpenAIMock.init(std.testing.allocator);
    defer openai_provider.deinit();
    const openai_interface = Provider.from(&openai_provider);
    var openai_inference = Inference.init(openai_interface);

    // Test OpenAI generate
    const openai_response = try openai_inference.generate("Test prompt");
    try std.testing.expectEqualStrings("This is a mock response from OpenAI API", openai_response);

    // Test OpenAI embed
    const openai_embeddings = try openai_inference.embed("Test input");
    try std.testing.expectEqual(@as(f16, 0.0), openai_embeddings[0]);
    try std.testing.expectEqual(@as(f16, 255.0), openai_embeddings[255]);

    // Test OpenAI query
    const openai_results = try openai_inference.query("Test query");
    defer std.testing.allocator.free(openai_results);
    try std.testing.expectEqual(@as(usize, 3), openai_results.len);
    try std.testing.expectEqualStrings("OpenAI result 1", openai_results[0]);
    try std.testing.expectEqualStrings("OpenAI result 2", openai_results[1]);
    try std.testing.expectEqualStrings("OpenAI result 3", openai_results[2]);

    // Create Anthropic inference instance using VTable
    var anthropic_provider = AnthropicMock.init(std.testing.allocator);
    defer anthropic_provider.deinit();
    const anthropic_interface = Provider.from(&anthropic_provider);
    var anthropic_inference = Inference.init(anthropic_interface);

    // Test Anthropic generate
    const anthropic_response = try anthropic_inference.generate("Test prompt");
    try std.testing.expectEqualStrings("This is a mock response from Anthropic Claude API", anthropic_response);

    // Test Anthropic embed
    const anthropic_embeddings = try anthropic_inference.embed("Test input");
    try std.testing.expectEqual(@as(f16, 255.0), anthropic_embeddings[0]);
    try std.testing.expectEqual(@as(f16, 0.0), anthropic_embeddings[255]);

    // Test Anthropic query
    const anthropic_results = try anthropic_inference.query("Test query");
    defer std.testing.allocator.free(anthropic_results);
    try std.testing.expectEqual(@as(usize, 2), anthropic_results.len);
    try std.testing.expectEqualStrings("Anthropic result 1", anthropic_results[0]);
    try std.testing.expectEqualStrings("Anthropic result 2", anthropic_results[1]);
}

test "Runtime polymorphism with heterogeneous providers" {
    const Provider = IGenerativeAI.Type();

    // Create both providers
    var openai_provider = OpenAIMock.init(std.testing.allocator);
    defer openai_provider.deinit();
    var anthropic_provider = AnthropicMock.init(std.testing.allocator);
    defer anthropic_provider.deinit();

    // Store different provider types in an array (runtime polymorphism!)
    var providers = [_]Inference{
        Inference.init(Provider.from(&openai_provider)),
        Inference.init(Provider.from(&anthropic_provider)),
    };

    // Test that we can call through the array and get different results
    const openai_response = try providers[0].generate("prompt");
    const anthropic_response = try providers[1].generate("prompt");

    try std.testing.expectEqualStrings("This is a mock response from OpenAI API", openai_response);
    try std.testing.expectEqualStrings("This is a mock response from Anthropic Claude API", anthropic_response);

    // Test embeddings are different
    const openai_embed = try providers[0].embed("input");
    const anthropic_embed = try providers[1].embed("input");

    try std.testing.expectEqual(@as(f16, 0.0), openai_embed[0]);
    try std.testing.expectEqual(@as(f16, 255.0), anthropic_embed[0]);

    // Test query returns different number of results
    const openai_query = try providers[0].query("query");
    defer std.testing.allocator.free(openai_query);
    const anthropic_query = try providers[1].query("query");
    defer std.testing.allocator.free(anthropic_query);

    try std.testing.expectEqual(@as(usize, 3), openai_query.len);
    try std.testing.expectEqual(@as(usize, 2), anthropic_query.len);
}
