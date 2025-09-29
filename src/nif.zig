const std = @import("std");

const c = @cImport({
    @cInclude("erl_nif.h");
    @cInclude("Python.h");
    @cInclude("marshal.h");
});

const types = @import("types.zig");

const NifEnv = ?*c.ErlNifEnv;
const NifTerm = c.ERL_NIF_TERM;

fn make_error(env: NifEnv, msg: [*:0]const u8) NifTerm {
    const errmsg = c.enif_make_atom(env, msg);
    _ = c.enif_make_tuple2(
        env,
        c.enif_make_atom(env, "error"),
        errmsg,
    );
    _ = c.enif_raise_exception(env, errmsg);
    return 0;
}

pub fn make_error_from_zig(env: NifEnv, err: anyerror) NifTerm {
    return make_error(env, @errorName(err));
}

fn nif_marshal(env: NifEnv, argc: c_int, argv: [*c] const NifTerm) callconv(.C) NifTerm {
    if (argc != 1) return c.enif_make_badarg(env);

    c.Py_Initialize();
    defer c.Py_Finalize();

    const py_obj = types.erl_term_to_py_obj(env.?, argv[0]) catch |err| return make_error_from_zig(env, err);
    defer c.Py_DecRef(py_obj);

    const marshaled = c.PyMarshal_WriteObjectToString(py_obj, c.Py_MARSHAL_VERSION);
    if (marshaled == null) return make_error(env, "marshal_failed");
    defer c.Py_DecRef(marshaled);

    const size: usize = @intCast(c.PyBytes_Size(marshaled));
    const data = c.PyBytes_AsString(marshaled)[0..size];
    // var dst_slice = out_bin.data[0..@intCast(usize, size)];
    // const data = c.PyBytes_AsString(marshaled);

    var out_bin: c.ErlNifBinary = undefined;
    if (c.enif_alloc_binary(size, &out_bin) == 0) return make_error(env, "alloc_error");

    @memcpy(out_bin.data[0..size], data);

    return c.enif_make_binary(env, &out_bin);
}

fn nif_unmarshal(env: NifEnv, argc: c_int, argv: [*c] const NifTerm) callconv(.C) NifTerm {
    if (argc != 1) return c.enif_make_badarg(env);

    var bin: c.ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[0], &bin) == 0) {
        return c.enif_make_badarg(env);
    }

    c.Py_Initialize();
    defer c.Py_Finalize();

    const obj = c.PyMarshal_ReadObjectFromString(bin.data, @intCast(bin.size));
    if (obj == null) return make_error(env, "binary_error");
    defer c.Py_DecRef(obj);

    return types.py_obj_to_erl_term(env.?, obj) catch |err| return make_error_from_zig(env, err);
}


const nif_funcs = [_]c.ErlNifFunc{
    // .{ .name = "eval", .arity = 2, .fptr = py_eval_dirty, .flags = c.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    // .{ .name = "compile", .arity = 1, .fptr = py_compile_dirty, .flags = 0 },
    .{ .name = "marshal", .arity = 1, .fptr = nif_marshal, .flags = 0 },
    .{ .name = "unmarshal", .arity = 1, .fptr = nif_unmarshal, .flags = 0 },
};

export fn nif_load(env: NifEnv, priv: [*c]?*anyopaque, info: NifTerm) callconv(.C) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

export fn nif_unload(env: NifEnv, priv: ?*anyopaque) void {
    _ = env;
    _ = priv;
    // just in case, shouldn't happen
    if (c.Py_IsInitialized() != 0) {
        c.Py_Finalize();
    }
}

export fn nif_init() *const c.ErlNifEntry {
    return &c.ErlNifEntry{
        .major = 2,
        .minor = 16,
        .name = "erlang_python",
        .num_of_funcs = nif_funcs.len,
        .funcs = @constCast(&nif_funcs[0]),
        .load = nif_load,
        .reload = null,
        .upgrade = null,
        .unload = nif_unload,
        .vm_variant = "beam.vanilla",
        .options = 1,
        .sizeof_ErlNifResourceTypeInit = @sizeOf(c.ErlNifResourceTypeInit),
    };
}

