const std = @import("std");

const c = @cImport({
    @cInclude("erl_nif.h");
    @cInclude("Python.h");
    @cInclude("marshal.h");
    @cInclude("dlfcn.h");
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

pub fn make_error_from_python(env: NifEnv) NifTerm {
    return make_error_from_zig(env, python_error());
}

const PythonError = error{
    NameError,
    TypeError,
    SyntaxError,
    ValueError,
    PythonError, // fallback
};

fn python_error() PythonError {
    var ptype: ?*c.PyObject = null;
    var pvalue: ?*c.PyObject = null;
    var ptraceback: ?*c.PyObject = null;

    c.PyErr_Fetch(&ptype, &pvalue, &ptraceback);
    c.PyErr_NormalizeException(&ptype, &pvalue, &ptraceback);

    const err = if (ptype == c.PyExc_NameError) PythonError.NameError
        else if (ptype == c.PyExc_TypeError) PythonError.TypeError
        else if (ptype == c.PyExc_SyntaxError) PythonError.SyntaxError
        else if (ptype == c.PyExc_ValueError) PythonError.ValueError
        else PythonError.PythonError;

    // Optional: print error string
    const err_str_obj = c.PyObject_Str(pvalue);
    if (err_str_obj != null) {
        defer c.Py_DecRef(err_str_obj);
        const err_cstr = c.PyUnicode_AsUTF8(err_str_obj);
        if (err_cstr != null) {
            std.debug.print("Unhandled Python error: {s}\n", .{err_cstr});
        }
    }

    return err;
}

fn py_eval_dirty(env: NifEnv, argc: c_int, argv: [*c]const NifTerm) callconv(.C) NifTerm {
    if (argc != 2) return c.enif_make_badarg(env);

    var bytecode_bin: c.ErlNifBinary = undefined;
    var globals_bin: c.ErlNifBinary = undefined;

    if (c.enif_inspect_binary(env, argv[0], &bytecode_bin) == 0 or
        c.enif_inspect_binary(env, argv[1], &globals_bin) == 0)
    {
        return c.enif_make_badarg(env);
    }

    const state = c.PyGILState_Ensure();
    defer c.PyGILState_Release(state);


    const globals_obj = c.PyMarshal_ReadObjectFromString(
        globals_bin.data,
        @intCast(globals_bin.size)
    ) orelse return make_error(env, "globals_unmarshal_failed");
    defer c.Py_DecRef(globals_obj);

    if (c.PyDict_Check(globals_obj) == 0) return make_error(env, "globals_not_dict");

    // Unmarshal code object from marshalled bytes
    const code_obj = c.PyMarshal_ReadObjectFromString(
        bytecode_bin.data,
        @intCast(bytecode_bin.size)
    ) orelse return make_error(env, "unmarshal_code_failed");
    defer c.Py_DecRef(code_obj);

    // Execute the code object
    const result = c.PyEval_EvalCode(code_obj, globals_obj, globals_obj) orelse return make_error_from_python(env);
    defer c.Py_DecRef(result);



    return types.py_obj_to_erl_term(env, result) catch |err| return make_error_from_zig(env, err);
}

fn py_compile(env: NifEnv, argc: c_int, argv: [*c] const NifTerm) callconv(.C) NifTerm {
    if (argc != 1) return c.enif_make_badarg(env);


    var string_val: [256]u8 = undefined;
    const string_len = c.enif_get_string(env, argv[0], &string_val, string_val.len, c.ERL_NIF_UTF8);
    if (string_len <= 0) return c.enif_make_badarg(env);

    const state = c.PyGILState_Ensure();
    defer c.PyGILState_Release(state);

    const code_obj = c.Py_CompileString(
        @constCast(&string_val[0]),
        "erl_source",
        c.Py_eval_input,
    ) orelse return make_error(env, "compile_failed");

    const marshaled = c.PyMarshal_WriteObjectToString(code_obj, c.Py_MARSHAL_VERSION) orelse return make_error(env, "marshal_failed");

    return types.py_bytes_to_erl_binary(env, marshaled) catch |err| return make_error_from_zig(env, err);
}

fn nif_marshal(env: NifEnv, argc: c_int, argv: [*c] const NifTerm) callconv(.C) NifTerm {
    if (argc != 1) return c.enif_make_badarg(env);

    const state = c.PyGILState_Ensure();
    defer c.PyGILState_Release(state);

    const py_obj = types.erl_term_to_py_obj(env, argv[0]) catch |err| return make_error_from_zig(env, err);
    defer c.Py_DecRef(py_obj);

    const marshaled = c.PyMarshal_WriteObjectToString(py_obj, c.Py_MARSHAL_VERSION) orelse return make_error(env, "marshal_failed");
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

    const state = c.PyGILState_Ensure();
    defer c.PyGILState_Release(state);

    const obj = c.PyMarshal_ReadObjectFromString(bin.data, @intCast(bin.size)) orelse return make_error(env, "binary_error");
    defer c.Py_DecRef(obj);

    return types.py_obj_to_erl_term(env, obj) catch |err| return make_error_from_zig(env, err);
}


const nif_funcs = [_]c.ErlNifFunc{
    .{ .name = "eval", .arity = 2, .fptr = py_eval_dirty, .flags = c.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "compile", .arity = 1, .fptr = py_compile, .flags = 0 },
    .{ .name = "marshal", .arity = 1, .fptr = nif_marshal, .flags = 0 },
    .{ .name = "unmarshal", .arity = 1, .fptr = nif_unmarshal, .flags = 0 },
};

export fn nif_load(env: NifEnv, priv: [*c]?*anyopaque, info: NifTerm) callconv(.C) c_int {
    _ = env;
    _ = priv;
    _ = info;
    _ = c.dlopen("libpython3.13.so", c.RTLD_NOW | c.RTLD_GLOBAL);
    c.Py_Initialize();
    _ = c.PyEval_SaveThread();
    return 0;
}

export fn nif_unload(env: NifEnv, priv: ?*anyopaque) void {
    _ = env;
    _ = priv;
    c.Py_Finalize();
}

export fn nif_init() *const c.ErlNifEntry {
    return &c.ErlNifEntry{
        .major = 2,
        .minor = 16,
        .name = "python",
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

