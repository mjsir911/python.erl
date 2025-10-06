-module(conversion_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).


marshal_identity(Term) -> python:unmarshal(python:marshal(Term)).

mystring() -> utf8_string().


simple() ->
    SimpleTypes = [
        integer(),
        float(),
        boolean(),
        binary()
    ],
    union(SimpleTypes).

keytypes() -> union([integer(), float(), binary()]). % let's not include boolean because of uhh reasons

supported() ->
    SupportedTypes = [
        simple(),
        mystring(),
        ?LAZY(list(supported())),
        ?LAZY(map(keytypes(), simple()))
    ],
    union(SupportedTypes).


bool_test() ->
    _ = python:marshal(true),
    _ = python:marshal(false),
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

float_test() ->
    ?assert(proper:quickcheck(
        ?FORALL(Float, float(),
            Float =:= marshal_identity(Float)
        )
    ) ,[{to_file, user}]).

string_test() ->
    SimpleString = "Hello, world!",
    ?assertEqual(SimpleString, marshal_identity(SimpleString)),

    Result = proper:quickcheck(
        ?FORALL(String, mystring(),
            String =:= marshal_identity(String)
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

simple_list_test() ->
    ?assert(proper:quickcheck(
        ?FORALL(List, list(simple()),
            List =:= marshal_identity(List)
        )
    ), [{to_file, user}]).

% simple_tuple_test() ->
%     ?assert(proper:quickcheck(
%         ?FORALL(Tuple, loose_tuple(simple()),
%             Tuple =:= marshal_identity(Tuple)
%         )
%     ), [{to_file, user}]).
%
% simple_dict_test() ->
%     ?assertEqual(marshal_identity(#{2 => 1}), #{2 => 1}),
%     % ?assert(proper:quickcheck(
%     %     ?FORALL(Dict, map(union([integer(), binary(), float()]), simple()),
%     %         Dict =:= marshal_identity(Dict)
%     %     )
%     % ), [{to_file, user}]),
%     ?assert(proper:quickcheck(
%         ?FORALL(Dict, map(union([boolean(), binary(), float()]), simple()),
%             Dict =:= marshal_identity(Dict)
%         )
%     ), [{to_file, user}]).


% all_supported_test() ->
%     ?assert(proper:quickcheck(
%         ?FORALL(Term, supported(),
%             Term =:= marshal_identity(Term)
%         )
%     )).
