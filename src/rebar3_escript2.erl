
-module(rebar3_escript2).

-export([init/1]).

init(State) ->
    lists:foldl( fun provider_init/2
               , {ok, State}
               , [ rebar3_escript2_escriptize
                 , rebar3_escript2_clean
                 ]).

provider_init(Module, {ok, State}) ->
    Module:init(State).
