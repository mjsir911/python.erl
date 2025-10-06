-module(eval_tests).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

run(Code) -> python:eval(python:compile(Code)).

compile_test() ->
    _ = python:compile("1 + 1"),
    _ = python:compile("'abc'"),
    _ = python:compile("print('abc')").

eval_test() ->
    ?assertEqual(2, run("1 + 1")),
    ?assertEqual("abc", run("'abc'")),
    ?assertEqual(16, run("2 ** 4")),
    ?assertEqual("cba", run("''.join(reversed('abc'))")),
    ?assertEqual(5.789999999999999, run("1.23 + 4.56")),
    ?assertEqual(
        #{"fragment" => [],"netloc" => "example.com", "params" => [],"path" => "/hi","query" => [], "scheme" => "https"},
        run("__import__('urllib.parse', fromlist=['urllib']).urlparse('https://example.com/hi')._asdict()")
    ).
