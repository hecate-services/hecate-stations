%% @doc One barrel_docdb doc per station node_id, merging fields from
%% node_record (geo, hostname, capabilities) and station_endpoint (the
%% literal dial address) as each arrives independently -- read-modify-
%% write against whatever's already there, since either can land first.
%%
%% Missing/undefined fields are OMITTED, not written as a null placeholder
%% -- same convention `macula_record:with_text/3' etc. already use on the
%% write side these fields came from.
-module(station_read_model).

-export([upsert_node_record/1, upsert_station_endpoint/2, retire_node/1, fold/2]).

upsert_node_record(#{node_id := NodeId} = Fields) when is_binary(NodeId) ->
    Id = node_id_hex(NodeId),
    Doc0 = existing_or_new(Id, NodeId),
    Doc1 = Doc0#{<<"last_node_record_at">> => now_ms()},
    Doc2 = maybe_put(Doc1, <<"hostname">>, maps:get(hostname, Fields)),
    Doc3 = maybe_put(Doc2, <<"city">>, maps:get(city, Fields)),
    Doc4 = maybe_put(Doc3, <<"country">>, maps:get(country, Fields)),
    Doc5 = maybe_put(Doc4, <<"continent">>, continent_of(maps:get(country, Fields))),
    Doc6 = maybe_put(Doc5, <<"lat">>, maps:get(lat, Fields)),
    Doc7 = maybe_put(Doc6, <<"lng">>, maps:get(lng, Fields)),
    Doc8 = maybe_put(Doc7, <<"capabilities">>, maps:get(capabilities, Fields)),
    Doc9 = maybe_put(Doc8, <<"kind">>, maps:get(kind, Fields)),
    put(Doc9);
upsert_node_record(_Fields) ->
    ok.

upsert_station_endpoint(StationPubkey, #{quic_port := Port} = Fields)
  when is_binary(StationPubkey), byte_size(StationPubkey) =:= 32 ->
    Id = node_id_hex(StationPubkey),
    Doc0 = existing_or_new(Id, StationPubkey),
    Doc1 = Doc0#{
        <<"quic_port">>              => Port,
        <<"host_advertised">>        => maps:get(host_advertised, Fields, []),
        <<"last_endpoint_at">>       => now_ms()
    },
    put(Doc1).

%% @doc Retire a station whose node_record was tombstoned. `fold_docs/3'
%% (behind `fold/2' below) excludes deleted docs by default, so a
%% retired station stops appearing in list_stations with no change
%% needed there -- barrel_docdb keeps the revision history for conflict
%% resolution rather than actually erasing the row.
-spec retire_node(macula_identity:pubkey()) -> ok.
retire_node(NodeId) when is_binary(NodeId), byte_size(NodeId) =:= 32 ->
    Id = node_id_hex(NodeId),
    {ok, DbName} = hecate_om:read_model(),
    deleted(barrel_docdb:delete_doc(DbName, Id)).

deleted({ok, _}) -> ok;
deleted({error, not_found}) -> ok.

%% @doc Fold every station doc through Fun/2 (same shape as
%% barrel_docdb:fold_docs/3's own callback) -- list_stations builds its
%% filtered result over this.
fold(Fun, Acc) ->
    {ok, DbName} = hecate_om:read_model(),
    barrel_docdb:fold_docs(DbName, Fun, Acc).

existing_or_new(Id, NodeId) ->
    {ok, DbName} = hecate_om:read_model(),
    case barrel_docdb:get_doc(DbName, Id) of
        {ok, Doc} -> Doc;
        {error, not_found} -> #{<<"id">> => Id, <<"node_id">> => NodeId}
    end.

put(Doc) ->
    {ok, DbName} = hecate_om:read_model(),
    {ok, _} = barrel_docdb:put_doc(DbName, Doc),
    ok.

maybe_put(Doc, _Key, undefined) -> Doc;
maybe_put(Doc, Key, Value) -> Doc#{Key => Value}.

continent_of(undefined) -> undefined;
continent_of(Country) -> continent_lookup:continent(Country).

node_id_hex(NodeId) ->
    binary:encode_hex(NodeId, lowercase).

now_ms() ->
    erlang:system_time(millisecond).
