%% @doc Drives station_read_model against a real, throwaway barrel_docdb
%% database -- no mesh, no hecate_om:boot/1. `hecate_om_read_model:ensure/2'
%% is documented "services don't call this module directly" (that's
%% `hecate_om:boot/1''s job in production), but it's the exact, idempotent
%% mechanism boot/1 itself uses, and there is no lighter test seam: reading
%% its source was how `station_read_model.erl' was written in the first
%% place, so exercising it for real here is what actually verifies those
%% API assumptions (put_doc's `<<"id">>' semantics, get_doc's `not_found',
%% fold_docs excluding deleted docs by default) rather than just asserting
%% against another guess.
-module(station_read_model_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    %% `erlang:unique_integer/1' is unique only within THIS VM, and
    %% `rebar3 eunit' is a fresh VM per invocation -- an integer-only name
    %% collides with a past run's leftover on-disk directory (never
    %% cleaned up if that run crashed) and reopens ITS docs. Wall-clock
    %% time makes the name unique across runs too.
    DbName = <<"hecate_stations_test_",
              (integer_to_binary(erlang:system_time(microsecond)))/binary, "_",
              (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Dir = filename:join(filename:basedir(user_cache, "hecate-stations-test"),
                        binary_to_list(DbName)),
    ok = filelib:ensure_path(Dir),
    ok = hecate_om_read_model:ensure(DbName, Dir),
    persistent_term:put(hecate_om_read_model_db, DbName),
    {DbName, Dir}.

teardown({DbName, Dir}) ->
    persistent_term:erase(hecate_om_read_model_db),
    ok = barrel_docdb:delete_db(DbName),
    _ = file:del_dir_r(Dir),
    ok.

node_id() -> crypto:strong_rand_bytes(32).

%% `station_read_model:upsert_node_record/1' assumes its one real caller
%% (`ingest_node_records', fed by `macula_record:read_node_record/1')
%% always hands over the complete key set -- every field mandatory,
%% `undefined' for whichever weren't on the wire. `maps:get/2' with no
%% default is how that assumption is enforced: a map missing a key
%% entirely is a malformed caller, not an absent field. This helper
%% mirrors that shape so tests exercise the real contract instead of a
%% partial one `read_node_record/1' would never actually produce.
node_fields(Overrides) ->
    maps:merge(#{
        node_id => undefined, station_id => undefined, realms => [],
        capabilities => undefined, kind => undefined, hostname => undefined,
        endpoint => undefined, city => undefined, country => undefined,
        lat => undefined, lng => undefined, display_name => undefined,
        caps_hint => undefined, peers => undefined
    }, Overrides).

station_read_model_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun upsert_node_record_creates_a_doc/1,
        fun upsert_node_record_omits_undefined_fields/1,
        fun upsert_node_record_derives_continent_from_country/1,
        fun upsert_station_endpoint_merges_onto_existing_node_doc/1,
        fun upsert_node_record_merges_onto_existing_endpoint_doc/1,
        fun retire_node_removes_the_doc_from_fold/1,
        fun retire_node_on_an_unseen_node_is_a_harmless_no_op/1
    ]}.

upsert_node_record_creates_a_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, hostname => <<"h1">>, city => <<"Leuven">>,
        country => <<"BE">>, lat => 50.8798, lng => 4.7005,
        capabilities => 0, kind => <<"station">>})),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(<<"h1">>, maps:get(<<"hostname">>, Doc)),
     ?_assertEqual(<<"Leuven">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(<<"BE">>, maps:get(<<"country">>, Doc)),
     ?_assertEqual(<<"Europe">>, maps:get(<<"continent">>, Doc)),
     ?_assertEqual(50.8798, maps:get(<<"lat">>, Doc))].

upsert_node_record_omits_undefined_fields(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => node_id(), capabilities => 0})),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertNot(maps:is_key(<<"hostname">>, Doc)),
     ?_assertNot(maps:is_key(<<"city">>, Doc)),
     ?_assertNot(maps:is_key(<<"country">>, Doc)),
     ?_assertNot(maps:is_key(<<"continent">>, Doc)),
     ?_assertNot(maps:is_key(<<"lat">>, Doc))].

upsert_node_record_derives_continent_from_country(_DbName) ->
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => node_id(), country => <<"JP">>, capabilities => 0})),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual(<<"Asia">>, maps:get(<<"continent">>, Doc)).

%% A station's node_record and station_endpoint arrive independently and
%% in either order -- this is the case the plan's own design calls out.
upsert_station_endpoint_merges_onto_existing_node_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, city => <<"Falkenstein">>, capabilities => 0})),
    ok = station_read_model:upsert_station_endpoint(
           NodeId, #{quic_port => 4433, host_advertised => [<<"1.2.3.4">>]}),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(<<"Falkenstein">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual([<<"1.2.3.4">>], maps:get(<<"host_advertised">>, Doc))].

upsert_node_record_merges_onto_existing_endpoint_doc(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_station_endpoint(
           NodeId, #{quic_port => 4433, host_advertised => []}),
    ok = station_read_model:upsert_node_record(node_fields(#{
        node_id => NodeId, city => <<"Nuremberg">>, capabilities => 0})),
    {ok, [Doc]} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    [?_assertEqual(4433, maps:get(<<"quic_port">>, Doc)),
     ?_assertEqual(<<"Nuremberg">>, maps:get(<<"city">>, Doc))].

%% Exercises the exact path a graceful shutdown's tombstone drives:
%% ingest_node_records retires by node_id, and the doc must be gone from
%% fold immediately -- not lingering until any TTL.
retire_node_removes_the_doc_from_fold(_DbName) ->
    NodeId = node_id(),
    ok = station_read_model:upsert_node_record(node_fields(#{node_id => NodeId, capabilities => 0})),
    ok = station_read_model:retire_node(NodeId),
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual([], Rows).

retire_node_on_an_unseen_node_is_a_harmless_no_op(_DbName) ->
    ok = station_read_model:retire_node(node_id()),
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    ?_assertEqual([], Rows).
