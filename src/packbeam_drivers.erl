%% Copyright 2026 Paul Guyot <pguyot@kallisys.net>
%% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later

%% AtomVM's NIF collections and port drivers, from packbeam_drivers.hrl.
%% Regenerate that file with scripts/generate_drivers.escript when AtomVM adds
%% a NIF or a build option.
-module(packbeam_drivers).
-export([nifs/0, is_nif/1, suggestions/2]).

-include("packbeam_drivers.hrl").

is_nif(MFA) -> lists:member(MFA, nifs()).
nifs() -> lists:usort(lists:append([MFAs || {_, nifs, _, _, MFAs} <- ?DRIVER_REGISTRATIONS])).

suggestions(Ports, Nifs) ->
    Unused = [
        {{Setting, Kind, Name}, Platform}
     || {Platform, Kind, Name, Setting, MFAs} <- ?DRIVER_REGISTRATIONS,
        Setting =/= none,
        unused(Kind, Name, MFAs, Ports, Nifs)
    ],
    %% Platforms sharing an option share one line.
    Grouped = lists:foldl(
        fun({Key, Platform}, Acc) ->
            case lists:keyfind(Key, 1, Acc) of
                {Key, Platforms} -> lists:keyreplace(Key, 1, Acc, {Key, Platforms ++ [Platform]});
                false -> Acc ++ [{Key, [Platform]}]
            end
        end,
        [],
        Unused
    ),
    [
        io_lib:format("~s: ~s (no reachable ~s ~s)", [
            lists:join("/", Platforms), Setting, Name, what(Kind)
        ])
     || {{Setting, Kind, Name}, Platforms} <- Grouped
    ].

unused(port, Name, _, Ports, _) -> not lists:member(Name, Ports);
unused(nifs, _, MFAs, _, Nifs) -> not lists:any(fun(MFA) -> lists:member(MFA, Nifs) end, MFAs).

what(port) -> "port";
what(nifs) -> "NIFs".
