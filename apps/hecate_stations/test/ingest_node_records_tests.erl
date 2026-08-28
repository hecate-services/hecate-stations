%% @doc Drives ingest_node_records' `handle_info/2' directly against real,
%% signed macula_record values -- no mesh, no macula:subscribe_records/3,
%% just the exact messages try_connect/2's own subscription callbacks send
%% to `self()'. Same throwaway-read-model rationale as
%% station_read_model_tests: this is what actually verifies
%% `macula_record:verify/1' rejection and `read_node_record/1' /
%% `read_tombstone/1' field extraction are wired correctly, not just
%% assumed.
-module(ingest_node_records_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TYPE_NODE_RECORD, 16#01).

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    DbName = <<"hecate_stations_ingest_test_",
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

docs() ->
    {ok, Rows} = station_read_model:fold(fun(D, Acc) -> {ok, [D | Acc]} end, []),
    Rows.

ingest_node_records_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun a_valid_signed_node_record_is_projected/1,
        fun a_tampered_node_record_is_silently_dropped/1,
        fun a_station_endpoint_merges_onto_the_node_doc/1,
        fun a_graceful_shutdown_tombstone_retires_the_station/1,
        fun a_tombstone_for_a_different_superseded_type_is_ignored/1
    ]}.

a_valid_signed_node_record_is_projected(_) ->
    Kp = macula_identity:generate(),
    NodeId = macula_identity:public(Kp),
    Record = macula_record:sign(
               macula_record:node_record(NodeId, [], 0, #{city => <<"Milan">>}), Kp),
    {noreply, state} = ingest_node_records:handle_info({node_record, Record}, state),
    [Doc] = docs(),
    ?_assertEqual(<<"Milan">>, maps:get(<<"city">>, Doc)).

%% verify/1 must reject a record whose payload was altered after signing
%% (a mismatched signature) -- and the ingestion path must silently no-op
%% rather than crash or trust it, per macula_record:verify/1's own
%% contract.
a_tampered_node_record_is_silently_dropped(_) ->
    Kp = macula_identity:generate(),
    NodeId = macula_identity:public(Kp),
    Signed = macula_record:sign(
               macula_record:node_record(NodeId, [], 0, #{city => <<"Milan">>}), Kp),
    Tampered = Signed#{payload => (macula_record:payload(Signed))#{
        {text, <<"city">>} => {text, <<"Nowhere">>}}},
    {noreply, state} = ingest_node_records:handle_info({node_record, Tampered}, state),
    ?_assertEqual([], docs()).

a_station_endpoint_merges_onto_the_node_doc(_) ->
    Kp = macula_identity:generate(),
    NodeId = macula_identity:public(Kp),
    NodeRecord = macula_record:sign(
                   macula_record:node_record(NodeId, [], 0, #{city => <<"Stockholm">>}), Kp),
    Endpoint = macula_record:sign(
                 macula_record:station_endpoint(NodeId, 4433,
                                                #{host_advertised => [<<"5.6.7.8">>]}), Kp),
    {noreply, state} = ingest_node_records:handle_info({node_record, NodeRecord}, state),
    {noreply, state} = ingest_node_records:handle_info({station_endpoint, Endpoint}, state),
    [Doc] = docs(),
    [?_assertEqual(<<"Stockholm">>, maps:get(<<"city">>, Doc)),
     ?_assertEqual(4433, maps:get(<<"quic_port">>, Doc))].

a_graceful_shutdown_tombstone_retires_the_station(_) ->
    Kp = macula_identity:generate(),
    NodeId = macula_identity:public(Kp),
    NodeRecord = macula_record:sign(macula_record:node_record(NodeId, [], 0), Kp),
    Tombstone = macula_record:sign(
                  macula_record:tombstone(NodeId, ?TYPE_NODE_RECORD, shutdown), Kp),
    {noreply, state} = ingest_node_records:handle_info({node_record, NodeRecord}, state),
    ?assertEqual(1, length(docs())),
    {noreply, state} = ingest_node_records:handle_info({tombstone, Tombstone}, state),
    ?_assertEqual([], docs()).

%% A tombstone superseding some OTHER record type (e.g. a station_endpoint,
%% 0x12) must never retire a node -- ingest_node_records only ever
%% ingests/retires node_record.
a_tombstone_for_a_different_superseded_type_is_ignored(_) ->
    Kp = macula_identity:generate(),
    NodeId = macula_identity:public(Kp),
    NodeRecord = macula_record:sign(macula_record:node_record(NodeId, [], 0), Kp),
    OtherTombstone = macula_record:sign(
                       macula_record:tombstone(NodeId, 16#12, revoked), Kp),
    {noreply, state} = ingest_node_records:handle_info({node_record, NodeRecord}, state),
    {noreply, state} = ingest_node_records:handle_info({tombstone, OtherTombstone}, state),
    ?_assertEqual(1, length(docs())).
