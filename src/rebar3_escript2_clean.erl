
-module(rebar3_escript2_clean).


-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, clean).
-define(DEPS, []).


-define(PRV_ERROR(Reason), {error, {?MODULE, Reason}}).

-include_lib("kernel/include/file.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
                                {name, ?PROVIDER},
                                {module, ?MODULE},
                                {namespace, escript2},
                                {bare, true},
                                {deps, ?DEPS},
                                {example, "rebar3 escript2 clean"},
                                {opts, []},
                                {short_desc, "remove escript archives."},
                                {desc, desc()}
                                ]),
    {ok, rebar_state:add_provider(State, Provider)}.

desc() ->
    "Remove executable escript files".

do(State) ->
    rebar_api:info("Cleaning escript...", []),
    Res = case rebar_state:get(State, escript_main_app, undefined) of
        undefined ->
            case rebar_state:project_apps(State) of
                [App] ->
                    clean_escript(State, App);
                _ ->
                    ?PRV_ERROR(no_main_app)
            end;
        Name ->
            AllApps = rebar_state:all_deps(State)++rebar_state:project_apps(State),
            case rebar_app_utils:find(ec_cnv:to_binary(Name), AllApps) of
                {ok, AppInfo} ->
                    clean_escript(State, AppInfo);
                _ ->
                    ?PRV_ERROR({bad_name, Name})
            end
    end,
    Res.

    
clean_escript(State0, App) ->
    AppName = rebar_app_info:name(App),

    %% Get the output filename for the escript -- this may include dirs
    Filename = filename:join([rebar_dir:base_dir(State0), "bin",
                              rebar_state:get(State0, escript_name, AppName)]),
    rebar_api:info("Cleaning escript file ~s", [Filename]),
    {ok, State0}.
    
    
-spec format_error(any()) -> iolist().
format_error({write_failed, AppName, WriteError}) ->
    io_lib:format("Failed to write ~p script: ~p", [AppName, WriteError]).
    