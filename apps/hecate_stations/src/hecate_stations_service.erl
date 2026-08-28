%% @doc The hecate_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. hecate_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
-module(hecate_stations_service).

-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
-export([read_model_id/0, data_dir/0]).

info() ->
    #{name => <<"hecate-stations">>,
      version => <<"0.1.0">>,
      description => <<"Live, filterable directory of macula stations: geo, health, and direct-dial IP, so clients never hand-maintain a station list">>}.

start(_Opts) -> hecate_stations_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

%% Declaring `handler' makes hecate_om_capabilities register this with
%% the mesh pool AND publish the signed direct-dial DHT record in one
%% call at boot (via hecate_om:boot/1), including periodic re-advertise
%% -- see list_stations.erl for the actual RPC logic.
capabilities() ->
    [#{name => <<"hecate_stations.list_stations">>,
      version => 1,
      handler => {list_stations, []}}].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%% This service publishes and subscribes to no realm-scoped topics --
%% node_record/station_endpoint ingestion reads the mesh-wide DHT (realm
%% 0, protocol-internal), not anything this identity_spec governs. The
%% one capability it serves is authorised by its own signing keypair
%% (hecate_om_identity), not by realm-granted pubsub actions/resources.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"hecate-stations">>,
      actions => [],
      resources => [],
      ttl_days => 30}.

%% barrel_docdb read model, populated by ingest_node_records. Requires
%% no {evoq, [...]} adapter block (unlike store_id/0's reckon-db path) --
%% barrel_docdb starts idle until this is exported, per hecate_om's own
%% doc.
read_model_id() -> <<"hecate_stations">>.

data_dir() ->
    os:getenv("HECATE_DATA_DIR", "/var/lib/hecate-stations").
