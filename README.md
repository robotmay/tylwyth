# Tylwyth

Shared private-network (`/24`), local EPMD, and pluggable BEAM peer discovery library for distributed Elixir releases.

## Installation

Add `:tylwyth` to `deps` in `mix.exs`:

```elixir
def deps do
  [
    {:tylwyth, git: "https://github.com/robotmay/tylwyth.git", tag: "v0.1.3"}
  ]
end
```

## Supervision Setup

Add `{Tylwyth, opts}` directly under your application or cluster supervisor:

```elixir
{Tylwyth,
 basename: Application.get_env(:my_app, :cluster_basename, "my_app"),
 subnet: Application.get_env(:my_app, :cluster_subnet),
 static_nodes: Application.get_env(:my_app, :cluster_static_nodes, []),
 enabled: Application.get_env(:my_app, :cluster_autodiscovery, true),
 extra_nodes: &MyApp.Cluster.extra_nodes/0,
 on_connect: fn peer -> MyApp.Cluster.sync_peer(peer) end}
```

## Release Environment (`rel/env.sh.eex`)

Source the bundled `priv/env.sh` from your Mix release `rel/env.sh.eex`:

```sh
#!/bin/sh
export NODE_BASENAME="${NODE_BASENAME:-my_app}"

for f in "$RELEASE_ROOT"/lib/tylwyth-*/priv/env.sh; do
  [ -f "$f" ] && . "$f" && break
done
```

For local/dev testing only, you may set `DEFAULT_RELEASE_COOKIE` in `rel/env.sh.eex`; `priv/env.sh` logs a warning whenever it falls back to `DEFAULT_RELEASE_COOKIE`.

## Security

- **Always set a secret `RELEASE_COOKIE`**: Anyone able to reach the Erlang distribution port with the cookie can execute arbitrary code on the BEAM node. Never rely on `DEFAULT_RELEASE_COOKIE` in production.
- **Firewall distribution & EPMD ports**: Run clustering over an isolated private/VPN network (e.g. WireGuard or private VPC LAN) and restrict ports `4369` and `9100–9105` (or your `ERL_DIST_STATIC_PORT`) to peer IPs.
- **Private subnet sweeps only**: `Tylwyth.Network.generate_subnet_nodes/2` restricts subnet expansion to RFC1918 and loopback (`127.0.0.0/8`) ranges, and `priv/env.sh` never falls back to binding distribution/EPMD onto a public IP.
