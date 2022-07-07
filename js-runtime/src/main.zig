const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const js = struct {
    extern fn zigCreateMap() u32;
    extern fn zigCreateArray() u32;
    extern fn zigCreateString(str: [*]const u8, len: u32) u32;
    extern fn zigCreateFunction(id: *const anyopaque) u32;
    extern fn zigGetProperty(id: u64, name: [*]const u8, len: u32, ret_ptr: *anyopaque) void;
    extern fn zigSetProperty(id: u64, name: [*]const u8, len: u32, set_ptr: *const anyopaque) void;
    extern fn zigDeleteProperty(id: u64, name: [*]const u8, len: u32) void;
    extern fn zigGetIndex(id: u64, index: u32, ret_ptr: *anyopaque) void;
    extern fn zigSetIndex(id: u64, index: u32, set_ptr: *const anyopaque) void;
    extern fn zigGetString(val_id: u64, ptr: [*]const u8) void;
    extern fn zigGetStringLength(val_id: u64) u32;
    extern fn zigValueEqual(val: *const anyopaque, other: *const anyopaque) bool;
    extern fn zigValueInstanceOf(val: *const anyopaque, other: *const anyopaque) bool;
    extern fn zigDeleteIndex(id: u64, index: u32) void;
    extern fn zigFunctionCall(id: u64, name: [*]const u8, len: u32, args: ?*const anyopaque, args_len: u32, ret_ptr: *anyopaque) void;
    extern fn zigFunctionInvoke(id: u64, args: ?*const anyopaque, args_len: u32, ret_ptr: *anyopaque) void;
    extern fn zigConstructType(id: u64, args: ?*const anyopaque, args_len: u32, ret_ptr: *anyopaque) void;
    extern fn zigCleanupObject(id: u64) void;
};

pub const Value = extern struct {
    tag: ValueTag,
    val: extern union {
        ref: u64,
        num: f64,
        bool: bool,
    },

    const ValueTag = enum(u8) {
        ref,
        num,
        bool,
        str,
        nulled,
        undef,
        func_js,
        func_zig,
    };

    pub const Tag = enum {
        object,
        num,
        bool,
        str,
        nulled,
        undef,
        func,
    };

    pub fn is(val: *const Value, comptime tag: Tag) bool {
        return switch (tag) {
            .object => val.tag == .object,
            .num => val.tag == .num,
            .bool => val.tag == .bool,
            .str => val.tag == .str,
            .nulled => val.tag == .nulled,
            .undef => val.tag == .undef,
            .func => val.tag == .func_js or val.tag == .func_zig,
        };
    }

    pub fn view(val: *const Value, comptime tag: Tag) switch (tag) {
        .object => Object,
        .num => f64,
        .bool => bool,
        .str => String,
        .func => Function,
        .nulled, .undef => @compileError("Cannot get null or undefined as a value"),
    } {
        return switch (tag) {
            .object => Object{ .ref = val.val.ref },
            .num => val.val.num,
            .bool => val.val.bool,
            .str => String{ .ref = val.val.ref },
            .func => Function{ .ref = val.val.ref },
            else => unreachable,
        };
    }

    pub fn eql(val: *const Value, other: Value) bool {
        if (val.tag != other.tag)
            return false;

        return switch (val.tag) {
            .num => val.val.num == other.val.num,
            .bool => val.val.bool == other.val.bool,
            // Using JS equality (===) is better here since lets say a ref can be dangling
            else => js.zigValueEqual(val, &other),
        };
    }

    pub fn instanceOf(val: *const Value, other: Value) bool {
        return js.zigValueInstanceOf(val, &other);
    }
};

pub const Object = struct {
    ref: u64,

    pub fn deinit(obj: *const Object) void {
        js.zigCleanupObject(obj.ref);
    }

    pub fn toValue(obj: *const Object) Value {
        return .{ .tag = .ref, .val = .{ .ref = obj.ref } };
    }

    pub fn get(obj: *const Object, prop: []const u8) Value {
        var ret: Value = undefined;
        js.zigGetProperty(obj.ref, prop.ptr, @intCast(u32, prop.len), &ret);
        return ret;
    }

    pub fn set(obj: *const Object, prop: []const u8, value: Value) void {
        js.zigSetProperty(obj.ref, prop.ptr, @intCast(u32, prop.len), &value);
    }

    pub fn delete(obj: *const Object, prop: []const u8) void {
        js.zigDeleteProperty(obj.ref, prop.ptr, @intCast(u32, prop.len));
    }

    pub fn getIndex(obj: *const Object, index: u32) Value {
        var ret: Value = undefined;
        js.zigGetIndex(obj.ref, index, &ret);
        return ret;
    }

    pub fn setIndex(obj: *const Object, index: u32, value: Value) void {
        js.zigSetIndex(obj.ref, index, &value);
    }

    pub fn deleteIndex(obj: *const Object, index: u32) void {
        js.zigDeleteIndex(obj.ref, index);
    }

    pub fn call(obj: *const Object, fun: []const u8, args: []const Value) Value {
        var ret: Value = undefined;
        js.zigFunctionCall(obj.ref, fun.ptr, fun.len, args.ptr, args.len, &ret);
        return ret;
    }
};

pub const Function = struct {
    ref: u64,

    pub fn deinit(func: *const Function) void {
        js.zigCleanupObject(func.ref);
    }

    pub fn toValue(func: *const Function) Value {
        return .{ .tag = .func_zig, .val = .{ .ref = func.ref } };
    }

    pub fn construct(func: *const Function, args: []const Value) Value {
        var ret: Value = undefined;
        js.zigConstructType(func.ref, args.ptr, args.len, &ret);
        return ret;
    }

    pub fn invoke(func: *const Function, args: []const Value) Value {
        var ret: Value = undefined;
        js.zigFunctionInvoke(func.ref, args.ptr, args.len, &ret);
        return ret;
    }
};

pub const String = struct {
    ref: u64,

    pub fn deinit(string: *const String) void {
        js.zigCleanupObject(string.ref);
    }

    pub fn toValue(string: *const String) Value {
        return .{ .tag = .str, .val = .{ .ref = string.ref } };
    }

    pub fn getLength(string: *const String) usize {
        return js.zigGetStringLength(string.ref);
    }

    pub fn getOwnedSlice(string: *const String, allocator: std.mem.Allocator) ![]const u8 {
        var slice = try allocator.alloc(u8, string.getLength());
        errdefer allocator.free(slice);
        js.zigGetString(string.ref, slice.ptr);
        return slice;
    }
};

export fn wasmCallFunction(id: *anyopaque, args: u32, len: u32) void {
    const obj = Object{ .ref = args };
    if (builtin.zig_backend == .stage1) {
        obj.set("return_value", functions.items[@ptrToInt(id) - 1](obj, len));
    } else {
        var func = @ptrCast(*FunType, @alignCast(std.meta.alignment(*FunType), id));
        obj.set("return_value", func(obj, len));
    }
}

pub fn global() Object {
    return Object{ .ref = 0 };
}

pub fn createMap() Object {
    return .{ .ref = js.zigCreateMap() };
}

pub fn createArray() Object {
    return .{ .ref = js.zigCreateArray() };
}

pub fn createString(string: []const u8) String {
    return .{ .ref = js.zigCreateString(string.ptr, string.len) };
}

pub fn createNumber(num: f64) Value {
    return .{ .tag = .num, .val = .{ .num = num } };
}

pub fn createBool(val: bool) Value {
    return .{ .tag = .bool, .val = .{ .bool = val } };
}

pub fn createNull() Value {
    return .{ .tag = .nulled, .val = undefined };
}

pub fn createUndefined() Value {
    return .{ .tag = .undef, .val = undefined };
}

const FunType = fn (args: Object, args_len: u32) Value;

var functions: std.ArrayListUnmanaged(FunType) = .{};

pub fn createFunction(fun: FunType) Function {
    if (builtin.zig_backend == .stage1) {
        functions.append(std.heap.page_allocator, fun) catch unreachable;
        return .{ .ref = js.zigCreateFunction(@intToPtr(*anyopaque, functions.items.len)) };
    }
    return .{ .ref = js.zigCreateFunction(&fun) };
}

pub fn constructType(t: []const u8, args: []const Value) Value {
    const constructor = global().get(t).view(.func);
    defer constructor.deinit();

    return constructor.construct(args);
}