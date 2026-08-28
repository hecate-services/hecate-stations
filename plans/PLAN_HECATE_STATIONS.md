# PLAN: hecate-stations

**This exists so any macula client can find a nearby, healthy station to
dial without hand-maintaining a static list.**

**Status:** Planning
**Created:** 2026-08-28
**Last Updated:** 2026-08-28
**Classification:** BUILD (infrastructure/plumbing — no adversarial CLAIM
gate needed; this asserts nothing about the world, it aggregates and
serves data other components already produce)

---

## Why this exists

`hecate-cam2me`'s Settings screen ships a hardcoded `KnownStations.kt` —
8 stations grepped from `macula-demo/infrastructure/` config files. One
entry (`station-be-leuven-centrum`) turned out to be a *retired DNS
alias* for `station-de-falkenstein`, caught only because a human happened
to know the fleet's history. Every future client (iOS cam2me, any other
macula app) would either re-copy this same list and drift the same way,
or have no station picker at all.

This is the general shape of the problem: **nothing aggregates "what
stations exist, where, and are they healthy" into a queryable directory.**
Every consumer either hardcodes a copy or has no view.

## What already exists — build on this, don't rebuild it

Investigated directly against source before writing this plan, not
assumed:

- **`macula_station_announcer`** (macula-station, macula 3.4+): every
  station already publishes a signed DHT `node_record`
  (`macula_record:node_record/4`, type tag `16#01`) on init and refreshes
  it at 75% of a 10-minute TTL, with a signed tombstone on graceful
  shutdown. The record's payload already carries (confirmed by reading
  `macula_record:node_payload/5`, `macula-io/macula/src/record/macula_record.erl:1129`):
  `node_id`, `station_id`, `realms`, `capabilities`, `caps_hint`,
  `display_name`, `hostname`, `endpoint`, `city`, `country`, `lat`, `lng`,
  `peers`, `kind`.
- **A *separate* record type carries the literal dial address**:
  `station_endpoint` (type tag `16#12`, storage key
  `SHA-256("station_endpoint" || pubkey)` — deliberately NOT the same key
  as `node_record`, see `macula_record.erl:610`). Payload: `quic_port`,
  `host_advertised` (a list of hosts, populated from the station's own
  `bind` config — a literal IPv6/IPv4, not a DNS name), `alpn`. TTL is a
  separate, *tighter* 5-minute constant with "zero safety margin before a
  still-valid record goes stale ahead of its own re-replication" per the
  announcer's own comment — hecate-stations' refresh cadence must respect
  this, not assume node_record's more generous 10-minute TTL applies here
  too.
- **`macula_station_health_publisher`**: every station broadcasts a 10s
  health beacon (`_mesh.health.v1`, realm `<<0:256>>`) with per-process
  load, connection count, and overlay-relay stats — already fighting real
  incidents (a 30-hour silent stall where every BEAM-level signal read
  green; see the module's own doc for why it also cross-checks the
  kernel's UDP receive queue).
- **The retrieval API already exists** on the core Erlang SDK's public
  facade (`macula-io/macula/src/macula.erl`): `find_record/2`,
  `find_records_by_type/2` (a snapshot query — exactly what a fresh
  hecate-stations boot needs), and `subscribe_records/3` (a live feed of
  new records of a type as they're stored). This is the standard
  snapshot-then-subscribe pattern already used elsewhere in this
  ecosystem (evoq's `start_from => 0` + subscribe).

**Net effect: hecate-stations is a thin QRY-only consumer of data that is
already being produced and already has a retrieval API.** No changes to
macula-station or the client SDKs are needed to get the core data
flowing.

## One real gap found, worth fixing upstream (not in this repo)

`macula_record:read_node_record/1` — the SDK's own typed-map reader for
`node_record` — does **not** surface `hostname`, `endpoint`, `city`,
`country`, `lat`, `lng`, `display_name`, or `peers`, even though
`node_payload/5` (the writer, 20 lines away in the same file) puts all of
them in. It only returns `node_id`, `station_id`, `realms`,
`capabilities`, `kind`. The data is on the wire; the convenience reader
just never grew to expose it.

Not blocking — `payload_field(P, <<"hostname">>)` etc. work directly on
the raw record right now — but every future consumer of this data pays
the same "go read the raw payload yourself" tax until this is fixed.
**File as a follow-up PR against `macula-io/macula` early in Phase 1**,
extending `read_node_record/1`'s typed map to match what the writer
already stores.

## Why DNS becomes optional, not load-bearing

`station_endpoint`'s `host_advertised` is the station's literal `bind`
address — for the fleet's real boxes, e.g. `2a01:4f8:c014:c8b3::be:01`,
not a hostname. A client (or hecate-stations itself) that resolves a
station through the DHT gets a directly-dialable IP, no DNS lookup
involved. DNS names (`station-de-falkenstein.macula.io`) stay useful for
humans reading logs/config and as bootstrap doors, but stop being
something a client's *connection* depends on — which is exactly the
category of problem that produced the stale Leuven-Centrum entry in the
first place (a DNS rename nobody downstream heard about).

## The bootstrap problem — this can't be the only way in

A client needs *a* station connection before it can call
`hecate_stations.list_stations`. `boot.macula.io` already exists for
this (DHT bootstrap nodes for mesh discovery). Shape:

1. Client ships with one minimal bootstrap door (or resolves via
   `boot.macula.io`) — not a full directory, just enough to get
   connected once.
2. Once connected, call `hecate_stations.list_stations` for the live,
   filterable, health-aware directory.
3. `KnownStations.kt`-style hardcoded lists shrink from "the whole
   directory" to a one-or-two-entry emergency fallback, used only if
   step 1 or 2 fails outright.

## Read model shape

One row per station node_id, in a barrel_docdb read model (matching
`hecate_om_service`'s `read_model_id`/`data_dir` optional-callback
pattern already used by other hecate-services):

```
node_id, hostname, host_advertised (from station_endpoint),
quic_port, city, country, continent (derived from country —
a small static lookup table, not sourced from the mesh),
lat, lng, capabilities,
first_seen_at, last_node_record_at, node_record_expires_at,
last_endpoint_at, endpoint_expires_at, tombstoned,
last_health_at, health (conns_count, overlay_relay counters)
```

`continent` needs a static country→continent table somewhere in this
repo — genuinely static reference data (ISO country codes don't get
DNS-renamed), not a maintenance burden like the station list was.

## Filtering — what the query API supports, and what it deliberately doesn't yet

- Continent / country / city — coarse, for browsing.
- Geo-radius / nearest-N from a client-supplied `{lat, lng}` — the
  "cell tower" behavior for automatic proximity selection. This is the
  query shape that keeps working unchanged as the fleet grows from 7
  boxes to street-level RasPi density (per Raf's stated roadmap) — pure
  lat/lng distance math, no schema change needed later.
- **Street-level filtering: explicitly out of scope now.** Doesn't fit
  the current fleet (cloud VPS POPs aren't street-addressable) and isn't
  needed until station density actually gets there. The geo-radius query
  shape above already carries this forward for free when it does.
- Latency: **not centrally computed per-client** — that's inherently
  relative to wherever the asking device is, and can't be known here.
  The client does its own nearest-station heuristic over the lat/lng this
  service returns. hecate-stations MAY separately contribute a coarse
  "is this station responsive at all" signal from its own health-beacon
  consumption — a real but different thing from any one client's latency,
  and should never be labeled as if it were the same measurement.

## One open question — verify before committing to the health design

Does a plain thin client (not itself a station) actually receive
`_mesh.health.v1`? `macula_station_health_publisher:broadcast/1` iterates
`macula_station_peer_links:connections()` and calls
`macula_station_link:publish/4` per connection — unclear from reading
alone whether that connection set includes ordinary client sessions or
is inter-station-only gossip. Cheap to check empirically (connect a
plain client, `subscribe(<<"_mesh.health.v1">>, <<0:256>>)`, see if
anything arrives) — do this as the first step of Phase 2, not resolved
by more reading.

## Phases

- [ ] **Phase 0 — spike, not committed code.** Verify `_mesh.health.v1`
      visibility to a thin client (see open question above). Confirms or
      kills the planned shape of Phase 2 before writing it.
- [ ] **Phase 1 — geo + liveness only.** Subscribe/query `node_record`
      and `station_endpoint` via `find_records_by_type/2` (boot snapshot)
      + `subscribe_records/3` (live feed). Populate the read model minus
      the `health` fields. Serve `hecate_stations.list_stations` (mesh
      RPC, same pattern as `hecate_turn_credentials.mint_credential`) —
      filterable by continent/country/city, plus the geo-radius/nearest-N
      shape from day one even though it'll only ever see 7 rows for now.
      File the `read_node_record/1` upstream fix (see above) as part of
      this phase, since Phase 1 is what actually needs those fields.
- [ ] **Phase 2 — health.** Consume `_mesh.health.v1` (pending Phase 0's
      answer) and fold a liveness/responsiveness signal into each row,
      distinct from raw TTL expiry.
- [ ] **Phase 3 — cam2me integration.** Replace `KnownStations.kt`'s
      static list with a real `hecate_stations.list_stations` call once
      connected; shrink the hardcoded list to a 1-2 entry bootstrap
      fallback per the bootstrap-problem section above.
- [ ] **Phase 4 — future, not now.** Street-level filtering once density
      warrants it. No schema change expected — see the filtering section.

## Files to Create/Modify

| File | Purpose | Status |
|------|---------|--------|
| `apps/hecate_stations/src/hecate_stations_service.erl` | Declare `list_stations` capability, read-model callbacks | Scaffolded, empty |
| `apps/hecate_stations/src/list_stations/list_stations.erl` | RPC responder (macula_response), Phase 1 | Not started |
| `apps/hecate_stations/src/ingest_node_records/` | Consumes node_record + station_endpoint, Phase 1 | Not started |
| `apps/hecate_stations/src/ingest_health/` | Consumes `_mesh.health.v1`, Phase 2 | Not started |
| `apps/hecate_stations/src/continent_lookup.erl` | Static country→continent table | Not started |
| `macula-io/macula` PR | Extend `read_node_record/1`'s typed map | Not started, tracked here |
| `hecate-cam2me/.../KnownStations.kt` | Shrink to bootstrap fallback once Phase 3 lands | Not started |

## Success Criteria

- [ ] `hecate_stations.list_stations` returns real fleet data (not fixtures)
- [ ] A station rename (like the Leuven→Falkenstein one) requires zero
      client-side changes anywhere — the whole point of this service
- [ ] cam2me's station picker is fed by this service, not a static file
- [ ] Query API's geo-radius shape works today at 7 rows and needs no
      redesign at 700
