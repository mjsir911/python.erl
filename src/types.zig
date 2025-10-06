const std = @import("std");

const c = @cImport({
    @cInclude("erl_nif.h");
    @cInclude("Python.h");
    @cInclude("marshal.h");
});

const NifEnv = ?*c.ErlNifEnv;
const NifTerm = c.ERL_NIF_TERM;
const PyObject = *c.PyObject;

const Error = error{
    PythonError,
    ErlangError,
    UnknownType,
    InvalidPythonObject,
    ConversionFailed,
    TupleTooBig,
    StrangeListLength,
};

pub fn erl_term_to_py_obj(env: NifEnv, term: NifTerm) !PyObject {
    if (c.enif_is_atom(env, term) != 0) {
        var atom_buf: [256]u8 = undefined;
        const len = c.enif_get_atom(env, term, &atom_buf, atom_buf.len, c.ERL_NIF_UTF8);
        if (len == 0) return Error.ErlangError;
        const atom_str = atom_buf[0..@intCast(len - 1)];

        if (std.mem.eql(u8, atom_str, "true")) {
            return @ptrCast(&c._Py_TrueStruct);
        } else if (std.mem.eql(u8, atom_str, "false")) {
            return @ptrCast(&c._Py_FalseStruct);
        } else {
            return Error.UnknownType;
        }
    }

    var string_val: [256]u8 = undefined;
    const string_len = c.enif_get_string(env, term, &string_val, string_val.len, c.ERL_NIF_UTF8);
    if (string_len > 0) {
        return c.PyUnicode_FromStringAndSize(&string_val[0], @intCast(string_len - 1)); // the minus one lmao
    }

    var int64_val: i64 = 0;
    if (c.enif_get_int64(env, term, &int64_val) != 0) {
        return c.PyLong_FromLongLong(int64_val);
    }

    var double_val: f64 = 0;
    if (c.enif_get_double(env, term, &double_val) != 0) {
        return c.PyFloat_FromDouble(double_val);
    }

    var bin: c.ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, term, &bin) != 0) {
        return c.PyBytes_FromStringAndSize(bin.data, @intCast(bin.size));
    }

    if (c.enif_is_list(env, term) != 0) {
        var length: c_uint = 0;
        if (c.enif_get_list_length(env, term, &length) == 0) {
            return Error.StrangeListLength;
        }

        const py_list = c.PyList_New(length);
        if (py_list == null) return Error.PythonError;

        var head: NifTerm = undefined;
        var tail: NifTerm = undefined;
        var list = term;
        var i: usize = 0;
        while (c.enif_get_list_cell(env, list, &head, &tail) != 0) {
            const py_item = try erl_term_to_py_obj(env, head);
                // c.Py_DecRef(py_list);
            // PyList_SetItem steals ref
            _ = c.PyList_SetItem(py_list, @intCast(i), py_item);
            i += 1;
            list = tail;
        }
        return py_list;
    }

    return Error.UnknownType;
}

pub fn py_obj_to_erl_term(env: NifEnv, obj: PyObject) !NifTerm {
    if (c.PyBool_Check(obj) != 0) {
        if (obj == @as(PyObject, @ptrCast(&c._Py_TrueStruct))) {
            return c.enif_make_atom(env, "true");
        } else {
            return c.enif_make_atom(env, "false");
        }
    }

    if (c.PyLong_Check(obj) != 0) {
        const val = c.PyLong_AsLongLong(obj);
        if (val == -1 and c.PyErr_Occurred() != null) {
            return Error.PythonError;
        }
        return c.enif_make_int64(env, val);
    }

    if (c.PyFloat_Check(obj) != 0) {
        const val = c.PyFloat_AsDouble(obj);
        return c.enif_make_double(env, val);
    }

    if (c.PyUnicode_Check(obj) != 0) {
        var size: c.Py_ssize_t = 0;
        const cstr = c.PyUnicode_AsUTF8AndSize(obj, &size);
        return c.enif_make_string_len(env, cstr, @intCast(size), c.ERL_NIF_UTF8);
    }

    if (c.PyBytes_Check(obj) != 0) {
        const size: usize = @intCast(c.PyBytes_Size(obj));
        const data = c.PyBytes_AsString(obj)[0..size];
        var bin: c.ErlNifBinary = undefined;
        if (c.enif_alloc_binary(size, &bin) == 0) {
            return c.enif_make_atom(env, "error");
        }
        @memcpy(bin.data[0..size], data);
        return c.enif_make_binary(env, &bin);
    }

    return Error.UnknownType;
}
