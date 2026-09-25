%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later

-module(packbeam_function_prune_tests).
-include_lib("eunit/include/eunit.hrl").

basic_test() ->
    B = fixture(
        pf_basic,
        "-export([start/0,dead/0]). start()->live(3). live(X)->{ok,X}. dead()->[dead_literal,123456789]."
    ),
    {Out, Report} = packbeam_prune:run([B], [], [{pf_basic, start, 0}], #{}),
    [New] = Out,
    ?assertEqual([], maps:get(warnings, Report)),
    ?assertEqual([{start, 0}], exports(New)),
    ?assert(byte_size(New) < byte_size(B)),
    ?assertEqual({ok, 3}, execute(pf_basic, New, start, [])),
    ?assertEqual(nomatch, binary:match(literals(New), <<"dead_literal">>)).

reference_test() ->
    A = fixture(
        pf_app,
        "-export([start/0,callback/0,dead/0]). start()->pf_lib:run(). callback()->42. dead()->bad."
    ),
    L = fixture(pf_lib, "-export([run/0,dead/0]). run()->pf_app:callback(). dead()->unused."),
    {[New], _} = packbeam_prune:run([A], [L], [{pf_app, start, 0}], #{}),
    ?assertEqual([{callback, 0}, {start, 0}], exports(New)),
    {Bundled, _} = packbeam_prune:run([A, L], [], [{pf_app, start, 0}], #{}),
    ?assertEqual(2, length(Bundled)),
    ?assertEqual([{run, 0}], exports(lists:nth(2, Bundled))).

known_module_dynamic_function_test() ->
    A = fixture(
        pf_dynamic,
        "-export([start/0]). start()->F=list_to_atom(erlang:atom_to_list(erlang:get(key))),pf_target:F()."
    ),
    T = fixture(pf_target, "-export([one/0,two/0]). one()->1. two()->2."),
    U = fixture(pf_unused, "-export([dead/0]). dead()->dead."),
    {Out, R} = packbeam_prune:run([A, T, U], [], [{pf_dynamic, start, 0}], #{}),
    ?assertEqual(2, length(Out)),
    ?assert(lists:any(fun(#{scope := S}) -> S =:= {module, pf_target} end, maps:get(warnings, R))).

%% An unbounded dispatch retains the exports of the modules the analyzed code
%% names. A module whose name only ever comes from runtime data -- here a term
%% decoded at run time -- is not discovered, and is trimmed.
unknown_module_test() ->
    A = fixture(
        pf_unknown,
        "-export([start/0]). start()->M=binary_to_term(erlang:get(key)),F=erlang:get(function),M:F()."
    ),
    T = fixture(pf_target, "-export([one/0,two/0]). one()->1. two()->2."),
    {[Only], R} = packbeam_prune:run([A, T], [], [{pf_unknown, start, 0}], #{}),
    ?assertEqual([{start, 0}], exports(Only)),
    ?assert(lists:any(fun(#{scope := S}) -> S =:= named_modules end, maps:get(warnings, R))),
    %% Naming the module and the function keeps that entry point; the other
    %% export, whose name the code never produces, still goes.
    Named = fixture(
        pf_named,
        "-export([start/0]). start()->erlang:put(k,{pf_target,one}),M=binary_to_term(erlang:get(key)),F=erlang:get(function),M:F()."
    ),
    {[_, Kept], _} = packbeam_prune:run([Named, T], [], [{pf_named, start, 0}], #{}),
    ?assertEqual([{one, 0}], exports(Kept)).

%% A fun built from runtime data (erl_parse:normalise/1 builds `fun M:F/A'
%% from a parse tree) can only name a module the code names: like an apply
%% with an unknown module, it keeps those, not the whole package.
unknown_make_fun_test() ->
    A = fixture(
        pf_make_fun,
        "-export([start/0]). start()->{M,F,Ar}=binary_to_term(erlang:get(key)),erlang:make_fun(M,F,Ar)."
    ),
    T = fixture(pf_target, "-export([one/0,two/0]). one()->1. two()->2."),
    {Out, R} = packbeam_prune:run([A, T], [], [{pf_make_fun, start, 0}], #{}),
    ?assertEqual(1, length(Out)),
    ?assert(lists:any(fun(#{scope := S}) -> S =:= named_modules end, maps:get(warnings, R))).

%% A module retained whole for an unknown dispatch is kept without being
%% analyzed: what its functions call must be kept too, even when the callee's
%% name is not an atom the code can produce.
named_module_callees_test() ->
    A = fixture(
        pf_named_app,
        "-export([start/0]). start()->erlang:put(k,{pf_named_x,f}),M=binary_to_term(erlang:get(key)),F=erlang:get(function),M:F()."
    ),
    X = fixture(pf_named_x, "-export([f/0]). f()->pf_named_y:g()."),
    Y = fixture(pf_named_y, "-export([g/0,h/0]). g()->ok. h()->dead."),
    {Out, _} = packbeam_prune:run([A, X, Y], [], [{pf_named_app, start, 0}], #{}),
    ?assertEqual(3, length(Out)),
    ?assertEqual([{g, 0}], exports(lists:nth(3, Out))).

%% A retained module names the next one in its literals too, as a child spec
%% does: `{code_server, start_link, []}'.
named_module_literal_test() ->
    A = fixture(
        pf_named_app,
        "-export([start/0]). start()->erlang:put(k,{pf_named_x,f}),M=binary_to_term(erlang:get(key)),F=erlang:get(function),M:F()."
    ),
    X = fixture(
        pf_named_x,
        "-export([f/0]). f()->[M,F]=persistent_term:get(k,[pf_named_z,go]),M:F()."
    ),
    Z = fixture(pf_named_z, "-export([go/0]). go()->ok."),
    {Out, _} = packbeam_prune:run([A, X, Z], [], [{pf_named_app, start, 0}], #{}),
    ?assertEqual(3, length(Out)).

%% A function kept without being analyzed may call an analyzed one with
%% arguments the analysis never saw: the callee's branches for them, and what
%% they call, stay.
named_module_caller_arguments_test() ->
    A = fixture(
        pf_named_app,
        "-export([start/0]). start()->pf_named_y:g(ok),erlang:put(k,{pf_named_x,f}),M=binary_to_term(erlang:get(key)),F=erlang:get(function),M:F()."
    ),
    X = fixture(pf_named_x, "-export([f/0]). f()->pf_named_y:g(erlang:get(z))."),
    Y = fixture(
        pf_named_y,
        "-export([g/1]). g(ok)->one; g(_)->other(). other()->two."
    ),
    {Out, _} = packbeam_prune:run([A, X, Y], [], [{pf_named_app, start, 0}], #{}),
    ?assertEqual(3, length(Out)),
    ?assertEqual(two, execute(pf_named_y, lists:nth(3, Out), g, [other])).

closure_test() ->
    B = fixture(
        pf_fun,
        "-export([start/0,dead/0]). start()->F=make(7),F(5). make(X)->fun(Y)->X+Y end. dead()->fun()->unused end."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_fun, start, 0}], #{}),
    ?assertEqual(12, execute(pf_fun, New, start, [])),
    ?assertEqual([{start, 0}], exports(New)).

branches_test() ->
    B = fixture(
        pf_branches,
        "-export([start/0,choose/1,dead/0]). start()->choose(erlang:get(key)). choose(a)->one(); choose(b)->two(); choose(_)->other(). one()->{one,[1,2,3]}. two()->{two,<<1,2,3>>}. other()->other. dead()->dead."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_branches, start, 0}], #{}),
    ?assertEqual({one, [1, 2, 3]}, execute(pf_branches, New, choose, [a])),
    ?assertEqual({two, <<1, 2, 3>>}, execute(pf_branches, New, choose, [b])),
    ?assertEqual(other, execute(pf_branches, New, choose, [c])).

constant_return_test() ->
    A = fixture(pf_return, "-export([start/0]). start()->M=module(),M:run(). module()->pf_target."),
    T = fixture(pf_target, "-export([run/0,dead/0]). run()->ok. dead()->dead."),
    {Out, R} = packbeam_prune:run([A, T], [], [{pf_return, start, 0}], #{}),
    ?assertEqual([], maps:get(warnings, R)),
    ?assertEqual([{run, 0}], exports(lists:nth(2, Out))).

on_load_test() ->
    B = fixture(
        pf_load,
        "-on_load(setup/0). -export([start/0,dead/0]). setup()->persistent_term:put(pf_load,loaded),ok. start()->persistent_term:get(pf_load). dead()->dead."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_load, start, 0}], #{}),
    ?assertEqual(loaded, execute(pf_load, New, start, [])),
    persistent_term:erase(pf_load).

archive_test() ->
    Dir = "_build/prune_archive_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(pf_app, "-export([start/0,dead/0]). start()->pf_lib:run(). dead()->bad."),
    L = fixture(pf_lib, "-export([run/0,dead/0]). run()->ok. dead()->unused."),
    ok = file:write_file(Dir ++ "pf_app.beam", A),
    ok = file:write_file(Dir ++ "pf_lib.beam", L),
    Init = fixture(init, "-export([boot/1]). boot([_,M])->M:start()."),
    ok = file:write_file(Dir ++ "init.beam", Init),
    ok = packbeam_api:create(Dir ++ "lib.avm", [Dir ++ "pf_lib.beam", Dir ++ "init.beam"], #{
        lib => true
    }),
    {ok, Before} = file:read_file(Dir ++ "lib.avm"),
    ok = packbeam_api:create(Dir ++ "out.avm", [Dir ++ "pf_app.beam"], #{
        prune => functions, references => [Dir ++ "lib.avm"]
    }),
    [Only] = packbeam_api:list(Dir ++ "out.avm"),
    ?assertEqual(pf_app, packbeam_api:get_element_module(Only)),
    ?assertEqual([{start, 0}], exports(packbeam_api:get_element_data(Only))),
    ?assertEqual({ok, Before}, file:read_file(Dir ++ "lib.avm")),
    ok = packbeam_api:create(Dir ++ "out.avm", [Dir ++ "pf_app.beam", Dir ++ "lib.avm"], #{
        prune => functions
    }),
    [_, Lib, _Init] = packbeam_api:list(Dir ++ "out.avm"),
    ?assertEqual([{run, 0}], exports(packbeam_api:get_element_data(Lib))),
    ?assertError(
        {duplicate_module, pf_lib},
        packbeam_api:create(Dir ++ "out.avm", [Dir ++ "pf_app.beam", Dir ++ "lib.avm"], #{
            prune => functions, references => [Dir ++ "lib.avm"]
        })
    ).

%% ExAtomVM marks the start module with the start flag alone. AtomVM loads it
%% as a module all the same, so pruning must analyze it: otherwise what it
%% calls is dropped.
start_flag_only_entry_test() ->
    Dir = "_build/prune_start_flag_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(pf_app, "-export([start/0,dead/0]). start()->pf_lib:run(). dead()->bad."),
    L = fixture(pf_lib, "-export([run/0,dead/0]). run()->ok. dead()->unused."),
    Init = fixture(init, "-export([boot/1]). boot([_,M])->M:start()."),
    ok = file:write_file(Dir ++ "pf_app.beam", A),
    ok = file:write_file(Dir ++ "pf_lib.beam", L),
    ok = file:write_file(Dir ++ "init.beam", Init),
    ok = packbeam_api:create(Dir ++ "app.avm", [Dir ++ "pf_app.beam"]),
    %% The first entry follows the 24-byte header: size, then flags.
    {ok, <<Header:24/binary, Size:32, 3:32, Rest/binary>>} = file:read_file(Dir ++ "app.avm"),
    ok = file:write_file(Dir ++ "app.avm", <<Header/binary, Size:32, 1:32, Rest/binary>>),
    ok = packbeam_api:create(Dir ++ "lib.avm", [Dir ++ "pf_lib.beam", Dir ++ "init.beam"], #{
        lib => true
    }),
    ok = packbeam_api:create(Dir ++ "out.avm", [Dir ++ "app.avm", Dir ++ "lib.avm"], #{
        prune => functions
    }),
    Out = maps:from_list([
        {packbeam_api:get_element_module(E), packbeam_api:get_element_data(E)}
     || E <- packbeam_api:list(Dir ++ "out.avm")
    ]),
    ?assertEqual([{start, 0}], exports(maps:get(pf_app, Out))),
    ?assertEqual([{run, 0}], exports(maps:get(pf_lib, Out))).

%% An AVM appended to the AtomVM executable boots init with the escript
%% arguments, and init calls the start module's main/1.
escript_entry_test() ->
    Dir = "_build/prune_escript_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(
        pf_esc, "-export([start/0,main/1,dead/0]). start()->ok. main(_)->pf_lib:run(). dead()->bad."
    ),
    L = fixture(pf_lib, "-export([run/0,dead/0]). run()->ok. dead()->unused."),
    Init = fixture(
        init,
        "-export([boot/1]).\n"
        "boot([<<\"-s\">>, escript, <<\"--\">>, _File | Args]) ->\n"
        "    case atomvm:get_start_beam(escript) of\n"
        "        {ok, B} ->\n"
        "            Size = byte_size(B),\n"
        "            Name = if Size > 5 -> case binary:part(B, Size - 5, 5) of\n"
        "                    <<\".beam\">> -> binary:part(B, 0, Size - 5); _ -> B end;\n"
        "                true -> B end,\n"
        "            M = binary_to_atom(Name, utf8),\n"
        "            case erlang:function_exported(M, main, 1) of\n"
        "                true -> M:main(Args);\n"
        "                false -> error\n"
        "            end;\n"
        "        _ -> error\n"
        "    end;\n"
        "boot([<<\"-s\">>, M]) -> M:start()."
    ),
    Atomvm = fixture(
        atomvm, "-export([get_start_beam/1]). get_start_beam(_) -> erlang:nif_error(undefined)."
    ),
    Binary = fixture(binary, "-export([part/3]). part(_, _, _) -> erlang:nif_error(undefined)."),
    ok = file:write_file(Dir ++ "pf_esc.beam", A),
    ok = file:write_file(Dir ++ "pf_lib.beam", L),
    ok = file:write_file(Dir ++ "init.beam", Init),
    ok = file:write_file(Dir ++ "atomvm.beam", Atomvm),
    ok = file:write_file(Dir ++ "binary.beam", Binary),
    Beams = [Dir ++ M ++ ".beam" || M <- ["pf_esc", "pf_lib", "init", "atomvm", "binary"]],
    ok = packbeam_api:create(Dir ++ "out.avm", Beams, #{
        prune => functions,
        diagnostics => fun(R) -> self() ! {warnings, maps:get(warnings, R)} end
    }),
    Out = maps:from_list([
        {packbeam_api:get_element_module(E), packbeam_api:get_element_data(E)}
     || E <- packbeam_api:list(Dir ++ "out.avm")
    ]),
    ?assertEqual([{main, 1}, {start, 0}], lists:sort(exports(maps:get(pf_esc, Out)))),
    ?assertEqual([{run, 0}], exports(maps:get(pf_lib, Out))),
    receive
        {warnings, Warnings} -> ?assertEqual([], Warnings)
    end.

%% AtomVM loads the first entry of a module's name: later copies are shadowed
%% and never run, so they are neither analyzed nor kept.
shadowed_module_test() ->
    Dir = "_build/prune_shadowed_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(pf_app, "-export([start/0]). start()->pf_dup:run()."),
    First = fixture(pf_dup, "-export([run/0]). run()->pf_left:run()."),
    Second = fixture(pf_dup, "-export([run/0]). run()->pf_right:run()."),
    Left = fixture(pf_left, "-export([run/0]). run()->left."),
    Right = fixture(pf_right, "-export([run/0]). run()->right."),
    Init = fixture(init, "-export([boot/1]). boot([_,M])->M:start()."),
    ok = file:write_file(Dir ++ "pf_app.beam", A),
    ok = file:write_file(Dir ++ "pf_left.beam", Left),
    ok = file:write_file(Dir ++ "pf_right.beam", Right),
    ok = file:write_file(Dir ++ "init.beam", Init),
    ok = filelib:ensure_dir(Dir ++ "first/x"),
    ok = filelib:ensure_dir(Dir ++ "second/x"),
    ok = file:write_file(Dir ++ "first/pf_dup.beam", First),
    ok = file:write_file(Dir ++ "second/pf_dup.beam", Second),
    Beams = [
        Dir ++ P
     || P <- [
            "pf_app.beam",
            "first/pf_dup.beam",
            "second/pf_dup.beam",
            "pf_left.beam",
            "pf_right.beam",
            "init.beam"
        ]
    ],
    ok = packbeam_api:create(Dir ++ "out.avm", Beams, #{prune => functions}),
    Out = [
        {packbeam_api:get_element_module(E), packbeam_api:get_element_data(E)}
     || E <- packbeam_api:list(Dir ++ "out.avm")
    ],
    ?assertEqual([init, pf_app, pf_dup, pf_left], lists:sort([M || {M, _} <- Out])).

%% The start module's name reaches the analysis only through init's seed
%% arguments: analyzed as any value, it must still count as an atom the
%% program knows, or the call on it finds no target.
coarse_start_module_test() ->
    Dir = "_build/prune_coarse_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(pf_app, "-export([start/0,dead/0]). start()->pf_lib:run(). dead()->bad."),
    L = fixture(pf_lib, "-export([run/0,dead/0]). run()->ok. dead()->unused."),
    Init = fixture(init, "-export([boot/1]). boot([_,M])->M:start()."),
    ok = file:write_file(Dir ++ "pf_app.beam", A),
    ok = file:write_file(Dir ++ "pf_lib.beam", L),
    ok = file:write_file(Dir ++ "init.beam", Init),
    ok = packbeam_api:create(
        Dir ++ "out.avm",
        [Dir ++ "pf_app.beam", Dir ++ "pf_lib.beam", Dir ++ "init.beam"],
        #{prune => functions, precision => coarse, diagnostics => fun(_) -> ok end}
    ),
    Out = maps:from_list([
        {packbeam_api:get_element_module(E), packbeam_api:get_element_data(E)}
     || E <- packbeam_api:list(Dir ++ "out.avm")
    ]),
    ?assertEqual([{start, 0}], exports(maps:get(pf_app, Out))),
    ?assertEqual([{run, 0}], exports(maps:get(pf_lib, Out))).

init_entry_test() ->
    Dir = "_build/prune_init_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    B = fixture(init, "-export([boot/1,start/0]). boot(_)->ok. start()->unused."),
    ok = file:write_file(Dir ++ "init.beam", B),
    ok = packbeam_api:create(Dir ++ "out.avm", [Dir ++ "init.beam"], #{
        prune => functions
    }),
    [P] = packbeam_api:list(Dir ++ "out.avm"),
    ?assertEqual([{boot, 1}], exports(packbeam_api:get_element_data(P))).

driver_test() ->
    B = fixture(
        pf_driver,
        "-export([start/0,dead/0]). start()->open_port({spawn,\"gpio\"},[]). dead()->open_port({spawn,\"uart\"},[])."
    ),
    {_, R} = packbeam_prune:run([B], [], [{pf_driver, start, 0}], #{}),
    ?assertEqual(["gpio"], maps:get(drivers, R)),
    Suggestions = lists:flatten(packbeam_prune:driver_suggestions(R)),
    ?assertEqual(nomatch, string:find(Suggestions, "GPIO_PORT_DRIVER")),
    ?assertNotEqual(nomatch, string:find(Suggestions, "UART")),
    U = fixture(
        pf_driver_unknown, "-export([start/0]). start()->open_port(erlang:get(driver),[])."
    ),
    {_, UR} = packbeam_prune:run([U], [], [{pf_driver_unknown, start, 0}], #{}),
    ?assertEqual([], packbeam_prune:driver_suggestions(UR)).

finite_modules_test() ->
    A = fixture(
        pf_finite,
        "-export([start/0]). start()->M=case erlang:get(key) of a->pf_left;_->pf_right end,M:run()."
    ),
    L = fixture(pf_left, "-export([run/0,dead/0]). run()->left. dead()->dead."),
    R = fixture(pf_right, "-export([run/0,dead/0]). run()->right. dead()->dead."),
    {Out, Report} = packbeam_prune:run([A, L, R], [], [{pf_finite, start, 0}], #{}),
    ?assertEqual([], maps:get(warnings, Report)),
    ?assertEqual([[{start, 0}], [{run, 0}], [{run, 0}]], [exports(B) || B <- Out]).

%% A library that was not supplied cannot be called at all, so its absence is
%% reported instead of silently keeping every function of the output.
missing_library_test() ->
    A = fixture(
        pf_missing, "-export([start/0,callback/0]). start()->missing_lib:run(). callback()->ok."
    ),
    {[New], R} = packbeam_prune:run([A], [], [{pf_missing, start, 0}], #{}),
    ?assertEqual([{start, 0}], exports(New)),
    ?assertEqual(
        [{absent, missing_lib}], [Scope || #{scope := Scope} <- maps:get(warnings, R)]
    ),
    %% Nothing reachable opens a port, so the advice covers every driver.
    ?assertNotEqual([], packbeam_prune:driver_suggestions(R)).

%% Without init, the package runs next to an AtomVM library installed on the
%% device, which packbeam cannot see: a call into it returns, and may run the
%% closures and callback modules it is given, or send messages.
device_library_test() ->
    Dir = "_build/prune_device_library_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    A = fixture(
        pf_app,
        "-export([start/0,dead/0]).\n"
        "start()->R=pf_device:run(fun(X)->{cb,X} end,pf_callback),{done,R,listen()}.\n"
        "listen()->pf_device:subscribe(self()),receive {'$gen_cast',X}->{event,X} end.\n"
        "dead()->bad."
    ),
    C = fixture(
        pf_callback, "-export([handle/1,other/0]). handle(X)->{handled,X}. other()->other."
    ),
    U = fixture(pf_unused, "-export([dead/0]). dead()->dead."),
    Device = fixture(
        pf_device,
        "-export([run/2,subscribe/1]). run(F,M)->{F(1),M:handle(2)}. subscribe(P)->P!{'$gen_cast',7}."
    ),
    ok = file:write_file(Dir ++ "pf_app.beam", A),
    ok = file:write_file(Dir ++ "pf_callback.beam", C),
    ok = file:write_file(Dir ++ "pf_unused.beam", U),
    Beams = [Dir ++ M ++ ".beam" || M <- ["pf_app", "pf_callback", "pf_unused"]],
    Self = self(),
    lists:foreach(
        fun(Options) ->
            ok = packbeam_api:create(
                Dir ++ "out.avm",
                Beams,
                Options#{diagnostics => fun(R) -> Self ! {warnings, maps:get(warnings, R)} end}
            ),
            Out = maps:from_list([
                {packbeam_api:get_element_module(E), packbeam_api:get_element_data(E)}
             || E <- packbeam_api:list(Dir ++ "out.avm")
            ]),
            ?assertEqual([pf_app, pf_callback], lists:sort(maps:keys(Out))),
            ?assertEqual([{start, 0}], exports(maps:get(pf_app, Out))),
            ?assertEqual(
                [{handle, 1}, {module_info, 0}, {module_info, 1}, {other, 0}],
                exports(maps:get(pf_callback, Out))
            ),
            receive
                {warnings, Warnings} ->
                    ?assertEqual(
                        [{module, pf_callback}, {unanalyzed, pf_device}],
                        lists:usort([S || #{scope := S} <- Warnings])
                    )
            end,
            Loaded = [{pf_device, Device} | maps:to_list(Out)],
            [{module, M} = code:load_binary(M, "pruned.beam", B) || {M, B} <- Loaded],
            try
                ?assertEqual({done, {{cb, 1}, {handled, 2}}, {event, 7}}, pf_app:start())
            after
                [code:delete(M) andalso code:purge(M) || {M, _} <- Loaded]
            end
        end,
        [
            %% What orbital passes for Gleam projects.
            #{prune => true, lib => false, start_module => pf_app},
            #{prune => functions, lib => true, keep => [{pf_app, start, 0}]}
        ]
    ).

spawn_test() ->
    B = fixture(
        pf_spawn,
        "-export([start/0,worker/0,dead/0]). start()->spawn(pf_spawn,worker,[]). worker()->ok. dead()->dead."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_spawn, start, 0}], #{}),
    ?assertEqual([{start, 0}, {worker, 0}], exports(New)).

literal_fun_test() ->
    A = fixture(pf_fun_ref, "-export([start/0]). start()->fun pf_target:run/0."),
    T = fixture(pf_target, "-export([run/0,dead/0]). run()->ok. dead()->dead."),
    {Out, _} = packbeam_prune:run([A, T], [], [{pf_fun_ref, start, 0}], #{}),
    ?assertEqual(2, length(Out)),
    ?assertEqual([{run, 0}], exports(lists:nth(2, Out))).

large_labels_test() ->
    Dead = [io_lib:format("f~p()->{dead,~p}. ", [I, I]) || I <- lists:seq(1, 1050)],
    B = fixture(
        pf_large,
        lists:flatten([
            "-compile(export_all). ",
            Dead,
            "start()->f1051(). f1051()->-123456789012345678901234567890."
        ])
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_large, start, 0}], #{}),
    ?assertEqual(-123456789012345678901234567890, execute(pf_large, New, start, [])),
    ?assertEqual([{f1051, 0}, {start, 0}], exports(New)).

reference_erlang_spawn_test() ->
    B = fixture(
        pf_spawn_ref,
        "-export([start/0,worker/0,dead/0]). start()->spawn(pf_spawn_ref,worker,[]). worker()->ok. dead()->dead."
    ),
    E = fixture(erlang, "-export([spawn/3]). spawn(_,_,_)->erlang:nif_error(undefined)."),
    {[New], _} = packbeam_prune:run([B], [E], [{pf_spawn_ref, start, 0}], #{}),
    ?assertEqual([{start, 0}, {worker, 0}], exports(New)).

remote_spawn_test() ->
    B = fixture(
        pf_remote,
        "-export([start/0,worker/0,dead/0]). start()->spawn('remote@host',pf_remote,worker,[]). worker()->ok. dead()->dead."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_remote, start, 0}], #{}),
    ?assertEqual([{start, 0}, {worker, 0}], exports(New)).

%% OTP 29 native records name their atoms and default values by index, so
%% the definitions follow the tables when trimming renumbers them.
native_records_test_() ->
    case list_to_integer(erlang:system_info(otp_release)) >= 29 of
        true -> [fun native_records/0];
        false -> []
    end.
native_records() ->
    B = fixture(
        pf_records,
        "-export([dead/0,start/0]). -record #point{x, y = {origin, [1, 2]}}. "
        "dead()->{unused_a, unused_b, [3, 4, 5]}. "
        "start()->P = #point{x = 1}, {P#point.x, P#point.y}."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_records, start, 0}], #{}),
    ?assertEqual([{start, 0}], exports(New)),
    ?assertEqual({1, {origin, [1, 2]}}, execute(pf_records, New, start, [])).

compressed_and_litu_test() ->
    B = fixture(
        pf_literals,
        "-export([start/0,dead/0]). start()->{keep,[1,2,3]}. dead()->{discard,<<0:800>>}."
    ),
    {ok, _, Cs} = beam_lib:all_chunks(B),
    D = literals(B),
    Variants = [{"LitT", <<(byte_size(D)):32, (zlib:compress(D))/binary>>}, {"LitU", D}],
    lists:foreach(
        fun(Chunk) ->
            {ok, Input} = beam_lib:build_module([Chunk | lists:keydelete("LitT", 1, Cs)]),
            {[New], _} = packbeam_prune:run([Input], [], [{pf_literals, start, 0}], #{}),
            ?assertEqual({keep, [1, 2, 3]}, execute(pf_literals, New, start, [])),
            ?assertEqual(nomatch, binary:match(literals(New), <<"discard">>))
        end,
        Variants
    ).

keep_and_resources_test() ->
    Dir = "_build/prune_keep_test/",
    ok = filelib:ensure_dir(Dir ++ "x"),
    B = fixture(pf_keep, "-export([callback/0,dead/0]). callback()->ok. dead()->dead."),
    ok = file:write_file(Dir ++ "pf_keep.beam", B),
    ok = file:write_file(Dir ++ "asset.txt", <<"asset">>),
    ?assertError(
        no_pruning_roots,
        packbeam_api:create(Dir ++ "out.avm", [Dir ++ "pf_keep.beam"], #{
            lib => true, prune => functions
        })
    ),
    Self = self(),
    ok = packbeam_api:create(
        Dir ++ "out.avm",
        [Dir ++ "pf_keep.beam", Dir ++ "asset.txt"],
        #{
            lib => true,
            prune => functions,
            keep => [{pf_keep, callback, 0}],
            diagnostics => fun(R) -> Self ! {report, R} end
        }
    ),
    [P, Asset] = packbeam_api:list(Dir ++ "out.avm"),
    ?assertEqual([{callback, 0}], exports(packbeam_api:get_element_data(P))),
    ?assertEqual(false, packbeam_api:is_entrypoint(P)),
    ?assertEqual(false, packbeam_api:is_beam(Asset)),
    receive
        {report, Report} -> ?assertEqual([{pf_keep, callback, 0}], maps:get(reachable, Report))
    after 1000 -> error(no_report)
    end,
    ?assertError(
        {missing_root, {pf_keep, missing, 0}},
        packbeam_prune:run([B], [], [{pf_keep, missing, 0}], #{})
    ).

structured_arguments_test() ->
    A = fixture(
        pf_structure,
        "-export([start/0]). start()->dispatch({erlang:get(key),pf_target}),spawn(pf_receiver,run,[self(),pf_target]). dispatch(T)->M=element(2,T),M:run()."
    ),
    R = fixture(pf_receiver, "-export([run/2,dead/0]). run(P,M)->P!M:run(). dead()->dead."),
    T = fixture(pf_target, "-export([run/0,dead/0]). run()->ok. dead()->dead."),
    {Out, Report} = packbeam_prune:run([A, R, T], [], [{pf_structure, start, 0}], #{}),
    ?assertEqual([], maps:get(warnings, Report)),
    ?assertEqual([[{start, 0}], [{run, 2}], [{run, 0}]], [exports(B) || B <- Out]).

structured_map_test() ->
    A = fixture(
        pf_map,
        "-export([start/0]). start()->dispatch(#{module=>pf_target,value=>erlang:get(key)}). dispatch(T)->M=maps:get(module,T),M:run()."
    ),
    T = fixture(pf_target, "-export([run/0,dead/0]). run()->ok. dead()->dead."),
    {Out, Report} = packbeam_prune:run([A, T], [], [{pf_map, start, 0}], #{}),
    ?assertEqual([], maps:get(warnings, Report)),
    ?assertEqual([{run, 0}], exports(lists:nth(2, Out))).

closure_register_lifetime_test() ->
    A = fixture(
        pf_lifetime,
        "-export([start/0,dead/0]). start()->F=make(7),case F(pf_sum:sum([1,2,3])) of 13->0;_->1 end. make(X)->fun(Y)->X+Y end. dead()->dead."
    ),
    L = fixture(pf_sum, "-export([sum/1,dead/0]). sum([A,B,C])->A+B+C. dead()->dead."),
    {Out, R} = packbeam_prune:run([A, L], [], [{pf_lifetime, start, 0}], #{}),
    ?assertEqual([], maps:get(warnings, R)),
    ?assertEqual([{start, 0}], exports(hd(Out))).

fun_table_relocation_test() ->
    B = fixture(
        pf_fun_table,
        "-export([dead/1,start/1]). dead(X)->fun()->X end. start(X)->F=make(X),F(5). make(X)->fun(Y)->X+Y end."
    ),
    {[New], _} = packbeam_prune:run([B], [], [{pf_fun_table, start, 1}], #{}),
    ?assertEqual([{start, 1}], exports(New)),
    ?assertMatch({beam_file, pf_fun_table, _, _, _, _}, beam_disasm:file(New)),
    ?assertEqual(12, execute(pf_fun_table, New, start, [7])).

fixture(M, Body) ->
    Source = lists:flatten(io_lib:format("-module(~p). ~s", [M, Body])),
    {ok, Tokens, _} = erl_scan:string(Source),
    Forms = forms(Tokens, [], []),
    case compile:forms(Forms, [binary, return_errors, no_line_info]) of
        {ok, M, B} -> B;
        Other -> error(Other)
    end.
forms([], [], Acc) ->
    lists:reverse(Acc);
forms([{dot, _} = D | T], Cur, Acc) ->
    {ok, F} = erl_parse:parse_form(lists:reverse([D | Cur])),
    forms(T, [], [F | Acc]);
forms([H | T], Cur, Acc) ->
    forms(T, [H | Cur], Acc).
exports(B) ->
    {ok, {_, [{exports, E}]}} = beam_lib:chunks(B, [exports]),
    lists:sort(E).
literals(B) ->
    {ok, _, Cs} = beam_lib:all_chunks(B),
    case proplists:get_value("LitT", Cs) of
        undefined -> proplists:get_value("LitU", Cs, <<>>);
        <<0:32, D/binary>> -> D;
        <<_:32, D/binary>> -> zlib:uncompress(D)
    end.
execute(M, B, F, A) ->
    code:purge(M),
    code:delete(M),
    {module, M} = code:load_binary(M, "pruned.beam", B),
    try
        apply(M, F, A)
    after
        code:delete(M),
        code:purge(M)
    end.
