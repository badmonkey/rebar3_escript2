%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
%% Modifications by Michael Fagan
%%
-module(rebar3_escript2_build).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, build).
%-define(PROVIDER, escriptize).
-define(DEPS, [{default, compile}]).


-define(PRV_ERROR(Reason), {error, {?MODULE, Reason}}).
-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

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
                                {example, "rebar3 escript2 build"},
                                {opts, []},
                                {short_desc, "Generate escript archive."},
                                {desc, desc()}
                                ]),
    {ok, rebar_state:add_provider(State, Provider)}.

desc() ->
    "Generate an escript executable containing "
        "the project's and its dependencies' BEAM files.".

do(State) ->
    Providers = rebar_state:providers(State),
    Cwd = rebar_state:dir(State),
    rebar_hooks:run_project_and_app_hooks(Cwd, pre, ?PROVIDER, Providers, State),
    Res = case rebar_state:get(State, escript_main_app, undefined) of
        undefined ->
            case rebar_state:project_apps(State) of
                [App] ->
                    escriptize(State, App);
                _ ->
                    ?PRV_ERROR(no_main_app)
            end;
        Name ->
            AllApps = rebar_state:all_deps(State)++rebar_state:project_apps(State),
            case rebar_app_utils:find(ec_cnv:to_binary(Name), AllApps) of
                {ok, AppInfo} ->
                    escriptize(State, AppInfo);
                _ ->
                    ?PRV_ERROR({bad_name, Name})
            end
    end,
    rebar_hooks:run_project_and_app_hooks(Cwd, post, ?PROVIDER, Providers, State),
    Res.

escriptize(State0, App) ->
    AppName = rebar_app_info:name(App),
    AppNameStr = ec_cnv:to_list(AppName),

    %% Get the output filename for the escript -- this may include dirs
    ScriptName = rebar_state:get(State0, escript_name, AppName),
    Filename = filename:join([rebar_dir:base_dir(State0), "bin", ScriptName]),
    rebar_api:info("Building escript ~s", [ScriptName]),
    rebar_api:debug("Writing escript file ~s", [Filename]),
    ok = filelib:ensure_dir(Filename),
    State = rebar_state:escript_path(State0, Filename),


    %% Look for a list of other applications (dependencies) to include
    %% in the output file. We then use the .app files for each of these
    %% to pull in all the .beam files.
    ThisApp = ec_cnv:to_atom(AppName),
    TopInclApps = lists:usort([ThisApp | rebar_state:get(State, escript_incl_apps, [])]),
    AllApps = rebar_state:all_deps(State)++rebar_state:project_apps(State),
    InclApps = find_deps(TopInclApps, AllApps),

    InclAppPaths = get_app_paths(InclApps, AllApps, []),


    %% Construct the archive of everything in ebin/ dir -- put it on the
    %% top-level of the zip file so that code loading works properly.
    EbinPrefix = filename:join(AppNameStr, "ebin"),
    EbinFiles = match_files(EbinPrefix, "*", "ebin"),

    InclBeams = get_app_beams(InclAppPaths),
    InclExtra = get_app_extras(InclAppPaths),

	[{ThisApp, ThisLibPath, ThisAppPath}] = get_app_paths([ThisApp], AllApps, []),
	ExtraFilesOverlay = rebar_state:get(State, escript_files, []),
	ExtraAppPaths = [ {"MainApp", ThisLibPath, ThisAppPath}
					, {"Root", ThisLibPath, rebar_dir:root_dir(State)}
					| InclAppPaths],
	InclOverlay = get_overlay_files(ExtraAppPaths, ExtraFilesOverlay),

    Files = get_nonempty( usort([EbinFiles, InclBeams, InclExtra, InclOverlay]) ),

	MainModuleStr = rebar_state:get(State, escript_main_module, AppNameStr),
	ExtraEmuArgs = rebar_state:get(State, escript_extra_emu_args, ""),
    DefaultEmuArgs = ?FMT("%%! -escript main ~s -pz ~s/~s/ebin -pz ~s ~s\n",
                          [MainModuleStr, AppNameStr, AppNameStr, AppNameStr, ExtraEmuArgs]),
    EscriptSections =
        [ {shebang,
           def("#!", State, escript_shebang, "#!/usr/bin/env escript\n")}
        , {comment, def("%%", State, escript_comment, "%%\n")}
        , {emu_args, def("%%!", State, escript_emu_args, DefaultEmuArgs)}
        , {archive, Files, []} ],
    case escript:create(Filename, EscriptSections) of
        ok -> ok;
        {error, EscriptError} ->
            throw(?PRV_ERROR({escript_creation_failed, AppName, EscriptError}))
    end,

    %% Finally, update executable perms for our script
    {ok, #file_info{mode = Mode}} = file:read_file_info(Filename),
    ok = file:change_mode(Filename, Mode bor 8#00111),
    {ok, State}.

    
-spec format_error(any()) -> iolist().
format_error({write_failed, AppName, WriteError}) ->
    io_lib:format("Failed to write ~p script: ~p", [AppName, WriteError]);
format_error({zip_error, AppName, ZipError}) ->
    io_lib:format("Failed to construct ~p escript: ~p", [AppName, ZipError]);
format_error({bad_name, App}) ->
    io_lib:format("Failed to get ebin/ directory for "
                   "escript_incl_app: ~p", [App]);
format_error({relative_path, Path}) ->
    io_lib:format("Path may not be relative "
                   "escript_files: ~p", [Path]);
format_error({contains_wildcards, Path}) ->
    io_lib:format("Path must not contain wildcard characters "
                   "escript_files: ~p", [Path]);
format_error(no_main_app) ->
    io_lib:format("Multiple project apps and {escript_main_app, atom()}."
                 " not set in rebar.config", []).

%% ===================================================================
%% Internal functions
%% ===================================================================


get_app_beams(AppPaths) ->
    gather_many_files(AppPaths, ebin, ["*.beam", "*.app"]).

        
get_app_extras(AppPaths) ->
    gather_many_files(AppPaths, priv, ["*"]) ++
    gather_many_files(AppPaths, include, ["*"]).


get_overlay_files(_, []) -> [];

get_overlay_files(AppPaths, [ {copy, Name, Input} | Rest]) ->
	PrefixInfo = expand_name(AppPaths, Name),
	InputInfo = expand_input(AppPaths, Input),

	N =	case { PrefixInfo, InputInfo } of
			{ {dir, Prefix}, 		 {file, Filename} }				->
				read_many_files([Filename], Prefix)

		;	{ {file_or_dir, Prefix}, {file, Filename} }				->
				read_file(Filename, Prefix)

		;	{ {_, Prefix}, 		 	 {many, ManyFiles} }			->
				read_many_files(ManyFiles, Prefix)

		;	{ {_, Prefix}, 		 	 {many, ManyDirs, Wildcard} }	->
				[ match_files(Dir, Wildcard, Prefix) || Dir <- ManyDirs ]
		end,

	[ N | get_overlay_files(AppPaths, Rest)];

get_overlay_files(AppPaths, [_ | Rest]) ->  
	get_overlay_files(AppPaths, Rest).


expand_input(AppPaths, Path) ->
	SplitPath = filename:split(Path),
	SplitDir = lists:droplast(SplitPath),
	FilePart = lists:last(SplitPath),
	Wildcards = has_wildcards(FilePart),

	case {filename:pathtype(Path), Wildcards} of
		{absolute, false}	-> {file, Path}
	;   {absolute, true}	-> {many, [filename:join(SplitDir)], FilePart}
	;	{relative, false}	-> expand_anchor(AppPaths, SplitPath, undefined)
	;	{relative, true}	-> expand_anchor(AppPaths, SplitDir, FilePart)
	end.


expand_name(_, "") -> {dir, ""};

expand_name(AppPaths, Name) ->
	SplitPath = filename:split(Name),
	Type = guess_type(Name),

	NewPath = expand_prefix(AppPaths, SplitPath),
	HasWildcards = has_wildcards(NewPath),

	case HasWildcards of
		true	-> throw(?PRV_ERROR({contains_wildcards, Name}))
	;	false	-> {Type, NewPath}
	end.


expand_prefix(AppPaths, [ "{MainApp}" | Rest ]) ->
	AppDir = find_app_path("MainApp", AppPaths),
	filename:join([ filename:basename(AppDir) | Rest ]);

expand_prefix(AppPaths, [ "/" | Rest ]) ->
	expand_prefix(AppPaths, Rest);

expand_prefix(_, PathList) ->
	filename:join(PathList).


expand_anchor(AppPaths, [ "{MainApp}" | Rest ], undefined) ->
	AppDir = find_app_path("MainApp", AppPaths),
	{file, filename:join([ AppDir | Rest])};

expand_anchor(AppPaths, [ "{MainApp}" | Rest ], FilePart) ->
	AppDir = find_app_path("MainApp", AppPaths),
	{many, [filename:join([ AppDir | Rest])], FilePart};

expand_anchor(AppPaths, [ "{*}" | Rest ], undefined) ->
	{many, [ filename:join([ Path | Rest]) || {App, Path} <- AppPaths, is_atom(App) ]};

expand_anchor(AppPaths, [ "{*}" | Rest ], FilePart) ->
	{many, [ filename:join([ Path | Rest]) || {App, Path} <- AppPaths, is_atom(App) ], FilePart};

expand_anchor(AppPaths, PathList, undefined) ->
	RootDir = find_app_path("Root", AppPaths),
	{file, filename:join([ RootDir | PathList])};

expand_anchor(AppPaths, PathList, FilePart) ->
	RootDir = find_app_path("Root", AppPaths),
	{many, [filename:join([ RootDir | PathList])], FilePart}.



has_wildcards(Path) ->
	lists:any(
	  	fun	(X) when X =:= $*; X =:= $?; X =:= $[; X =:= ${ -> true
		;	(_) -> false
		end, Path).



find_app_path(App, []) -> throw(?PRV_ERROR({bad_name, App}));
find_app_path(App, [{App, _, Path} | _]) -> Path;
find_app_path(App, [_ | Rest]) -> find_app_path(App, Rest).

find_lib_path(App, []) -> throw(?PRV_ERROR({bad_name, App}));
find_lib_path(App, [{App, Path, _} | _]) -> Path;
find_lib_path(App, [_ | Rest]) -> find_lib_path(App, Rest).


guess_type(Path) ->
	case ( lists:last(Path) =:= $/ ) of
		true	-> dir
	;	false	-> file_or_dir
	end.


                
%%%%% ------------------------------------------------------- %%%%%
  


gather_many_files(AppPaths, Dir, Wildcards) ->
    [ gather_app_files(App, Path, Dir, Wildcards) || {App, Path, _} <- AppPaths, is_atom(App) ].


get_app_paths([], _, Acc) ->
    Acc;
    
get_app_paths([App | Rest], AllApps, Acc) ->    
    case rebar_app_utils:find(ec_cnv:to_binary(App), AllApps) of
        {ok, App1}  ->
            LibDir = filename:absname(rebar_app_info:out_dir(App1)),
            BaseDir = filename:absname(rebar_app_info:dir(App1)),
            get_app_paths(Rest, AllApps, [{App, LibDir, BaseDir} | Acc])
            
    ;   _           ->
            case code:lib_dir(App) of
                {error, bad_name}   -> throw(?PRV_ERROR({bad_name, App}))
            ;   Path                ->
					get_app_paths(Rest, AllApps, [{App, Path, undefined} | Acc])
            end
    end.



-spec gather_app_files(atom(), string(), atom() | string(), string() ) -> list().

gather_app_files(App, Path, Dir, Wildcards) ->
    FromDir = filename:join(Path, Dir),
    ToDir = filename:join(App, Dir),
    [ match_files(FromDir, W, ToDir) || W <- Wildcards ].
    

%%%%% ------------------------------------------------------- %%%%%
 
 
match_files(Dir, "*", Prefix) ->
    Dirlen = length(Dir) + 1,
    AllFiles = filelib:fold_files(Dir, "", true,
        fun(F, Acc) ->
            [ lists:nthtail(Dirlen, F) | Acc ]
        end,
        []),
    debug_match(Dir, "*", [ read_file(Dir, Filename, Prefix) || Filename <- AllFiles ]);
    
match_files(Dir, Wildcard, Prefix) ->
    debug_match(Dir, Wildcard
			   , [ read_file(Dir, Filename, Prefix)
				   || Filename <- filelib:wildcard(Wildcard, Dir) ] ).


debug_match(Dir, Wildcard, X) ->
    DebugFiles = [ Name || {Name, _} <- usort(X) ],
    rebar_api:debug("Matches ~s/~s~n     ~p", [ Dir, Wildcard, DebugFiles ]),
    X.    



%%%%% ------------------------------------------------------- %%%%%


pathjoin("", Y) -> Y;
pathjoin(X, Y) -> filename:join([X, Y]).
	

read_many_files(FromFiles, ToPrefix) ->	
	[ read_file( filename:dirname(X)
			   , filename:basename(X)
			   , ToPrefix )
        || X <- FromFiles ].
	

read_file(FromDir, Filename, ToPrefix) ->
	read_file(FromDir, Filename, ToPrefix, Filename).


read_file(FromDir, FromFilename, ToPrefix, ToFilename) ->
    InFilePath = filename:join(FromDir, FromFilename),
	OutFilePath = pathjoin(ToPrefix, ToFilename),
	read_file(InFilePath, OutFilePath).


read_file(FromFile, ToFile) ->
    case filelib:is_regular(FromFile) of
        true    ->
            [ dir_entries(filename:dirname(ToFile))
            , {ToFile, file_contents(FromFile)}
            ]
    ;   false   -> []
    end.


file_contents(Filename) ->
    {ok, Bin} = file:read_file(Filename),
    Bin.


    
%% Given a filename, return zip archive dir entries for each sub-dir.
%% Required to work around issues fixed in OTP-10071.
dir_entries(File) ->
    Dirs = dirs(File),
    [{Dir ++ "/", <<>>} || Dir <- Dirs].

%% Given "foo/bar/baz", return ["foo", "foo/bar", "foo/bar/baz"].
dirs(Dir) ->
    dirs1(filename:split(Dir), "", []).

dirs1([], _, Acc) ->
    lists:reverse(Acc);
dirs1([H|T], "", []) ->
    dirs1(T, H, [H]);
dirs1([H|T], Last, Acc) ->
    Dir = filename:join(Last, H),
    dirs1(T, Dir, [Dir|Acc]).

usort(List) ->
    lists:ukeysort(1, lists:flatten(List)).

get_nonempty(Files) ->
    [{FName,FBin} || {FName,FBin} <- Files, FBin =/= <<>>].

find_deps(AppNames, AllApps) ->
    BinAppNames = [ec_cnv:to_binary(Name) || Name <- AppNames],
    [ec_cnv:to_atom(Name) ||
     Name <- find_deps_of_deps(BinAppNames, AllApps, BinAppNames)].

%% Should look at the app files to find direct dependencies
find_deps_of_deps([], _, Acc) -> Acc;
find_deps_of_deps([Name|Names], Apps, Acc) ->
    rebar_api:debug("processing ~p", [Name]),
    {ok, App} = rebar_app_utils:find(Name, Apps),
    DepNames = proplists:get_value(applications, rebar_app_info:app_details(App), []),
    BinDepNames = [ec_cnv:to_binary(Dep) || Dep <- DepNames,
                   %% ignore system libs; shouldn't include them.
                   DepDir <- [code:lib_dir(Dep)],
                   DepDir =:= {error, bad_name} orelse % those are all local
                   not lists:prefix(code:root_dir(), DepDir)]
                -- ([Name|Names]++Acc), % avoid already seen deps
    rebar_api:debug("new deps of ~p found to be ~p", [Name, BinDepNames]),
    find_deps_of_deps(BinDepNames ++ Names, Apps, BinDepNames ++ Acc).

def(Rm, State, Key, Default) ->
    Value0 = rebar_state:get(State, Key, Default),
    case Rm of
        "#!"  -> "#!"  ++ Value = Value0, rm_newline(Value);
        "%%"  -> "%%"  ++ Value = Value0, rm_newline(Value);
        "%%!" -> "%%!" ++ Value = Value0, rm_newline(Value)
    end.

rm_newline(String) ->
    [C || C <- String, C =/= $\n].
