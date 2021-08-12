const std = @import("std");
const Tree = @import("Tree.zig");
const TokenIndex = Tree.TokenIndex;
const NodeIndex = Tree.NodeIndex;
const Parser = @import("Parser.zig");
const Compilation = @import("Compilation.zig");

const Type = @This();

pub const Qualifiers = packed struct {
    @"const": bool = false,
    atomic: bool = false,
    @"volatile": bool = false,
    restrict: bool = false,

    pub fn any(quals: Qualifiers) bool {
        return quals.@"const" or quals.restrict or quals.@"volatile" or quals.atomic;
    }

    pub fn dump(quals: Qualifiers, w: anytype) !void {
        if (quals.@"const") try w.writeAll("const ");
        if (quals.atomic) try w.writeAll("_Atomic ");
        if (quals.@"volatile") try w.writeAll("volatile ");
        if (quals.restrict) try w.writeAll("restrict ");
    }
};

// TODO improve memory usage
pub const Func = struct {
    return_type: Type,
    params: []Param,

    pub const Param = struct {
        name: []const u8,
        ty: Type,
        register: bool,
    };
};

pub const Array = struct {
    len: u64,
    elem: Type,
};

pub const VLA = struct {
    expr: NodeIndex,
    elem: Type,
};

// TODO improve memory usage
pub const Enum = struct {
    name: []const u8,
    tag_ty: Type,
    fields: []Field,

    pub const Field = struct {
        name: []const u8,
        ty: Type,
        value: u64,
    };

    pub fn isIncomplete(e: Enum) bool {
        return e.fields.len == std.math.maxInt(usize);
    }

    pub fn create(allocator: *std.mem.Allocator, name: []const u8) !*Enum {
        var e = try allocator.create(Enum);
        e.name = name;
        e.fields.len = std.math.maxInt(usize);
        return e;
    }
};

// TODO improve memory usage
pub const Record = struct {
    name: []const u8,
    fields: []Field,
    size: u32,
    alignment: u32,

    pub const Field = struct {
        name: []const u8,
        ty: Type,
        bit_width: u32,
    };

    pub fn isIncomplete(r: Record) bool {
        return r.fields.len == std.math.maxInt(usize);
    }

    pub fn create(allocator: *std.mem.Allocator, name: []const u8) !*Record {
        var r = try allocator.create(Record);
        r.name = name;
        r.fields.len = std.math.maxInt(usize);
        return r;
    }
};

pub const Specifier = enum {
    void,
    bool,

    // integers
    char,
    schar,
    uchar,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
    long_long,
    ulong_long,

    // floating point numbers
    float,
    double,
    long_double,
    complex_float,
    complex_double,
    complex_long_double,

    // data.sub_type
    pointer,
    unspecified_variable_len_array,
    // data.func
    /// int foo(int bar, char baz) and int (void)
    func,
    /// int foo(int bar, char baz, ...)
    var_args_func,
    /// int foo(bar, baz) and int foo()
    /// is also var args, but we can give warnings about incorrect amounts of parameters
    old_style_func,

    // data.array
    array,
    static_array,
    incomplete_array,
    // data.vla
    variable_len_array,

    // data.record
    @"struct",
    @"union",

    // data.enum
    @"enum",
};

data: union {
    sub_type: *Type,
    func: *Func,
    array: *Array,
    vla: *VLA,
    @"enum": *Enum,
    record: *Record,
    none: void,
} = .{ .none = {} },
alignment: u32 = 0,
specifier: Specifier,
qual: Qualifiers = .{},

pub fn isCallable(ty: Type) ?Type {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => ty,
        .pointer => ty.data.sub_type.isCallable(),
        else => null,
    };
}

pub fn isFunc(ty: Type) bool {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => true,
        else => false,
    };
}

pub fn isArray(ty: Type) bool {
    return switch (ty.specifier) {
        .array, .static_array, .incomplete_array, .variable_len_array, .unspecified_variable_len_array => true,
        else => false,
    };
}

pub fn isInt(ty: Type) bool {
    return switch (ty.specifier) {
        .bool, .char, .schar, .uchar, .short, .ushort, .int, .uint, .long, .ulong, .long_long, .ulong_long => true,
        else => false,
    };
}

pub fn isFloat(ty: Type) bool {
    return switch (ty.specifier) {
        .float, .double, .long_double, .complex_float, .complex_double, .complex_long_double => true,
        else => false,
    };
}

pub fn isUnsignedInt(ty: Type, comp: *Compilation) bool {
    _ = comp;
    return switch (ty.specifier) {
        .char => return false, // TODO check comp for char signedness
        .uchar, .ushort, .uint, .ulong, .ulong_long => return true,
        else => false,
    };
}

pub fn isEnumOrRecord(ty: Type) bool {
    return switch (ty.specifier) {
        .@"enum", .@"struct", .@"union" => true,
        else => false,
    };
}

pub fn elemType(ty: Type) Type {
    return switch (ty.specifier) {
        .pointer, .unspecified_variable_len_array => ty.data.sub_type.*,
        .array, .static_array, .incomplete_array => ty.data.array.elem,
        .variable_len_array => ty.data.vla.elem,
        else => unreachable,
    };
}

pub fn eitherLongDouble(a: Type, b: Type) ?Type {
    if (a.specifier == .long_double or a.specifier == .complex_long_double) return a;
    if (b.specifier == .long_double or b.specifier == .complex_long_double) return b;
    return null;
}

pub fn eitherDouble(a: Type, b: Type) ?Type {
    if (a.specifier == .double or a.specifier == .complex_double) return a;
    if (b.specifier == .double or b.specifier == .complex_double) return b;
    return null;
}

pub fn eitherFloat(a: Type, b: Type) ?Type {
    if (a.specifier == .float or a.specifier == .complex_float) return a;
    if (b.specifier == .float or b.specifier == .complex_float) return b;
    return null;
}

pub fn integerPromotion(ty: Type, comp: *Compilation) Type {
    return .{
        .specifier = switch (ty.specifier) {
            .bool, .char, .schar, .uchar, .short => .int,
            .ushort => if (ty.sizeof(comp).? == sizeof(.{ .specifier = .int }, comp)) Specifier.uint else .int,
            .int => .int,
            .uint => .uint,
            .long => .long,
            .ulong => .ulong,
            .long_long => .long_long,
            .ulong_long => .ulong_long,
            else => unreachable, // not an integer type
        },
    };
}

pub fn wideChar(p: *Parser) Type {
    _ = p;
    // TODO get target from compilation
    return .{ .specifier = .int };
}

pub fn hasIncompleteSize(ty: Type) bool {
    return switch (ty.specifier) {
        .void, .incomplete_array => true,
        .@"enum" => ty.data.@"enum".isIncomplete(),
        .@"struct", .@"union" => ty.data.record.isIncomplete(),
        else => false,
    };
}

/// Size of type as reported by sizeof
pub fn sizeof(ty: Type, comp: *Compilation) ?u32 {
    // TODO get target from compilation
    return switch (ty.specifier) {
        .variable_len_array, .unspecified_variable_len_array, .incomplete_array => return null,
        .func, .var_args_func, .old_style_func, .void, .bool => 1,
        .char, .schar, .uchar => 1,
        .short, .ushort => 2,
        .int, .uint => 4,
        .long, .ulong => switch (comp.target.os.tag) {
            .linux,
            .macos,
            .freebsd,
            .netbsd,
            .dragonfly,
            .openbsd,
            .wasi,
            .emscripten,
            => comp.target.cpu.arch.ptrBitWidth() >> 3,
            .windows, .uefi => 32,
            else => 32,
        },
        .long_long, .ulong_long => 8,
        .float => 4,
        .double => 8,
        .long_double => 16,
        .complex_float => 8,
        .complex_double => 16,
        .complex_long_double => 32,
        .pointer, .static_array => comp.target.cpu.arch.ptrBitWidth() >> 3,
        .array => ty.data.array.elem.sizeof(comp).? * @intCast(u32, ty.data.array.len),
        .@"struct", .@"union" => if (ty.data.record.isIncomplete()) null else ty.data.record.size,
        .@"enum" => if (ty.data.@"enum".isIncomplete()) null else ty.data.@"enum".tag_ty.sizeof(comp),
    };
}

pub fn eql(a: Type, b: Type, check_qualifiers: bool) bool {
    if (a.alignment != b.alignment) return false;
    if (a.specifier != b.specifier) return false;

    if (check_qualifiers) {
        if (a.qual.@"const" != b.qual.@"const") return false;
        if (a.qual.atomic != b.qual.atomic) return false;
        if (a.qual.@"volatile" != b.qual.@"volatile") return false;
        if (a.qual.restrict != b.qual.restrict) return false;
    }

    switch (a.specifier) {
        .pointer,
        .unspecified_variable_len_array,
        => if (!a.data.sub_type.eql(b.data.sub_type.*, true)) return false,

        .func,
        .var_args_func,
        .old_style_func,
        => {
            // TODO validate this
            if (a.data.func.params.len != b.data.func.params.len) return false;
            if (!a.data.func.return_type.eql(b.data.func.return_type, true)) return false;
            for (a.data.func.params) |param, i| {
                if (!param.ty.eql(b.data.func.params[i].ty, true)) return false;
            }
        },

        .array,
        .static_array,
        .incomplete_array,
        => {
            if (a.data.array.len != b.data.array.len) return false;
            if (!a.data.array.elem.eql(b.data.array.elem, true)) return false;
        },
        .variable_len_array => if (!a.data.vla.elem.eql(b.data.vla.elem, true)) return false,

        .@"struct", .@"union" => if (a.data.record != b.data.record) return false,
        .@"enum" => if (a.data.@"enum" != b.data.@"enum") return false,

        else => {},
    }
    return true;
}

pub fn combine(inner: *Type, outer: Type, p: *Parser, source_tok: TokenIndex) Parser.Error!void {
    switch (inner.specifier) {
        .pointer => return inner.data.sub_type.combine(outer, p, source_tok),
        .unspecified_variable_len_array => return p.todo("combine [*] array"),
        .variable_len_array => {
            try inner.data.vla.elem.combine(outer, p, source_tok);

            if (inner.data.vla.elem.hasIncompleteSize()) return p.errTok(.array_incomplete_elem, source_tok);
            if (inner.data.vla.elem.isFunc()) return p.errTok(.array_func_elem, source_tok);
            if (inner.data.vla.elem.qual.any() and inner.isArray()) return p.errTok(.qualifier_non_outermost_array, source_tok);
        },
        .array, .static_array, .incomplete_array => {
            try inner.data.array.elem.combine(outer, p, source_tok);

            if (inner.data.array.elem.hasIncompleteSize()) return p.errTok(.array_incomplete_elem, source_tok);
            if (inner.data.array.elem.isFunc()) return p.errTok(.array_func_elem, source_tok);
            if (inner.data.array.elem.specifier == .static_array and inner.isArray()) return p.errTok(.static_non_outermost_array, source_tok);
            if (inner.data.array.elem.qual.any() and inner.isArray()) return p.errTok(.qualifier_non_outermost_array, source_tok);
        },
        .func, .var_args_func, .old_style_func => {
            try inner.data.func.return_type.combine(outer, p, source_tok);
            if (inner.data.func.return_type.isArray()) return p.errTok(.func_cannot_return_array, source_tok);
            if (inner.data.func.return_type.isFunc()) return p.errTok(.func_cannot_return_func, source_tok);
        },
        else => inner.* = outer,
    }
}

/// An unfinished Type
pub const Builder = struct {
    typedef: ?struct {
        tok: TokenIndex,
        ty: Type,
    } = null,
    kind: Kind = .none,

    pub const Kind = union(enum) {
        none,
        void,
        bool,
        char,
        schar,
        uchar,

        unsigned,
        signed,
        short,
        sshort,
        ushort,
        short_int,
        sshort_int,
        ushort_int,
        int,
        sint,
        uint,
        long,
        slong,
        ulong,
        long_int,
        slong_int,
        ulong_int,
        long_long,
        slong_long,
        ulong_long,
        long_long_int,
        slong_long_int,
        ulong_long_int,

        float,
        double,
        long_double,
        complex,
        complex_long,
        complex_float,
        complex_double,
        complex_long_double,

        pointer: *Type,
        unspecified_variable_len_array: *Type,
        func: *Func,
        var_args_func: *Func,
        old_style_func: *Func,
        array: *Array,
        static_array: *Array,
        incomplete_array: *Array,
        variable_len_array: *VLA,
        @"struct": *Record,
        @"union": *Record,
        @"enum": *Enum,

        pub fn str(spec: Kind) ?[]const u8 {
            return switch (spec) {
                .none => unreachable,
                .void => "void",
                .bool => "_Bool",
                .char => "char",
                .schar => "signed char",
                .uchar => "unsigned char",
                .unsigned => "unsigned",
                .signed => "signed",
                .short => "short",
                .ushort => "unsigned short",
                .sshort => "signed short",
                .short_int => "short int",
                .sshort_int => "signed short int",
                .ushort_int => "unsigned short int",
                .int => "int",
                .sint => "signed int",
                .uint => "unsigned int",
                .long => "long",
                .slong => "signed long",
                .ulong => "unsigned long",
                .long_int => "long int",
                .slong_int => "signed long int",
                .ulong_int => "unsigned long int",
                .long_long => "long long",
                .slong_long => "signed long long",
                .ulong_long => "unsigned long long",
                .long_long_int => "long long int",
                .slong_long_int => "signed long long int",
                .ulong_long_int => "unsigned long long int",

                .float => "float",
                .double => "double",
                .long_double => "long double",
                .complex => "_Complex",
                .complex_long => "_Complex long",
                .complex_float => "_Complex float",
                .complex_double => "_Complex double",
                .complex_long_double => "_Complex long double",

                else => null,
            };
        }
    };

    pub fn finish(spec: Builder, p: *Parser, ty: *Type) Parser.Error!void {
        ty.specifier = switch (spec.kind) {
            .none => {
                ty.specifier = .int;
                return p.err(.missing_type_specifier);
            },
            .void => .void,
            .bool => .bool,
            .char => .char,
            .schar => .schar,
            .uchar => .uchar,

            .unsigned => .uint,
            .signed => .int,
            .short_int, .sshort_int, .short, .sshort => .short,
            .ushort, .ushort_int => .ushort,
            .int, .sint => .int,
            .uint => .uint,
            .long, .slong, .long_int, .slong_int => .long,
            .ulong, .ulong_int => .ulong,
            .long_long, .slong_long, .long_long_int, .slong_long_int => .long_long,
            .ulong_long, .ulong_long_int => .ulong_long,

            .float => .float,
            .double => .double,
            .long_double => .long_double,
            .complex_float => .complex_float,
            .complex_double => .complex_double,
            .complex_long_double => .complex_long_double,
            .complex, .complex_long => {
                try p.errExtra(.type_is_invalid, p.tok_i, .{ .str = spec.kind.str().? });
                return error.ParsingFailed;
            },

            .pointer => |data| {
                ty.specifier = .pointer;
                ty.data = .{ .sub_type = data };
                return;
            },
            .unspecified_variable_len_array => |data| {
                ty.specifier = .unspecified_variable_len_array;
                ty.data = .{ .sub_type = data };
                return;
            },
            .func => |data| {
                ty.specifier = .func;
                ty.data = .{ .func = data };
                return;
            },
            .var_args_func => |data| {
                ty.specifier = .var_args_func;
                ty.data = .{ .func = data };
                return;
            },
            .old_style_func => |data| {
                ty.specifier = .old_style_func;
                ty.data = .{ .func = data };
                return;
            },
            .array => |data| {
                ty.specifier = .array;
                ty.data = .{ .array = data };
                return;
            },
            .static_array => |data| {
                ty.specifier = .static_array;
                ty.data = .{ .array = data };
                return;
            },
            .incomplete_array => |data| {
                ty.specifier = .incomplete_array;
                ty.data = .{ .array = data };
                return;
            },
            .variable_len_array => |data| {
                ty.specifier = .variable_len_array;
                ty.data = .{ .vla = data };
                return;
            },
            .@"struct" => |data| {
                ty.specifier = .@"struct";
                ty.data = .{ .record = data };
                return;
            },
            .@"union" => |data| {
                ty.specifier = .@"union";
                ty.data = .{ .record = data };
                return;
            },
            .@"enum" => |data| {
                ty.specifier = .@"enum";
                ty.data = .{ .@"enum" = data };
                return;
            },
        };
    }

    pub fn cannotCombine(spec: Builder, p: *Parser, source_tok: TokenIndex) Compilation.Error!void {
        var prev_ty: Type = .{ .specifier = undefined };
        spec.finish(p, &prev_ty) catch unreachable;
        try p.errExtra(.cannot_combine_spec, source_tok, .{ .str = try p.typeStr(prev_ty) });
        if (spec.typedef) |some| try p.errStr(.spec_from_typedef, some.tok, try p.typeStr(some.ty));
    }

    pub fn combine(spec: *Builder, p: *Parser, new: Kind, source_tok: TokenIndex) Compilation.Error!void {
        switch (new) {
            else => switch (spec.kind) {
                .none => spec.kind = new,
                else => return spec.cannotCombine(p, source_tok),
            },
            .signed => spec.kind = switch (spec.kind) {
                .none => .signed,
                .char => .schar,
                .short => .sshort,
                .short_int => .sshort_int,
                .int => .sint,
                .long => .slong,
                .long_int => .slong_int,
                .long_long => .slong_long,
                .long_long_int => .slong_long_int,
                .sshort,
                .sshort_int,
                .sint,
                .slong,
                .slong_int,
                .slong_long,
                .slong_long_int,
                => return p.errStr(.duplicate_decl_spec, p.tok_i, "signed"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .unsigned => spec.kind = switch (spec.kind) {
                .none => .unsigned,
                .char => .uchar,
                .short => .ushort,
                .short_int => .ushort_int,
                .int => .uint,
                .long => .ulong,
                .long_int => .ulong_int,
                .long_long => .ulong_long,
                .long_long_int => .ulong_long_int,
                .ushort,
                .ushort_int,
                .uint,
                .ulong,
                .ulong_int,
                .ulong_long,
                .ulong_long_int,
                => return p.errStr(.duplicate_decl_spec, p.tok_i, "unsigned"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .char => spec.kind = switch (spec.kind) {
                .none => .char,
                .unsigned => .uchar,
                .signed => .schar,
                .char, .schar, .uchar => return p.errStr(.duplicate_decl_spec, p.tok_i, "char"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .short => spec.kind = switch (spec.kind) {
                .none => .short,
                .unsigned => .ushort,
                .signed => .sshort,
                else => return spec.cannotCombine(p, source_tok),
            },
            .int => spec.kind = switch (spec.kind) {
                .none => .int,
                .signed => .sint,
                .unsigned => .uint,
                .short => .short_int,
                .sshort => .sshort_int,
                .ushort => .ushort_int,
                .long => .long_int,
                .slong => .slong_int,
                .ulong => .ulong_int,
                .long_long => .long_long_int,
                .slong_long => .slong_long_int,
                .ulong_long => .ulong_long_int,
                .int,
                .sint,
                .uint,
                .short_int,
                .sshort_int,
                .ushort_int,
                .long_int,
                .slong_int,
                .ulong_int,
                .long_long_int,
                .slong_long_int,
                .ulong_long_int,
                => return p.errStr(.duplicate_decl_spec, p.tok_i, "int"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .long => spec.kind = switch (spec.kind) {
                .none => .long,
                .long => .long_long,
                .unsigned => .ulong,
                .signed => .long,
                .int => .long_int,
                .sint => .slong_int,
                .ulong => .ulong_long,
                .long_long, .ulong_long => return p.errStr(.duplicate_decl_spec, p.tok_i, "long"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .float => spec.kind = switch (spec.kind) {
                .none => .float,
                .complex => .complex_float,
                .complex_float, .float => return p.errStr(.duplicate_decl_spec, p.tok_i, "float"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .double => spec.kind = switch (spec.kind) {
                .none => .double,
                .long => .long_double,
                .complex_long => .complex_long_double,
                .complex => .complex_double,
                .long_double,
                .complex_long_double,
                .complex_double,
                .double,
                => return p.errStr(.duplicate_decl_spec, p.tok_i, "double"),
                else => return spec.cannotCombine(p, source_tok),
            },
            .complex => spec.kind = switch (spec.kind) {
                .none => .complex,
                .long => .complex_long,
                .float => .complex_float,
                .double => .complex_double,
                .long_double => .complex_long_double,
                .complex,
                .complex_long,
                .complex_float,
                .complex_double,
                .complex_long_double,
                => return p.errStr(.duplicate_decl_spec, p.tok_i, "_Complex"),
                else => return spec.cannotCombine(p, source_tok),
            },
        }
    }

    pub fn fromType(ty: Type) Kind {
        return switch (ty.specifier) {
            .void => .void,
            .bool => .bool,
            .char => .char,
            .schar => .schar,
            .uchar => .uchar,
            .short => .short,
            .ushort => .ushort,
            .int => .int,
            .uint => .uint,
            .long => .long,
            .ulong => .ulong,
            .long_long => .long_long,
            .ulong_long => .ulong_long,
            .float => .float,
            .double => .double,
            .long_double => .long_double,
            .complex_float => .complex_float,
            .complex_double => .complex_double,
            .complex_long_double => .complex_long_double,

            .pointer => .{ .pointer = ty.data.sub_type },
            .unspecified_variable_len_array => .{ .unspecified_variable_len_array = ty.data.sub_type },
            .func => .{ .func = ty.data.func },
            .var_args_func => .{ .var_args_func = ty.data.func },
            .old_style_func => .{ .old_style_func = ty.data.func },
            .array => .{ .array = ty.data.array },
            .static_array => .{ .static_array = ty.data.array },
            .incomplete_array => .{ .incomplete_array = ty.data.array },
            .variable_len_array => .{ .variable_len_array = ty.data.vla },
            .@"struct" => .{ .@"struct" = ty.data.record },
            .@"union" => .{ .@"union" = ty.data.record },
            .@"enum" => .{ .@"enum" = ty.data.@"enum" },
        };
    }
};

/// Useful for debugging, too noisy to be enabled by default.
const dump_detailed_containers = false;

// Print as Zig types since those are actually readable
pub fn dump(ty: Type, w: anytype) @TypeOf(w).Error!void {
    try ty.qual.dump(w);
    switch (ty.specifier) {
        .pointer => {
            try w.writeAll("*");
            try ty.data.sub_type.dump(w);
        },
        .func, .var_args_func, .old_style_func => {
            try w.writeAll("fn (");
            for (ty.data.func.params) |param, i| {
                if (i != 0) try w.writeAll(", ");
                if (param.register) try w.writeAll("register ");
                if (param.name.len != 0) try w.print("{s}: ", .{param.name});
                try param.ty.dump(w);
            }
            if (ty.specifier != .func) {
                if (ty.data.func.params.len != 0) try w.writeAll(", ");
                try w.writeAll("...");
            }
            try w.writeAll(") ");
            try ty.data.func.return_type.dump(w);
        },
        .array, .static_array => {
            try w.writeByte('[');
            if (ty.specifier == .static_array) try w.writeAll("static ");
            try w.print("{d}]", .{ty.data.array.len});
            try ty.data.array.elem.dump(w);
        },
        .incomplete_array => {
            try w.writeAll("[]");
            try ty.data.array.elem.dump(w);
        },
        .@"enum" => {
            try w.print("enum {s}", .{ty.data.@"enum".name});
            if (dump_detailed_containers) try dumpEnum(ty.data.@"enum", w);
        },
        .@"struct" => {
            try w.print("struct {s}", .{ty.data.record.name});
            if (dump_detailed_containers) try dumpRecord(ty.data.record, w);
        },
        .@"union" => {
            try w.print("union {s}", .{ty.data.record.name});
            if (dump_detailed_containers) try dumpRecord(ty.data.record, w);
        },
        .unspecified_variable_len_array => {
            try w.writeAll("[*]");
            try ty.data.array.elem.dump(w);
        },
        .variable_len_array => {
            try w.writeAll("[<expr>]");
            try ty.data.array.elem.dump(w);
        },
        else => try w.writeAll(Builder.fromType(ty).str().?),
    }
    if (ty.alignment != 0) try w.print(" _Alignas({d})", .{ty.alignment});
}

fn dumpEnum(@"enum": *Enum, w: anytype) @TypeOf(w).Error!void {
    try w.writeAll(" {");
    for (@"enum".fields) |field| {
        try w.print(" {s} = {d},", .{ field.name, field.value });
    }
    try w.writeAll(" }");
}

fn dumpRecord(record: *Record, w: anytype) @TypeOf(w).Error!void {
    try w.writeAll(" {");
    for (record.fields) |field| {
        try w.writeByte(' ');
        try field.ty.dump(w);
        try w.print(" {s}: {d};", .{ field.name, field.bit_width });
    }
    try w.writeAll(" }");
}
