# hecate-stations

**Live, filterable directory of macula stations: geo, health, and direct-dial IP, so clients never hand-maintain a station list**

## Status: scaffold

The service boots, joins the mesh and answers `/health` on 8495. It
does nothing else yet.

It announces no capability and asks the realm for no authority, because it can do
nothing yet. Both lists grow when the thing they name exists. Advertising a
capability before it exists puts a lie on the mesh where another service can find
it and call it.

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 lint

    scripts/health.sh                      # against a running node

Building the image needs a Rust toolchain, because macula ships a QUIC NIF and
the alpine build compiles it from source rather than fetching one linked against
a different libc.

    podman build -t hecate-stations -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `HECATE_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MACULA_STATION_SEEDS` | required | Station to dial. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `HECATE_HEALTH_PORT` | `8495` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `HECATE_NODE_NAME` | `hecate_stations` | Erlang node name. |
| `HECATE_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `HECATE_COOKIE` | `hecate_stations` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

CI builds on every push to `main` and pushes
`ghcr.io/hecate-services/hecate-stations:latest` plus the semver tag. Pull `:latest` under
watchtower and a merge is a deploy, while a rollback is pinning to a semver tag.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `HECATE_REALM` supplied from somewhere it is not committed.

## The service contract

Six callbacks in `hecate_stations_service`, all required, all resolved **by name** by
`hecate_om` at startup on a live node. The `-behaviour(hecate_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

### Adding a store later

This service has no `reckon-db` store, which is the right answer for most. The
reckon-db applications run either way; what a store adds is a data directory, an
open handle, and something written.

The cheapest way to get one is to scaffold again with `store=1`, which generates
the callbacks, the config and the guards together.

⚠ **By hand it is three things and not one, and the missing third crash-loops the
node.** Export `store_id/0` and `data_dir/0`; add the `evoq` adapter block to
`config/sys.config.src`, without which boot raises
`{not_configured, event_store_adapter}` before any service code runs; and mount a
volume in the compose file. A sibling service put two of three fleet nodes into a
boot loop by doing the first and not the second.

## Licence

Apache-2.0.
