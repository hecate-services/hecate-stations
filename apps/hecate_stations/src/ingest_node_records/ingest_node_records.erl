%% @doc Consumes node_record (type 0x01) and station_endpoint (type
%% 0x12) DHT records -- geo, hostname, and the literal dial address every
%% macula-station already broadcasts via macula_station_announcer -- and
%% projects them into the read model, one barrel_docdb doc per node_id.
%% Also consumes tombstone (type 0x0C) records superseding a node_record,
%% published by the same announcer on graceful shutdown, and retires the
%% station immediately rather than waiting out its TTL.
%%
%% Snapshot-then-subscribe, the same pattern evoq's own catch-up uses:
%% `macula:find_records_by_type/2' for what's already there at boot,
%% `macula:subscribe_records/3' for what arrives after. Retries the
%% initial connect until `hecate_om_identity' has both the mesh pool and
%% this service's keypair -- it connects off its own init path,
%% asynchronously, so a single inline attempt at boot can race it and
%% lose (see hecate-tube's `tube_mesh_providers.erl' for the same race).
%%
%% No tombstone snapshot at boot: a tombstone overwrites its superseded
%% record's own DHT slot (Part 6 §9.13), so a station tombstoned before
%% this service started was never in the `?TYPE_NODE_RECORD' snapshot to
%% begin with -- there is nothing to retire.
%%
%% Every record's signature is verified via `macula_record:verify/1'
%% before its payload is trusted, per that function's own doc.
-module(ingest_node_records).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TYPE_NODE_RECORD, 16#01).
-define(TYPE_TOMBSTONE, 16#0C).
-define(TYPE_STATION_ENDPOINT, 16#12).
-define(RETRY_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    self() ! connect,
    {ok, #{}}.

handle_call(_Msg, _From, State) -> {reply, {error, unknown_call}, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(connect, State) ->
    {noreply, try_connect(hecate_om:mesh_handles(), State)};
handle_info({node_record, Record}, State) ->
    ok = ingest_node_record(Record),
    {noreply, State};
handle_info({station_endpoint, Record}, State) ->
    ok = ingest_station_endpoint(Record),
    {noreply, State};
handle_info({tombstone, Record}, State) ->
    ok = ingest_tombstone(Record),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

try_connect({ok, Pool, _Realm}, State) ->
    Self = self(),
    {ok, NodeRecords} = macula:find_records_by_type(Pool, ?TYPE_NODE_RECORD),
    lists:foreach(fun ingest_node_record/1, NodeRecords),
    {ok, Endpoints} = macula:find_records_by_type(Pool, ?TYPE_STATION_ENDPOINT),
    lists:foreach(fun ingest_station_endpoint/1, Endpoints),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_NODE_RECORD,
                                       fun(R) -> Self ! {node_record, R} end),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_STATION_ENDPOINT,
                                       fun(R) -> Self ! {station_endpoint, R} end),
    {ok, _} = macula:subscribe_records(Pool, ?TYPE_TOMBSTONE,
                                       fun(R) -> Self ! {tombstone, R} end),
    State#{pool => Pool};
try_connect(_MeshHandles, State) ->
    erlang:send_after(?RETRY_MS, self(), connect),
    State.

ingest_node_record(Record) ->
    verified_node_record(macula_record:verify(Record)).

verified_node_record({ok, Record}) ->
    Fields = macula_record:read_node_record(Record),
    station_read_model:upsert_node_record(Fields);
verified_node_record({error, _Reason}) ->
    ok.

ingest_station_endpoint(Record) ->
    verified_station_endpoint(macula_record:verify(Record), Record).

verified_station_endpoint({ok, Record}, #{key := StationPubkey}) ->
    Fields = macula_record:read_station_endpoint(Record),
    station_read_model:upsert_station_endpoint(StationPubkey, Fields);
verified_station_endpoint({error, _Reason}, _Record) ->
    ok.

ingest_tombstone(Record) ->
    verified_tombstone(macula_record:verify(Record)).

verified_tombstone({ok, Record}) ->
    retire_if_node_record(macula_record:read_tombstone(Record));
verified_tombstone({error, _Reason}) ->
    ok.

retire_if_node_record(#{superseded_type := ?TYPE_NODE_RECORD, superseded_key := NodeId}) ->
    station_read_model:retire_node(NodeId);
retire_if_node_record(#{}) ->
    ok.
