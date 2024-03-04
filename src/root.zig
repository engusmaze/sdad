const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    array: []const Value,
    pair: *struct { Value, Value },
    ident: []const u8,

    const Self = @This();
    fn to_string_inner(self: *const Self, allocator: Allocator, string: *ArrayListUnmanaged(u8), comptime compact: bool) !void {
        switch (self.*) {
            .array => |array| {
                if (compact) {
                    try string.append(allocator, '{');
                } else {
                    try string.appendSlice(allocator, "{ ");
                }
                for (array) |value| {
                    if (compact) {
                        if (string.getLastOrNull()) |last| {
                            switch (last) {
                                ' ', '\t', '\n', '\r', '\x0B', '\x0C', '{', '}', '=' => {},
                                else => try string.append(allocator, ' '),
                            }
                        }
                    }
                    try value.to_string_inner(allocator, string, compact);
                    if (!compact)
                        try string.append(allocator, ' ');
                }
                try string.append(allocator, '}');
            },
            .pair => |pair| {
                try pair[0].to_string_inner(allocator, string, compact);
                if (compact) {
                    try string.append(allocator, '=');
                } else {
                    try string.appendSlice(allocator, " = ");
                }
                try pair[1].to_string_inner(allocator, string, compact);
            },
            .ident => |ident| try string.appendSlice(allocator, ident),
        }
    }
    pub fn to_string(self: *const Self, allocator: Allocator, comptime compact: bool) ![]u8 {
        var string = ArrayListUnmanaged(u8){};
        try self.to_string_inner(allocator, &string, compact);
        return string.toOwnedSlice(allocator);
    }
    fn to_string_pretty_inner(self: *const Self, allocator: Allocator, string: *ArrayListUnmanaged(u8), level: usize) !void {
        switch (self.*) {
            .array => |array| {
                const inner_level = level + 1;
                try string.appendSlice(allocator, "{\n");
                for (array) |value| {
                    try string.appendNTimes(allocator, '\t', inner_level);
                    try value.to_string_pretty_inner(allocator, string, inner_level);
                    try string.append(allocator, '\n');
                }
                try string.appendNTimes(allocator, '\t', level);
                try string.append(allocator, '}');
            },
            .pair => |pair| {
                try pair[0].to_string_pretty_inner(allocator, string, level);
                try string.appendSlice(allocator, " = ");
                try pair[1].to_string_pretty_inner(allocator, string, level);
            },
            .ident => |ident| try string.appendSlice(allocator, ident),
        }
    }
    pub fn to_string_pretty(self: *const Self, allocator: Allocator) ![]u8 {
        var string = ArrayListUnmanaged(u8){};
        try self.to_string_pretty_inner(allocator, &string, 0);
        return string.toOwnedSlice(allocator);
    }
    // Iterative deinit
    // pub fn deinit(self: Self, allocator: Allocator) void {
    //     var buffer = ArrayListUnmanaged(Value){};
    //     buffer.resize(allocator, 1) catch {};
    //     buffer.items[0] = self;
    //     while (buffer.items.len > 0) {
    //         switch (buffer.pop()) {
    //             .array => |array| {
    //                 buffer.appendSlice(allocator, array) catch {};
    //                 allocator.free(array);
    //             },
    //             .pair => |pair| {
    //                 buffer.appendSlice(allocator, pair) catch {};
    //                 allocator.destroy(pair);
    //             },
    //             // Ident should be a reference to external string
    //             .ident => {
    //                 // |ident| allocator.free(ident)
    //             },
    //         }
    //     }
    // }
    pub fn deinit(self: Self, allocator: Allocator) void {
        switch (self) {
            .array => |array| {
                for (array) |value|
                    value.deinit(allocator);
                allocator.free(array);
            },
            .pair => |pair| {
                pair[0].deinit(allocator);
                pair[1].deinit(allocator);
                allocator.destroy(pair);
            },
            // Ident should be a reference to external string
            .ident => {},
        }
    }
};

const ParseError = error{
    InvalidClosingBrace,
    ExpectedClosingBrace,
    ExpectedCharAfterEscape,
    ConsecutiveEquals,
    ExpectedValueBeforeEquals,
    ExpectedValueAfterEquals,
};

const Values = struct {
    array: ArrayListUnmanaged(Value),
    pair: bool = false,

    const Self = @This();
    inline fn append(self: *Self, allocator: Allocator, value: Value) !void {
        try self.array.append(allocator, result: {
            if (self.pair) {
                if (self.array.popOrNull()) |prev| {
                    self.pair = false;
                    var pair = try allocator.create(struct { Value, Value });
                    pair[0] = prev;
                    pair[1] = value;
                    break :result Value{ .pair = pair };
                } else {
                    return ParseError.ExpectedValueBeforeEquals;
                }
            } else break :result value;
        });
    }
};

pub fn parse(bytes: []const u8, allocator: Allocator) !Value {
    var parents = ArrayListUnmanaged(Values){};
    defer {
        for (parents.items) |par| {
            var parent = par;
            for (parent.array.items) |value|
                value.deinit(allocator);
            parent.array.deinit(allocator);
        }
        parents.deinit(allocator);
    }
    var current_values = Values{ .array = ArrayListUnmanaged(Value){} };
    var ptr = bytes.ptr;
    const end = bytes.ptr + bytes.len;
    while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += 1) {
        switch (ptr[0]) {
            // Ignore all whitespace
            ' ', '\t', '\n', '\r', '\x0B', '\x0C' => {},
            '{' => {
                try parents.append(allocator, current_values);
                current_values = Values{ .array = ArrayListUnmanaged(Value){} };
            },
            '}' => {
                if (parents.popOrNull()) |par| {
                    var parent = par;
                    try parent.append(allocator, Value{ .array = try current_values.array.toOwnedSlice(allocator) });
                    current_values = parent;
                } else return ParseError.InvalidClosingBrace;
            },
            // Pair
            '=' => {
                if (current_values.pair)
                    return ParseError.ConsecutiveEquals;
                current_values.pair = true;
            },
            '#' => while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += 1)
                switch (ptr[0]) {
                    '\n' => break,
                    else => {},
                },
            else => {
                const start = ptr;
                while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += 1) {
                    switch (ptr[0]) {
                        ' ', '\t', '\n', '\r', '\x0B', '\x0C', '{', '}', '=', '#' => break,
                        else => {},
                    }
                }
                try current_values.append(allocator, Value{ .ident = start[0 .. @intFromPtr(ptr) - @intFromPtr(start)] });
                continue;
            },
        }
    }

    if (parents.items.len > 0)
        return ParseError.ExpectedClosingBrace;

    if (current_values.array.items.len == 1) {
        defer current_values.array.deinit(allocator);
        return current_values.array.items[0];
    } else {
        return Value{ .array = try current_values.array.toOwnedSlice(allocator) };
    }
}
