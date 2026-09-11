%% @doc RPC provider: hecate_stations.list_stations. Returns the live
%% directory this service has built from node_record/station_endpoint
%% DHT records, optionally filtered.
%%
%% Payload (all optional, `#{}' or absent = every known station):
%%   continent | country | city :: binary() -- exact match
%%   near => #{lat := number(), lng := number(), limit => pos_integer()}
%%     -- sorted nearest-first by great-circle distance; `limit' caps the
%%     result count. This is the shape that keeps working unchanged as
%%     the fleet grows from a handful of boxes to street-level density --
%%     see plans/PLAN_HECATE_STATIONS.md's filtering section.
-module(list_stations).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, undefined}.

%% Filters and sorting run on the stored docs; only the rows that go out
%% are shaped for the wire (station_read_model:to_wire/1).
handle_request(Payload, State) ->
    {ok, Rows} = station_read_model:fold(fun(Doc, Acc) -> {ok, [Doc | Acc]} end, []),
    Stations = [station_read_model:to_wire(Row) || Row <- apply_filters(Payload, Rows)],
    {reply, #{stations => Stations}, State}.

apply_filters(Payload, Rows) ->
    R1 = filter_eq(Rows, <<"continent">>, maps:get(continent, Payload, undefined)),
    R2 = filter_eq(R1, <<"country">>, maps:get(country, Payload, undefined)),
    R3 = filter_eq(R2, <<"city">>, maps:get(city, Payload, undefined)),
    apply_near(R3, maps:get(near, Payload, undefined)).

filter_eq(Rows, _Key, undefined) ->
    Rows;
filter_eq(Rows, Key, Value) ->
    [R || R <- Rows, maps:get(Key, R, undefined) =:= Value].

apply_near(Rows, undefined) ->
    Rows;
apply_near(Rows, #{lat := Lat, lng := Lng} = Near) ->
    WithDistance = [{distance_km(Lat, Lng, R), R} || R <- Rows, has_geo(R)],
    Sorted = [R || {_D, R} <- lists:keysort(1, WithDistance)],
    limited(Sorted, maps:get(limit, Near, undefined)).

has_geo(R) ->
    maps:get(<<"lat">>, R, undefined) =/= undefined andalso
    maps:get(<<"lng">>, R, undefined) =/= undefined.

distance_km(Lat, Lng, Row) ->
    haversine_km(Lat, Lng, maps:get(<<"lat">>, Row), maps:get(<<"lng">>, Row)).

limited(Sorted, undefined) -> Sorted;
limited(Sorted, N) when is_integer(N), N >= 0 -> lists:sublist(Sorted, N).

%% Great-circle distance in km. Earth radius 6371km, standard mean value
%% -- fine for "which station is nearest", not survey-grade.
haversine_km(Lat1, Lng1, Lat2, Lng2) ->
    EarthRadiusKm = 6371.0,
    Phi1 = Lat1 * math:pi() / 180,
    Phi2 = Lat2 * math:pi() / 180,
    DPhi = (Lat2 - Lat1) * math:pi() / 180,
    DLambda = (Lng2 - Lng1) * math:pi() / 180,
    A = math:sin(DPhi / 2) * math:sin(DPhi / 2) +
        math:cos(Phi1) * math:cos(Phi2) *
        math:sin(DLambda / 2) * math:sin(DLambda / 2),
    C = 2 * math:atan2(math:sqrt(A), math:sqrt(1 - A)),
    EarthRadiusKm * C.
