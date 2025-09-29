-module(erlang_python).
-on_load(init/0).
-export([marshal/1, unmarshal/1, bin_to_py_bytestring/1]).

init() ->
    erlang:load_nif("./zig-out/lib/liberlang-python", 0).

marshal(_Term) ->
    erlang:nif_error(not_loaded).

unmarshal(_Bin) ->
    erlang:nif_error(not_loaded).


bin_to_py_bytestring(Bin) when is_binary(Bin) ->
    Bytes = binary:bin_to_list(Bin),
    String = lists:map(fun(Byte) ->
        io_lib:format("\\x~2.16.0B", [Byte])
    end, Bytes),
    Str = lists:flatten(["b'" | String] ++ "'"),
    io:format("~s~n", [Str]),
    Str.
