%% @doc The service contract, asserted locally.
%%
%% hecate_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(hecate_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes hecate_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots hecate_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(hecate_stations_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, hecate_stations).
-define(SERVICE, hecate_stations_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If hecate_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"hecate-stations">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

health_is_green_test() ->
    ?assertEqual(ok, ?SERVICE:health()).

%% This service exists to answer exactly one RPC. An empty list would be
%% the lie now; this pins the shape hecate_om_capabilities destructures
%% (name, version, handler) so a typo in any of the three fails loudly
%% here instead of as a mesh peer's confusing "no such procedure".
announces_list_stations_capability_test() ->
    [#{name := Name, version := Vsn, handler := {Mod, Args}}] = ?SERVICE:capabilities(),
    ?assertEqual(<<"hecate_stations.list_stations">>, Name),
    ?assertEqual(1, Vsn),
    ?assertEqual(list_stations, Mod),
    ?assertEqual([], Args).

identity_spec_has_the_shape_hecate_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% This service publishes and subscribes to no realm-scoped topics --
%% node_record/station_endpoint ingestion reads the mesh-wide DHT (realm
%% 0, protocol-internal), not anything this identity_spec governs. The
%% one capability it serves is authorised by its own signing keypair
%% (hecate_om_identity), not by realm-granted pubsub actions/resources.
%% Asking for neither is still the honest answer, independently of
%% announces_list_stations_capability_test/0 above.
authority_asks_for_no_pubsub_topics_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% The supervisor starts and stops cleanly on its own, without hecate_om.
%% It supervises exactly one worker -- ingest_node_records, the
%% snapshot-then-subscribe DHT consumer -- so this asserts the tree is
%% startable AND that the one child it must have is actually wired in.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = hecate_stations_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    Children = supervisor:which_children(Pid),
    ?assertEqual(1, length(Children)),
    ?assertMatch([{ingest_node_records, ChildPid, worker, [ingest_node_records]}]
                 when is_pid(ChildPid), Children),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile", "FROM docker.io/erlang:([0-9]+)"),
    Ci = pinned(".github/workflows/lint.yml", "image: erlang:([0-9]+)"),
    Running = list_to_binary(erlang:system_info(otp_release)),
    %% Sorted and deduplicated, so a failure prints all three rather than the
    %% first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, Ci, Running])).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [{capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
