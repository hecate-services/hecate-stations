%% @doc Drives the `hecate_stations.list_stations' RPC responder against a
%% real, throwaway barrel_docdb read model seeded via station_read_model --
%% same rationale as station_read_model_tests: exercising the actual fold
%% is what verifies the filter/haversine logic against real docs instead
%% of a hand-shaped fixture that might not match what upsert actually
%% writes.
-module(list_stations_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    %% See station_read_model_tests:setup/0 for why wall-clock time is
    %% mixed into the name: unique_integer/1 alone repeats across the
    %% fresh VM `rebar3 eunit' starts per invocation and can reopen a
    %% past run's leftover on-disk directory.
    DbName = <<"hecate_stations_list_test_",
              (integer_to_binary(erlang:system_time(microsecond)))/binary, "_",
              (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Dir = filename:join(filename:basedir(user_cache, "hecate-stations-test"),
                        binary_to_list(DbName)),
    ok = filelib:ensure_path(Dir),
    ok = hecate_om_read_model:ensure(DbName, Dir),
    persistent_term:put(hecate_om_read_model_db, DbName),
    seed(),
    {DbName, Dir}.

teardown({DbName, Dir}) ->
    persistent_term:erase(hecate_om_read_model_db),
    ok = barrel_docdb:delete_db(DbName),
    _ = file:del_dir_r(Dir),
    ok.

%% Four real macula-demo stations plus one deliberately geo-less node
%% (`kind => daemon', the way a thin client's own self-announced
%% node_record would look -- present in the directory but never a `near'
%% result, and excluded from the count the same way `has_geo/1' excludes
%% it in `list_stations.erl').
seed() ->
    station_read_model:upsert_node_record(fields(#{
        city => <<"Leuven">>, country => <<"BE">>, continent_override => <<"Europe">>,
        lat => 50.8798, lng => 4.7005})),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Falkenstein">>, country => <<"DE">>, continent_override => <<"Europe">>,
        lat => 50.4779, lng => 12.3713})),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Paris">>, country => <<"FR">>, continent_override => <<"Europe">>,
        lat => 48.8566, lng => 2.3522})),
    station_read_model:upsert_node_record(fields(#{
        city => <<"Tokyo">>, country => <<"JP">>, continent_override => <<"Asia">>,
        lat => 35.6762, lng => 139.6503})),
    station_read_model:upsert_node_record(fields(#{
        city => undefined, country => undefined, lat => undefined, lng => undefined})).

%% `continent' is derived server-side from `country' by station_read_model
%% itself (via continent_lookup), so seeding never sets it directly --
%% `continent_override' here is discarded, kept only so callers read as
%% self-documenting about which continent a fixture ends up in.
fields(Overrides) ->
    Base = #{
        node_id => crypto:strong_rand_bytes(32), station_id => undefined, realms => [],
        capabilities => 0, kind => undefined, hostname => undefined, endpoint => undefined,
        city => undefined, country => undefined, lat => undefined, lng => undefined,
        display_name => undefined, caps_hint => undefined, peers => undefined
    },
    maps:merge(Base, maps:remove(continent_override, Overrides)).

cities(Rows) -> lists:sort([maps:get(<<"city">>, R, undefined) || R <- Rows]).

list_stations_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun no_filter_returns_every_station/1,
        fun continent_filter/1,
        fun country_filter/1,
        fun city_filter/1,
        fun near_sorts_nearest_first_and_excludes_geo_less_stations/1,
        fun near_respects_limit/1
    ]}.

no_filter_returns_every_station(_DbName) ->
    {ok, undefined} = list_stations:init([]),
    {reply, #{stations := Rows}, undefined} = list_stations:handle_request(#{}, undefined),
    ?_assertEqual(5, length(Rows)).

continent_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{continent => <<"Asia">>}, undefined),
    ?_assertEqual([<<"Tokyo">>], cities(Rows)).

country_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{country => <<"DE">>}, undefined),
    ?_assertEqual([<<"Falkenstein">>], cities(Rows)).

city_filter(_DbName) ->
    {reply, #{stations := Rows}, _} =
        list_stations:handle_request(#{city => <<"Paris">>}, undefined),
    ?_assertEqual([<<"Paris">>], cities(Rows)).

%% Leuven is the query point: Falkenstein and Paris are both closer than
%% Tokyo, and the geo-less fifth station must never appear.
near_sorts_nearest_first_and_excludes_geo_less_stations(_DbName) ->
    {reply, #{stations := Rows}, _} = list_stations:handle_request(
        #{near => #{lat => 50.8798, lng => 4.7005}}, undefined),
    [?_assertEqual(4, length(Rows)),
     ?_assertEqual(<<"Tokyo">>, maps:get(<<"city">>, lists:last(Rows)))].

near_respects_limit(_DbName) ->
    {reply, #{stations := Rows}, _} = list_stations:handle_request(
        #{near => #{lat => 50.8798, lng => 4.7005, limit => 2}}, undefined),
    ?_assertEqual(2, length(Rows)).
