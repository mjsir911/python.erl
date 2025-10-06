const std = @import("std");

const c = @cImport({
    @cInclude("erl_nif.h");
    @cInclude("Python.h");
    @cInclude("marshal.h");
    @cInclude("dlfcn.h");
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

    // var string_val: [256]u8 = undefined;
    // const string_len = c.enif_get_string(env, term, &string_val, string_val.len, c.ERL_NIF_UTF8);
    // if (string_len > 0) {
    //     return c.PyUnicode_FromStringAndSize(&string_val[0], @intCast(string_len - 1)); // the minus one lmao
    // }

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

        const py_list = c.PyList_New(length) orelse return Error.PythonError;
        errdefer c.Py_DecRef(py_list);

        var head: NifTerm = undefined;
        var tail: NifTerm = undefined;
        var list = term;
        var i: usize = 0;
        while (c.enif_get_list_cell(env, list, &head, &tail) != 0) {
            const py_item = try erl_term_to_py_obj(env, head);
            _ = c.PyList_SetItem(py_list, @intCast(i), py_item);
            i += 1;
            list = tail;
        }
        return py_list;
    }

    if (c.enif_is_map(env, term) != 0) {
        var map_iter: c.ErlNifMapIterator = undefined;
        if (c.enif_map_iterator_create(env, term, &map_iter, c.ERL_NIF_MAP_ITERATOR_HEAD) == 0) {
            return Error.ErlangError;
        }

        const py_dict = c.PyDict_New() orelse return Error.PythonError;

        var key: NifTerm = undefined;
        var value: NifTerm = undefined;

        while (c.enif_map_iterator_get_pair(env, &map_iter, &key, &value) != 0) {
            const py_key = erl_term_to_py_obj(env, key) catch |err| {
                c.enif_map_iterator_destroy(env, &map_iter);
                return err;
            };
            const py_value = erl_term_to_py_obj(env, value) catch |err| {
                c.Py_DecRef(py_key);
                c.enif_map_iterator_destroy(env, &map_iter);
                return err;
            };

            if (c.PyDict_SetItem(py_dict, py_key, py_value) != 0) {
                c.Py_DecRef(py_key);
                c.Py_DecRef(py_value);
                c.enif_map_iterator_destroy(env, &map_iter);
                return Error.PythonError;
            }

            c.Py_DecRef(py_key);
            c.Py_DecRef(py_value);
            _ = c.enif_map_iterator_next(env, &map_iter);
        }

        c.enif_map_iterator_destroy(env, &map_iter);
        return py_dict;
    }

    if (c.enif_is_tuple(env, term) != 0) {
        var tuple_elements: [32]NifTerm = undefined;

        var tuple_ptr: [*c]NifTerm = &tuple_elements[0];

        var arity: c_int = undefined;
        if (c.enif_get_tuple(env, term, &arity, &tuple_ptr) == 0) {
            return Error.ErlangError;
        }

        if (arity > tuple_elements.len) return Error.TupleTooBig;

        const py_tuple = c.PyTuple_New(arity) orelse return Error.PythonError;
        // errdefer c.Py_DecRef(py_tuple);

        var i: usize = 0;
        while (i < arity) : (i += 1) {
            const py_elem = try erl_term_to_py_obj(env, tuple_ptr[i]);
            if (c.PyTuple_SetItem(py_tuple, @intCast(i), py_elem) != 0) return Error.PythonError;
        }

        return py_tuple;
    }



    return Error.UnknownType;
}


pub fn py_bytes_to_erl_binary(env: NifEnv, bytes: [*c]c.PyObject) !NifTerm {
    const size: usize = @intCast(c.PyBytes_Size(bytes));
    const data = c.PyBytes_AsString(bytes)[0..size];

    var out_bin: c.ErlNifBinary = undefined;
    if (c.enif_alloc_binary(size, &out_bin) == 0) return Error.ErlangError;

    @memcpy(out_bin.data[0..size], data);

    return c.enif_make_binary(env, &out_bin);
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
        return py_bytes_to_erl_binary(env, obj);
    }

    if (c.PyList_Check(obj) != 0) {
        const size = c.PyList_Size(obj);
        var result: NifTerm = c.enif_make_list(env, 0); // Start with empty list

        var i: isize = @intCast(size - 1);
        while (i >= 0) : (i -= 1) {
            const item = c.PyList_GetItem(obj, i); // Borrowed reference
            const erl_item = try py_obj_to_erl_term(env, item);
            result = c.enif_make_list_cell(env, erl_item, result);
        }

        return result;
    }

    if (c.PyDict_Check(obj) != 0) {
        const keys = c.PyDict_Keys(obj) orelse return Error.PythonError;
        defer c.Py_DecRef(keys);

        const size = c.PyList_Size(keys);
        var result_map: NifTerm = c.enif_make_new_map(env);
        if (result_map == 0) return Error.ErlangError;

        var i: usize = 0;
        while (i < size) : (i += 1) {
            const key = c.PyList_GetItem(keys, @intCast(i)); // Borrowed reference
            const val = c.PyDict_GetItem(obj, key);          // Borrowed reference

            const erl_key = try py_obj_to_erl_term(env, key);
            const erl_val = try py_obj_to_erl_term(env, val);

            var new_map: NifTerm = undefined;
            if (c.enif_make_map_put(env, result_map, erl_key, erl_val, &new_map) == 0) return Error.ErlangError;

            result_map = new_map;
        }

        return result_map;
    }

    // if (c.PyTuple_Check(obj) != 0) {
    //     const size = c.PyTuple_Size(obj);
    //     if (size > 32) return Error.TupleTooBig;

    //     var erl_elements: [32]NifTerm = undefined;
    //     var erl_ptr: [*c]NifTerm = &erl_elements[0];

    //     var i: usize = 0;
    //     while (i < size) : (i += 1) {
    //         const py_item = c.PyTuple_GetItem(obj, @intCast(i));
    //         erl_ptr[i] = try py_obj_to_erl_term(env, py_item);
    //     }

    //     return c.enif_make_tuple(env, @intCast(size), &erl_ptr);
    // }



    return Error.UnknownType;
}
