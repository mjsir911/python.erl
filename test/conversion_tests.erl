-module(conversion_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).


marshal_identity(Term) -> erlang_python:unmarshal(erlang_python:marshal(Term)).

mystring() -> utf8_string().


simple() ->
    SimpleTypes = [
        integer(),
        binary(),
        boolean(),
        mystring()
    ],
    union(SimpleTypes).

supported() ->
    SupportedTypes = [
        simple()
    ],
    union(SupportedTypes).


bool_test() ->
    _ = erlang_python:marshal(true),
    _ = erlang_python:marshal(false),
    ?assertEqual(true, marshal_identity(true), [{to_file, user}]),
    ?assertEqual(false, marshal_identity(false), [{to_file, user}]).

int_test() ->
    SimpleInt = 100,
    ?assertEqual(SimpleInt, marshal_identity(SimpleInt)),

    Result = proper:quickcheck(
        ?FORALL(Int, int(),
            Int =:= marshal_identity(Int)
        )
    ),
    ?assert(Result, [{to_file, user}]).

-define(PROPTEST_LONG_TIMEOUT, 100000).

string_test() ->
    SimpleString = "Hello, world!",
    ?assertEqual(SimpleString, marshal_identity(SimpleString)),

    Result = proper:quickcheck(
        ?TIMEOUT(?PROPTEST_LONG_TIMEOUT,
            ?FORALL(String, mystring(),
                String =:= marshal_identity(String)
            )
        )
    ),
    ?assert(Result, [{to_file, user}]).

binary_test() ->
    Result = proper:quickcheck(
        ?FORALL(Binary, binary(),
            Binary =:= marshal_identity(Binary)
        )
    ),
    ?assert(Result, [{to_file, user}]).

% list_test() ->
%     ?assert(proper:quickcheck(
%         ?FORALL(List, list(simple()),
%             List =:= marshal_identity(List)
%         )
%     ), [{to_file, user}]).

all_supported_test() -> 
    ?assert(proper:quickcheck(
        ?TIMEOUT(?PROPTEST_LONG_TIMEOUT,
            ?FORALL(Term, supported(),
                Term =:= marshal_identity(Term)
            )
        )
    ), [{to_file, user}]).
