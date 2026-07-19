# netbird-kit

Interactive, configurable deployment manager for **self-hosted [NetBird](https://netbird.io)** — built for the cases the official installer doesn't cover cleanly: running behind your **existing edge proxy**, on a **non-standard public port**, or **behind NAT**, with the single-origin OIDC and gRPC/UDP routing gotchas handled for you.

If you just want NetBird on a fresh box that owns ports 80/443, the official `getting-started.sh` is simpler — use that. Reach for this kit when your topology is more constrained.

## What it does

One script, full lifecycle:

| Command | Action |
|---|---|
| `init` | Interactive Q&A → generates `.env`, `config.yaml`, `docker-compose.yml`, `dashboard.env` |
| `up` | `docker compose up -d` |
| `health` | Checks containers, OIDC discovery over TLS, and STUN listener |
| `update` | Backs up config + `pg_dump`, pulls newer images, recreates, health-checks |
| `pin` | Freezes current image **digests** into `.env` for reproducible redeploys |
| `down` | Stops the stack (keeps data) |
| `destroy` | Stops and **deletes** all data volumes (asks first) |

The stack: combined `netbird-server` (management + signal + relay + STUN) + dashboard + **PostgreSQL** + optional bundled Traefik.

## Configurable at `init`

- **Public hostname and HTTPS port** — any port, single-origin enforced everywhere.
- **STUN/UDP port** — change it if `3478` is taken.
- **Reverse proxy** — bundled Traefik, *or* generate config advice for an existing proxy (pfSense/HAProxy, nginx, Caddy, external Traefik).
- **TLS** — ACME DNS-01 (any lego provider), ACME HTTP-01, or bring-your-own-cert. For the ACME modes, `init` offers the **Let's Encrypt staging** endpoint — use it while testing to avoid production rate limits (staging issues untrusted certs; switch to production with a re-init once your topology works).
- **Storage** — Docker named volumes or bind-mounts to host paths you choose.
- **Postgres** — user/db names; password generated locally.

## Quick start

```bash
git clone <your-repo-url> netbird-kit && cd netbird-kit
chmod +x netbird-kit.sh
./netbird-kit.sh init      # answer the prompts
# point DNS at this host, set up NAT per the advice init prints
./netbird-kit.sh up
./netbird-kit.sh health
# open https://<your-domain>:<your-port>/setup to create the first admin
./netbird-kit.sh pin       # once you're happy, freeze versions
```

Secrets (relay, DB encryption key, DB password, IdP cookie key) are generated locally with `openssl` and never printed or transmitted.

## The gotchas this kit handles for you

These are the things that make hand-rolling NetBird behind a proxy painful:

- **Single-origin OIDC.** The dashboard bakes in one auth authority (`https://host:port/oauth2`). If you load the dashboard on *any other* origin — e.g. bare `:443` when your real port is `:12345` — the OIDC discovery fetch is cross-origin and fails with a CORS error and an `Unauthenticated` screen. The kit makes every URL (exposed address, issuer, redirect URIs, dashboard authority) use **one** origin, and warns you to only ever reach it on that port.
- **gRPC needs h2c.** Signal and management run over gRPC (HTTP/2). In bundled mode the kit configures a dedicated Traefik router with an `h2c` backend; in external mode it prints the exact path split your proxy needs.
- **STUN can't be proxied.** UDP STUN must be a direct port-forward, never through an HTTP proxy. The kit exposes it directly and reminds you in the NAT advice.
- **Config schema.** `auth`, `store`, and `reverseProxy` are nested under `server:` in `config.yaml` (NetBird ignores them at top level).
- **Cloudflare proxy vs. custom ports.** If your DNS is on Cloudflare, the record must be **DNS-only (grey cloud)** — the orange-cloud proxy won't pass non-standard ports or UDP. The kit calls this out.

## Files it generates

```
.env                 # all config values + generated secrets (git-ignored)
config.yaml          # NetBird combined-server config (git-ignored)
docker-compose.yml   # structure reflects your init choices (git-ignored)
dashboard.env        # dashboard OIDC config (git-ignored)
secrets/traefik.env  # DNS-01 provider credentials, chmod 600 (git-ignored)
traefik-dynamic.yml  # only for bring-your-own-cert mode
backups/<timestamp>/ # created by `update`
```

Everything with secrets is git-ignored by default. **Back up `.env` and `config.yaml`** — the store `encryptionKey` is unrecoverable if lost.

## Updating safely

`./netbird-kit.sh update` backs up first, then pulls and recreates. NetBird occasionally changes config schema between versions, so:

1. Read the [NetBird release notes](https://github.com/netbirdio/netbird/releases) before a major bump.
2. Run `update` (it dumps the DB and copies config to `backups/`).
3. Watch `docker compose logs -f netbird-server` for schema/parse errors.
4. On a known-good version, run `pin` so future pulls can't surprise you.

Auto-updaters (Watchtower et al.) are **not recommended** for this stack — it's stateful control-plane infrastructure where an unattended bad pull is an outage. Pin and update deliberately.

## Requirements

- Linux host with Docker + Compose v2
- `openssl`, `curl` (and `ss` for the local STUN check)
- A domain you control, pointing at this host

## License

MIT — see `LICENSE`.

## Disclaimer

Community tooling, not affiliated with NetBird GmbH. It generates standard NetBird configuration; when in doubt, cross-check against the [official docs](https://docs.netbird.io/selfhosted/selfhosted-quickstart).
