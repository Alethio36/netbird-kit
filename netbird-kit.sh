#!/usr/bin/env bash
#
# netbird-kit — configurable self-hosted NetBird deployment manager.
#
# Handles the case the official installer doesn't: NetBird behind your existing
# edge proxy and/or on a non-standard public port, with the single-origin and
# reverse-proxy gotchas handled for you.
#
# Subcommands:
#   init      Interactive Q&A -> generates .env, config.yaml, docker-compose.yml
#   up        Start the stack (docker compose up -d)
#   health    Check containers, TLS/OIDC discovery, and STUN reachability
#   update    Back up, pull newer images, recreate, health-check
#   pin       Freeze current image digests into .env for reproducible redeploys
#   down      Stop the stack (keeps data volumes)
#   destroy   Stop and DELETE all data volumes (irreversible)
#   help      Show this help
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants / defaults (edit these to change baked-in defaults for your fork)
# ---------------------------------------------------------------------------
readonly KIT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly SECRETS_DIR="${SCRIPT_DIR}/secrets"
readonly TRAEFIK_DYNAMIC="${SCRIPT_DIR}/traefik-dynamic.yml"

# Default image tags. `pin` rewrites these to immutable digests.
readonly DEF_SERVER_IMG="netbirdio/netbird-server:latest"
readonly DEF_DASH_IMG="netbirdio/dashboard:latest"
readonly DEF_TRAEFIK_IMG="traefik:v3.6"
readonly DEF_PG_IMG="postgres:16-alpine"

# Internal Docker network subnet (used for trustedHTTPProxies).
readonly NET_SUBNET="172.30.0.0/24"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_OFF=""
fi

info() { printf '%s\n' "${C_BLU}==>${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GRN}OK${C_OFF}  $*"; }
warn() { printf '%s\n' "${C_YEL}WARN${C_OFF} $*" >&2; }
die()  { printf '%s\n' "${C_RED}ERROR${C_OFF} $*" >&2; exit 1; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

# ask VAR "Question" ["default"]  -> sets global $VAR
ask() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if [[ -n "$__def" ]]; then
    read -r -p "$(printf '%s' "${C_BOLD}${__q}${C_OFF} [${__def}]: ")" __ans || true
    __ans="${__ans:-$__def}"
  else
    while [[ -z "$__ans" ]]; do
      read -r -p "$(printf '%s' "${C_BOLD}${__q}${C_OFF}: ")" __ans || true
      [[ -z "$__ans" ]] && warn "This value is required."
    done
  fi
  printf -v "$__var" '%s' "$__ans"
}

# ask_secret_value VAR "Question"  -> reads without echo
ask_secret_value() {
  local __var="$1" __q="$2" __ans=""
  while [[ -z "$__ans" ]]; do
    read -r -s -p "$(printf '%s' "${C_BOLD}${__q}${C_OFF}: ")" __ans || true
    printf '\n'
    [[ -z "$__ans" ]] && warn "This value is required."
  done
  printf -v "$__var" '%s' "$__ans"
}

# ask_menu VAR "Question" "opt1" "opt2" ...  -> sets $VAR to the chosen option text
ask_menu() {
  local __var="$1" __q="$2"; shift 2
  local -a __opts=("$@")
  local __i __choice
  printf '%s\n' "${C_BOLD}${__q}${C_OFF}"
  for __i in "${!__opts[@]}"; do
    printf '  %d) %s\n' "$((__i + 1))" "${__opts[$__i]}"
  done
  while :; do
    read -r -p "Choose [1-${#__opts[@]}]: " __choice || true
    if [[ "$__choice" =~ ^[0-9]+$ ]] && (( __choice >= 1 && __choice <= ${#__opts[@]} )); then
      printf -v "$__var" '%s' "${__opts[$((__choice - 1))]}"
      return 0
    fi
    warn "Enter a number between 1 and ${#__opts[@]}."
  done
}

ask_yesno() { # ask_yesno "Question" default(y/n) -> returns 0 for yes
  local __q="$1" __def="${2:-n}" __ans=""
  local __hint="y/N"; [[ "$__def" == "y" ]] && __hint="Y/n"
  read -r -p "$(printf '%s' "${C_BOLD}${__q}${C_OFF} [${__hint}]: ")" __ans || true
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_port() {
  if ! [[ "$1" =~ ^[0-9]+$ ]] || (( $1 < 1 || $1 > 65535 )); then
    die "Invalid port '$1' (must be 1-65535)."
  fi
}
validate_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9.-]+$ && "$1" == *.* ]] \
    || die "Invalid domain '$1' (expected something like netbird.example.com)."
}
require_file() {
  [[ -f "$1" ]] || die "File not found: $1"
}

gen_secret_b64() { openssl rand -base64 32; }
gen_secret_hex() { openssl rand -hex 24; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2) not available. Install the Compose plugin."
}

require_generated() {
  [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" && -f "$CONFIG_FILE" ]] \
    || die "No generated config found. Run: $0 init"
}

# ---------------------------------------------------------------------------
# init: interactive Q&A
# ---------------------------------------------------------------------------
cmd_init() {
  if [[ -f "$ENV_FILE" ]]; then
    ask_yesno "Existing config found. Overwrite it (regenerates secrets)?" "n" \
      || die "Aborted. Delete .env/config.yaml/docker-compose.yml manually to regenerate."
  fi

  hr
  info "NetBird deployment configuration"
  hr

  # --- Domain & public port (single-origin: this port is used EVERYWHERE) ---
  ask NB_DOMAIN "Public hostname for NetBird (no scheme, no port)" "netbird.example.com"
  validate_domain "$NB_DOMAIN"

  ask NB_PUBLIC_PORT "Public HTTPS port clients will use (443 = standard)" "443"
  validate_port "$NB_PUBLIC_PORT"

  ask NB_STUN_PORT "STUN/UDP port (3478 standard; change if already in use)" "3478"
  validate_port "$NB_STUN_PORT"

  # --- Reverse proxy mode ---
  ask_menu NB_PROXY_MODE "How is TLS / reverse proxy handled?" \
    "bundled  - this stack runs its own Traefik (recommended if nothing else owns your ports)" \
    "external - you already run a proxy (pfSense/HAProxy, nginx, Caddy, external Traefik)"
  NB_PROXY_MODE="${NB_PROXY_MODE%% *}"   # keep first word: bundled|external

  # --- TLS strategy (only meaningful for bundled proxy) ---
  NB_TLS_MODE="external-proxy"
  NB_TLS_DNS_PROVIDER=""
  NB_TLS_CERT_PATH=""
  NB_TLS_KEY_PATH=""
  NB_ACME_EMAIL=""
  NB_ACME_STAGING="false"
  if [[ "$NB_PROXY_MODE" == "bundled" ]]; then
    ask_menu NB_TLS_MODE "Certificate strategy for the bundled Traefik" \
      "dns01  - ACME DNS-01 (works on any port / behind NAT; needs DNS provider API creds)" \
      "http01 - ACME HTTP-01 (requires ${NB_DOMAIN}:80 publicly reachable)" \
      "byocert - bring your own cert + key files"
    NB_TLS_MODE="${NB_TLS_MODE%% *}"

    case "$NB_TLS_MODE" in
      dns01)
        ask NB_ACME_EMAIL "Email for the Let's Encrypt account" ""
        ask_acme_staging
        info "DNS provider must be one lego supports: https://go-acme.github.io/lego/dns/"
        ask NB_TLS_DNS_PROVIDER "lego DNS provider code (e.g. cloudflare, route53, digitalocean)" "cloudflare"
        collect_dns_credentials      # sets DNS_CRED_LINES[] (written to secrets/traefik.env)
        ;;
      http01)
        ask NB_ACME_EMAIL "Email for the Let's Encrypt account" ""
        ask_acme_staging
        if [[ "$NB_PUBLIC_PORT" != "443" ]]; then
          warn "HTTP-01 validates on port 80 of ${NB_DOMAIN}. With a non-standard HTTPS"
          warn "port, ${NB_DOMAIN}:80 must still be publicly reachable and forwarded to"
          warn "this host. If it isn't, choose dns01 instead."
        fi
        ;;
      byocert)
        ask NB_TLS_CERT_PATH "Absolute path to fullchain cert (.pem/.crt)" ""
        require_file "$NB_TLS_CERT_PATH"
        ask NB_TLS_KEY_PATH "Absolute path to private key (.pem/.key)" ""
        require_file "$NB_TLS_KEY_PATH"
        ;;
    esac
  fi

  # --- External proxy: which one (for tailored advice) + host ports ---
  NB_EXT_PROXY_KIND=""
  NB_HTTP_HOST_PORT=""
  NB_DASH_HOST_PORT=""
  if [[ "$NB_PROXY_MODE" == "external" ]]; then
    ask_menu NB_EXT_PROXY_KIND "Which external proxy? (for setup advice)" \
      "pfsense-haproxy" "nginx" "caddy" "traefik-external" "other"
    ask NB_HTTP_HOST_PORT "Host port to expose the NetBird server on (your proxy routes here)" "8081"
    validate_port "$NB_HTTP_HOST_PORT"
    ask NB_DASH_HOST_PORT "Host port to expose the dashboard on (your proxy routes here)" "8080"
    validate_port "$NB_DASH_HOST_PORT"
  fi

  # --- Storage ---
  ask_menu NB_STORAGE_MODE "Where should data live?" \
    "named - Docker-managed named volumes (simplest)" \
    "bind  - bind-mount to host paths you control"
  NB_STORAGE_MODE="${NB_STORAGE_MODE%% *}"
  NB_DATA_BASE=""
  if [[ "$NB_STORAGE_MODE" == "bind" ]]; then
    ask NB_DATA_BASE "Absolute base directory for data (subdirs created per volume)" "${SCRIPT_DIR}/data"
    [[ "$NB_DATA_BASE" = /* ]] || die "Data base directory must be an absolute path."
  fi

  # --- Postgres ---
  ask NB_PG_USER "Postgres username" "netbird"
  ask NB_PG_DB "Postgres database name" "netbird"

  # --- Generate secrets locally ---
  info "Generating secrets locally (never printed, never leave this machine)..."
  local relay_secret store_key idp_key pg_pass
  relay_secret="$(gen_secret_b64)"
  store_key="$(gen_secret_b64)"
  idp_key="$(gen_secret_b64)"
  pg_pass="$(gen_secret_hex)"

  # --- Write everything ---
  write_env "$relay_secret" "$store_key" "$idp_key" "$pg_pass"
  write_config
  write_compose
  [[ "$NB_TLS_MODE" == "byocert" ]] && write_traefik_dynamic

  ok "Configuration written."
  hr
  print_advice
  hr
  print_next_steps
}

# collect_dns_credentials: prompt for the provider's lego env vars, store them
collect_dns_credentials() {
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  local cred_file="${SECRETS_DIR}/traefik.env"
  : > "$cred_file"; chmod 600 "$cred_file"

  case "$NB_TLS_DNS_PROVIDER" in
    cloudflare)
      local tok
      ask_secret_value tok "Cloudflare API token (scope: Zone:DNS:Edit on your zone only)"
      printf 'CF_DNS_API_TOKEN=%s\n' "$tok" >> "$cred_file"
      ;;
    *)
      warn "For '${NB_TLS_DNS_PROVIDER}', enter the lego environment variables it needs."
      warn "See the provider page at https://go-acme.github.io/lego/dns/${NB_TLS_DNS_PROVIDER}/"
      local more="y"
      while [[ "$more" =~ ^[Yy] ]]; do
        local k v
        ask k "Env var NAME (e.g. DO_AUTH_TOKEN)" ""
        ask_secret_value v "Value for ${k}"
        printf '%s=%s\n' "$k" "$v" >> "$cred_file"
        read -r -p "Add another credential var? [y/N]: " more || true
        more="${more:-n}"
      done
      ;;
  esac
  ok "DNS credentials written to secrets/traefik.env (chmod 600)."
}

# ask_acme_staging: offer the LE staging endpoint for testing (avoids rate limits)
ask_acme_staging() {
  echo
  warn "Let's Encrypt PRODUCTION has strict rate limits. Use STAGING while testing:"
  echo  "  it issues UNTRUSTED certs (browser warnings) but has generous limits."
  echo  "  Switch to production with a re-init once your topology is confirmed working."
  if ask_yesno "Use Let's Encrypt STAGING endpoint?" "n"; then
    NB_ACME_STAGING="true"
  else
    NB_ACME_STAGING="false"
  fi
}

# ---------------------------------------------------------------------------
# File generation
# ---------------------------------------------------------------------------
write_env() {
  # Promote inputs to globals so write_config / write_dashboard_env (which read
  # these by name) work under `set -u`.
  NB_RELAY_SECRET="$1"
  NB_STORE_ENCRYPTION_KEY="$2"
  NB_IDP_COOKIE_KEY="$3"
  POSTGRES_PASSWORD="$4"
  # Single canonical origin. Omit :443 so it matches a browser hitting the bare
  # hostname; keep the port otherwise (the single-origin rule).
  NB_EXPOSED_ADDRESS="https://${NB_DOMAIN}:${NB_PUBLIC_PORT}"
  [[ "$NB_PUBLIC_PORT" == "443" ]] && NB_EXPOSED_ADDRESS="https://${NB_DOMAIN}"
  local exposed="$NB_EXPOSED_ADDRESS"
  local relay_secret="$NB_RELAY_SECRET" store_key="$NB_STORE_ENCRYPTION_KEY"
  local idp_key="$NB_IDP_COOKIE_KEY" pg_pass="$POSTGRES_PASSWORD"

  umask 077
  cat > "$ENV_FILE" <<ENV
# Generated by netbird-kit ${KIT_VERSION} on $(date -u +%FT%TZ). DO NOT commit this file.
# Re-run './netbird-kit.sh init' to regenerate. Back this up together with config.yaml.

# --- Identity / networking ---
NB_DOMAIN=${NB_DOMAIN}
NB_PUBLIC_PORT=${NB_PUBLIC_PORT}
NB_STUN_PORT=${NB_STUN_PORT}
NB_EXPOSED_ADDRESS=${exposed}

# --- Modes (informational; structure is baked into docker-compose.yml) ---
NB_PROXY_MODE=${NB_PROXY_MODE}
NB_TLS_MODE=${NB_TLS_MODE}
NB_EXT_PROXY_KIND=${NB_EXT_PROXY_KIND}

# --- External-proxy host ports ---
NB_HTTP_HOST_PORT=${NB_HTTP_HOST_PORT}
NB_DASH_HOST_PORT=${NB_DASH_HOST_PORT}

# --- Bundled Traefik / ACME ---
NB_ACME_EMAIL=${NB_ACME_EMAIL}
NB_ACME_STAGING=${NB_ACME_STAGING}
NB_TLS_DNS_PROVIDER=${NB_TLS_DNS_PROVIDER}
NB_TLS_CERT_PATH=${NB_TLS_CERT_PATH}
NB_TLS_KEY_PATH=${NB_TLS_KEY_PATH}

# --- Storage ---
NB_STORAGE_MODE=${NB_STORAGE_MODE}
NB_DATA_BASE=${NB_DATA_BASE}

# --- Postgres ---
NB_PG_USER=${NB_PG_USER}
NB_PG_DB=${NB_PG_DB}
POSTGRES_PASSWORD=${pg_pass}

# --- Secrets (base64) ---
NB_RELAY_SECRET=${relay_secret}
NB_STORE_ENCRYPTION_KEY=${store_key}
NB_IDP_COOKIE_KEY=${idp_key}

# --- Image tags (edit or run './netbird-kit.sh pin' to freeze digests) ---
NB_SERVER_IMG=${DEF_SERVER_IMG}
NB_DASH_IMG=${DEF_DASH_IMG}
NB_TRAEFIK_IMG=${DEF_TRAEFIK_IMG}
NB_PG_IMG=${DEF_PG_IMG}
ENV
  chmod 600 "$ENV_FILE"
}

write_config() {
  # listenAddress is always :80 inside the container; TLS is terminated by the
  # proxy (bundled Traefik or external). auth/store/reverseProxy are NESTED
  # under `server:` — NetBird ignores them at top level.
  local issuer="${NB_EXPOSED_ADDRESS}/oauth2"
  umask 077
  cat > "$CONFIG_FILE" <<CFG
# Generated by netbird-kit ${KIT_VERSION}. Secrets are injected from .env at
# container start via envsubst is NOT used here — values are literal. Back this
# file up: NB_STORE_ENCRYPTION_KEY is unrecoverable if lost.

server:
  listenAddress: ":80"
  exposedAddress: "${NB_EXPOSED_ADDRESS}"
  stunPorts:
    - ${NB_STUN_PORT}
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "${NB_RELAY_SECRET}"
  dataDir: "/var/lib/netbird/"

  auth:
    issuer: "${issuer}"
    localAuthDisabled: false
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "${NB_IDP_COOKIE_KEY}"
    dashboardRedirectURIs:
      - "${NB_EXPOSED_ADDRESS}/nb-auth"
      - "${NB_EXPOSED_ADDRESS}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  store:
    engine: "postgres"
    dsn: "host=postgres port=5432 user=${NB_PG_USER} password=${POSTGRES_PASSWORD} dbname=${NB_PG_DB} sslmode=disable"
    encryptionKey: "${NB_STORE_ENCRYPTION_KEY}"

  reverseProxy:
    trustedHTTPProxies:
      - "${NET_SUBNET}"
    trustedPeers:
      - "100.64.0.0/10"
CFG
  chmod 600 "$CONFIG_FILE"
}

write_traefik_dynamic() {
  cat > "$TRAEFIK_DYNAMIC" <<'DYN'
# Traefik dynamic config for bring-your-own-cert mode.
tls:
  certificates:
    - certFile: /certs/fullchain.pem
      keyFile: /certs/privkey.pem
  stores:
    default:
      defaultCertificate:
        certFile: /certs/fullchain.pem
        keyFile: /certs/privkey.pem
DYN
}

# Emit the volumes: block based on storage mode.
emit_volumes_block() {
  if [[ "$NB_STORAGE_MODE" == "named" ]]; then
    cat <<'YAML'
volumes:
  netbird_data:
  netbird_postgres:
  netbird_traefik:
YAML
  else
    # bind mode: device paths come from .env
    cat <<'YAML'
volumes:
  netbird_data:
    driver: local
    driver_opts: { type: none, o: bind, device: "${NB_DATA_BASE}/netbird" }
  netbird_postgres:
    driver: local
    driver_opts: { type: none, o: bind, device: "${NB_DATA_BASE}/postgres" }
  netbird_traefik:
    driver: local
    driver_opts: { type: none, o: bind, device: "${NB_DATA_BASE}/traefik" }
YAML
  fi
}

# Emit the traefik service + its ACME/TLS command args for bundled mode.
emit_traefik_service() {
  local tls_args="" extra_env="" extra_vol="" extra_ports=""
  # LE staging endpoint (untrusted certs, loose rate limits) when requested.
  local staging_arg=""
  if [[ "${NB_ACME_STAGING:-false}" == "true" && "$NB_TLS_MODE" != "byocert" ]]; then
    staging_arg=$'\n      - "--certificatesresolvers.le.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"'
  fi
  case "$NB_TLS_MODE" in
    dns01)
      tls_args=$'      - "--certificatesresolvers.le.acme.email=${NB_ACME_EMAIL}"\n      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"\n      - "--certificatesresolvers.le.acme.dnschallenge=true"\n      - "--certificatesresolvers.le.acme.dnschallenge.provider=${NB_TLS_DNS_PROVIDER}"\n      - "--certificatesresolvers.le.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53"'"${staging_arg}"
      extra_env=$'    env_file:\n      - ./secrets/traefik.env'
      ;;
    http01)
      tls_args=$'      - "--entrypoints.web.address=:80"\n      - "--certificatesresolvers.le.acme.email=${NB_ACME_EMAIL}"\n      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"\n      - "--certificatesresolvers.le.acme.httpchallenge=true"\n      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"'"${staging_arg}"
      extra_ports=$'      - "80:80"'
      ;;
    byocert)
      tls_args=$'      - "--providers.file.filename=/etc/traefik/dynamic.yml"'
      extra_vol=$'      - ./traefik-dynamic.yml:/etc/traefik/dynamic.yml:ro\n      - ${NB_TLS_CERT_PATH}:/certs/fullchain.pem:ro\n      - ${NB_TLS_KEY_PATH}:/certs/privkey.pem:ro'
      ;;
  esac

  cat <<YAML
  traefik:
    image: \${NB_TRAEFIK_IMG}
    container_name: netbird-traefik
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.websecure.address=:443"
${tls_args}
${extra_env}
    ports:
      - "\${NB_PUBLIC_PORT}:443"
${extra_ports}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - netbird_traefik:/letsencrypt
${extra_vol}
    networks: [netbird]
    logging: *default-logging
YAML
}

# Labels for netbird-server + dashboard when using bundled Traefik.
emit_bundled_labels_server() {
  local cr=""
  [[ "$NB_TLS_MODE" != "byocert" ]] && cr=$'\n      - traefik.http.routers.netbird-grpc.tls.certresolver=le'
  local cr_http=""
  [[ "$NB_TLS_MODE" != "byocert" ]] && cr_http=$'\n      - traefik.http.routers.netbird-http.tls.certresolver=le'
  cat <<YAML
    labels:
      - traefik.enable=true
      - "traefik.http.routers.netbird-grpc.rule=Host(\`\${NB_DOMAIN}\`) && (PathPrefix(\`/signalexchange.SignalExchange/\`) || PathPrefix(\`/management.ManagementService/\`))"
      - traefik.http.routers.netbird-grpc.entrypoints=websecure
      - traefik.http.routers.netbird-grpc.tls=true${cr}
      - traefik.http.routers.netbird-grpc.service=netbird-grpc
      - traefik.http.services.netbird-grpc.loadbalancer.server.port=80
      - traefik.http.services.netbird-grpc.loadbalancer.server.scheme=h2c
      - "traefik.http.routers.netbird-http.rule=Host(\`\${NB_DOMAIN}\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/oauth2\`) || PathPrefix(\`/relay\`) || PathPrefix(\`/ws-proxy\`))"
      - traefik.http.routers.netbird-http.entrypoints=websecure
      - traefik.http.routers.netbird-http.tls=true${cr_http}
      - traefik.http.routers.netbird-http.service=netbird-http
      - traefik.http.services.netbird-http.loadbalancer.server.port=80
YAML
}

emit_bundled_labels_dash() {
  local cr=""
  [[ "$NB_TLS_MODE" != "byocert" ]] && cr=$'\n      - traefik.http.routers.netbird-dashboard.tls.certresolver=le'
  cat <<YAML
    labels:
      - traefik.enable=true
      - "traefik.http.routers.netbird-dashboard.rule=Host(\`\${NB_DOMAIN}\`)"
      - traefik.http.routers.netbird-dashboard.entrypoints=websecure
      - traefik.http.routers.netbird-dashboard.tls=true${cr}
      - traefik.http.routers.netbird-dashboard.priority=1
      - traefik.http.services.netbird-dashboard.loadbalancer.server.port=80
YAML
}

write_compose() {
  umask 077
  {
    cat <<'HEAD'
name: netbird
# Generated by netbird-kit. Structure reflects your init choices.

x-logging: &default-logging
  driver: "json-file"
  options: { max-size: "100m", max-file: "3" }

services:
HEAD

    # Traefik service (bundled mode only)
    if [[ "$NB_PROXY_MODE" == "bundled" ]]; then
      emit_traefik_service
    fi

    # netbird-server
    cat <<'SRV'
  netbird-server:
    image: ${NB_SERVER_IMG}
    container_name: netbird-server
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    command: ["--config", "/etc/netbird/config.yaml"]
    volumes:
      - netbird_data:/var/lib/netbird
      - ./config.yaml:/etc/netbird/config.yaml
    ports:
      - "${NB_STUN_PORT}:${NB_STUN_PORT}/udp"
SRV
    if [[ "$NB_PROXY_MODE" == "bundled" ]]; then
      printf '    networks: [netbird]\n    logging: *default-logging\n'
      emit_bundled_labels_server
    else
      # external proxy: expose the server HTTP/gRPC port to the host
      printf '      - "${NB_HTTP_HOST_PORT}:80"\n'
      printf '    networks: [netbird]\n    logging: *default-logging\n'
    fi

    # dashboard
    cat <<'DASH'
  dashboard:
    image: ${NB_DASH_IMG}
    container_name: netbird-dashboard
    restart: unless-stopped
    depends_on: [netbird-server]
    env_file: ./dashboard.env
DASH
    if [[ "$NB_PROXY_MODE" == "bundled" ]]; then
      printf '    networks: [netbird]\n    logging: *default-logging\n'
      emit_bundled_labels_dash
    else
      printf '    ports:\n      - "${NB_DASH_HOST_PORT}:80"\n'
      printf '    networks: [netbird]\n    logging: *default-logging\n'
    fi

    # postgres
    cat <<'PG'
  postgres:
    image: ${NB_PG_IMG}
    container_name: netbird-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${NB_PG_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${NB_PG_DB}
    volumes:
      - netbird_postgres:/var/lib/postgresql/data
    networks: [netbird]
    logging: *default-logging
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${NB_PG_USER} -d ${NB_PG_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
PG

    # networks + volumes
    cat <<YAML

networks:
  netbird:
    driver: bridge
    ipam:
      config:
        - subnet: ${NET_SUBNET}

YAML
    emit_volumes_block
  } > "$COMPOSE_FILE"

  write_dashboard_env
}

write_dashboard_env() {
  umask 077
  cat > "${SCRIPT_DIR}/dashboard.env" <<DENV
# Generated by netbird-kit. Browser-facing values MUST use the same origin
# (scheme+host+port) as NB_EXPOSED_ADDRESS or OIDC will fail with CORS errors.
NETBIRD_MGMT_API_ENDPOINT=${NB_EXPOSED_ADDRESS}
NETBIRD_MGMT_GRPC_API_ENDPOINT=${NB_EXPOSED_ADDRESS}
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=${NB_EXPOSED_ADDRESS}/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NGINX_SSL_PORT=443
LETSENCRYPT_DOMAIN=none
DENV
  chmod 600 "${SCRIPT_DIR}/dashboard.env"

  # Create bind dirs if needed so compose doesn't fail on first up.
  if [[ "$NB_STORAGE_MODE" == "bind" ]]; then
    mkdir -p "${NB_DATA_BASE}/netbird" "${NB_DATA_BASE}/postgres" "${NB_DATA_BASE}/traefik"
  fi
}

# ---------------------------------------------------------------------------
# Advice output
# ---------------------------------------------------------------------------
print_advice() {
  info "Setup notes for your configuration"
  echo
  # Single-origin warning is universal and the #1 gotcha.
  if [[ "$NB_PUBLIC_PORT" != "443" ]]; then
    warn "SINGLE-ORIGIN: you chose a non-standard port (${NB_PUBLIC_PORT})."
    echo  "  Always reach the dashboard at exactly https://${NB_DOMAIN}:${NB_PUBLIC_PORT}"
    echo  "  Loading it on any other port (e.g. bare :443) breaks OIDC with CORS errors,"
    echo  "  because the browser origin must match the baked-in auth authority."
    echo  "  Do NOT also publish :443 to this host — keep ${NB_PUBLIC_PORT} the only door."
    echo
  fi

  case "$NB_PROXY_MODE" in
    bundled) print_advice_dns_or_tls ;;
    external) print_advice_external_proxy ;;
  esac

  # STUN / NAT advice (universal)
  echo
  info "Firewall / NAT (both modes)"
  echo  "  Forward these from your WAN/edge to this host:"
  echo  "   - TCP ${NB_PUBLIC_PORT}  (HTTPS: dashboard, API, gRPC, relay)"
  echo  "   - UDP ${NB_STUN_PORT}  (STUN — must be DIRECT, never through an HTTP proxy)"
  echo  "  If ${NB_DOMAIN} is on Cloudflare DNS, set the record to DNS-only (grey cloud):"
  echo  "  the orange-cloud proxy will not pass non-standard ports or UDP."
}

print_advice_dns_or_tls() {
  if [[ "${NB_ACME_STAGING:-false}" == "true" ]]; then
    warn "ACME STAGING is enabled: certs will be issued by Let's Encrypt staging and"
    echo  "  will show as UNTRUSTED in browsers. This is for testing only. When your"
    echo  "  setup works, re-run './netbird-kit.sh init' choosing production, then"
    echo  "  delete the staging cert store so a real cert is fetched:"
    echo  "    docker compose down && docker volume rm netbird_netbird_traefik && ./netbird-kit.sh up"
    echo  "  (for bind storage, delete the traefik data dir instead)."
    echo
  fi
  case "$NB_TLS_MODE" in
    dns01)
      info "TLS: ACME DNS-01 via '${NB_TLS_DNS_PROVIDER}'"
      echo  "  Credentials are in secrets/traefik.env (chmod 600). Traefik writes the"
      echo  "  _acme-challenge TXT record itself; you do not create it manually."
      if [[ "$NB_TLS_DNS_PROVIDER" == "cloudflare" ]]; then
        echo
        info "Cloudflare specifics"
        echo  "  1. DNS: A record ${NB_DOMAIN} -> your WAN IP, PROXY OFF (grey cloud)."
        echo  "  2. Token: My Profile > API Tokens > Create > 'Edit zone DNS'."
        echo  "     Zone Resources: Include > Specific zone > your zone only."
      fi
      ;;
    http01)
      info "TLS: ACME HTTP-01"
      echo  "  ${NB_DOMAIN}:80 must be publicly reachable and forwarded to this host,"
      echo  "  or issuance fails. If you're on a non-standard HTTPS port behind NAT,"
      echo  "  DNS-01 is usually the better choice."
      ;;
    byocert)
      info "TLS: bring-your-own-cert"
      echo  "  Traefik loads: ${NB_TLS_CERT_PATH} and ${NB_TLS_KEY_PATH}"
      echo  "  Renew them yourself and 'docker compose restart traefik' after renewal."
      ;;
  esac
}

print_advice_external_proxy() {
  info "External proxy mode: this stack exposes plain HTTP to your host"
  echo  "   - NetBird server: 127.0.0.1:${NB_HTTP_HOST_PORT}  (API + gRPC + oauth + relay)"
  echo  "   - Dashboard:      127.0.0.1:${NB_DASH_HOST_PORT}  (SPA)"
  echo  "  Your proxy terminates TLS on ${NB_DOMAIN}:${NB_PUBLIC_PORT} and must:"
  echo  "   * support HTTP/2 + gRPC (h2c) to the server backend"
  echo  "   * route gRPC paths /signalexchange.SignalExchange/ and"
  echo  "     /management.ManagementService/ to the server with an h2c/http2 backend"
  echo  "   * route /api /oauth2 /relay /ws-proxy to the server backend"
  echo  "   * route everything else (the SPA) to the dashboard backend"
  echo  "   * set long timeouts (>=1 day) for gRPC/WebSocket streams"
  echo
  case "$NB_EXT_PROXY_KIND" in
    pfsense-haproxy) advice_pfsense ;;
    nginx)           advice_nginx ;;
    caddy)           advice_caddy ;;
    traefik-external) advice_traefik_ext ;;
    *)               advice_generic_proxy ;;
  esac
}

advice_pfsense() {
  info "pfSense + HAProxy"
  echo  "  HAProxy cannot proxy the gRPC/h2c or UDP cleanly in http/offload mode."
  echo  "  Recommended: use HAProxy in TCP mode with SNI passthrough for :${NB_PUBLIC_PORT}"
  echo  "  to a small nginx/Caddy in front of these backends, OR terminate TLS at HAProxy"
  echo  "  and http-route to ${NB_HTTP_HOST_PORT}/${NB_DASH_HOST_PORT} only if your HAProxy"
  echo  "  build supports HTTP/2 backends. Simpler: switch this deployment to 'bundled'"
  echo  "  Traefik and just NAT WAN ${NB_PUBLIC_PORT} -> this host, bypassing HAProxy."
  echo  "  STUN: Firewall > NAT > Port Forward, WAN UDP ${NB_STUN_PORT} -> this host"
  echo  "  (a plain forward; it must NOT go through HAProxy)."
}
advice_nginx() {
  info "nginx server block (adapt paths/cert):"
  cat <<NGINX
    server {
      listen ${NB_PUBLIC_PORT} ssl http2;
      server_name ${NB_DOMAIN};
      ssl_certificate     /path/fullchain.pem;
      ssl_certificate_key /path/privkey.pem;
      client_header_timeout 1d; client_body_timeout 1d;
      # gRPC -> server
      location ~ ^/(signalexchange\\.SignalExchange|management\\.ManagementService)/ {
        grpc_pass grpc://127.0.0.1:${NB_HTTP_HOST_PORT};
      }
      # server HTTP endpoints
      location ~ ^/(api|oauth2|relay|ws-proxy) {
        proxy_pass http://127.0.0.1:${NB_HTTP_HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
      }
      # dashboard SPA (catch-all)
      location / { proxy_pass http://127.0.0.1:${NB_DASH_HOST_PORT}; proxy_set_header Host \$host; }
    }
NGINX
}
advice_caddy() {
  info "Caddyfile (Caddy fetches its own cert; adapt as needed):"
  cat <<CADDY
    ${NB_DOMAIN}:${NB_PUBLIC_PORT} {
      @grpc path /signalexchange.SignalExchange/* /management.ManagementService/*
      handle @grpc { reverse_proxy h2c://127.0.0.1:${NB_HTTP_HOST_PORT} }
      @srv  path /api* /oauth2* /relay* /ws-proxy*
      handle @srv  { reverse_proxy 127.0.0.1:${NB_HTTP_HOST_PORT} }
      handle       { reverse_proxy 127.0.0.1:${NB_DASH_HOST_PORT} }
    }
CADDY
}
advice_traefik_ext() {
  info "External Traefik: use the same two-router split this kit uses in bundled mode"
  echo  "  (see the labels in a bundled-mode docker-compose.yml for the exact rules),"
  echo  "  pointing the gRPC router at an h2c backend on 127.0.0.1:${NB_HTTP_HOST_PORT}."
}
advice_generic_proxy() {
  info "Generic proxy checklist"
  echo  "  Any proxy works IF it can: terminate TLS on ${NB_DOMAIN}:${NB_PUBLIC_PORT},"
  echo  "  speak HTTP/2 + gRPC (h2c) to the server backend, do WebSockets, and split:"
  echo  "    gRPC paths + /api /oauth2 /relay /ws-proxy  -> 127.0.0.1:${NB_HTTP_HOST_PORT}"
  echo  "    everything else                             -> 127.0.0.1:${NB_DASH_HOST_PORT}"
  echo  "  Plus a DIRECT UDP forward for STUN on ${NB_STUN_PORT} (never through the proxy)."
}

print_next_steps() {
  info "Next steps"
  echo  "  1. Review .env, config.yaml, docker-compose.yml"
  echo  "  2. Point DNS: ${NB_DOMAIN} -> this host / your WAN IP"
  echo  "  3. Start it:   ./netbird-kit.sh up"
  echo  "  4. Health:     ./netbird-kit.sh health"
  echo  "  5. First admin: open ${NB_EXPOSED_ADDRESS}/setup"
  echo  "  6. When stable: ./netbird-kit.sh pin   (freeze image versions)"
}

# ---------------------------------------------------------------------------
# Lifecycle commands
# ---------------------------------------------------------------------------
cmd_up() {
  require_docker; require_generated
  info "Starting stack..."
  ( cd "$SCRIPT_DIR" && docker compose up -d )
  ok "Stack started. Run './netbird-kit.sh health' to verify."
}

cmd_down() {
  require_docker; require_generated
  ( cd "$SCRIPT_DIR" && docker compose down )
  ok "Stopped (data volumes kept)."
}

cmd_destroy() {
  require_docker; require_generated
  warn "This DELETES all NetBird data (Postgres, keys, certs). Irreversible."
  ask_yesno "Type-through: really destroy all data?" "n" || die "Aborted."
  ( cd "$SCRIPT_DIR" && docker compose down -v )
  ok "Stack and data volumes removed."
}

cmd_update() {
  require_docker; require_generated
  info "Backing up config + database before update..."
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  local bdir="${SCRIPT_DIR}/backups/${stamp}"
  mkdir -p "$bdir"
  cp "$CONFIG_FILE" "$ENV_FILE" "$bdir/" 2>/dev/null || true
  if ( cd "$SCRIPT_DIR" && docker compose exec -T postgres \
         pg_dump -U "$(get_env NB_PG_USER)" "$(get_env NB_PG_DB)" ) > "$bdir/db.sql" 2>/dev/null; then
    ok "DB dumped to $bdir/db.sql"
  else
    warn "DB dump skipped (is the stack running?)"
    rm -f "$bdir/db.sql"
  fi
  info "Pulling newer images..."
  ( cd "$SCRIPT_DIR" && docker compose pull && docker compose up -d )
  ok "Updated. Backup at $bdir"
  cmd_health || warn "Health check reported issues — inspect logs; backup is at $bdir"
}

cmd_pin() {
  require_docker; require_generated
  info "Resolving current image digests..."
  local svc img digest
  for svc in NB_SERVER_IMG NB_DASH_IMG NB_TRAEFIK_IMG NB_PG_IMG; do
    img="$(get_env "$svc")"
    [[ -z "$img" ]] && continue
    digest="$(docker inspect --format '{{ index .RepoDigests 0 }}' "$img" 2>/dev/null || true)"
    if [[ -n "$digest" ]]; then
      set_env "$svc" "$digest"
      ok "$svc -> $digest"
    else
      warn "No local digest for $img (pull it first). Left unpinned."
    fi
  done
  info "Recreating with pinned images..."
  ( cd "$SCRIPT_DIR" && docker compose up -d )
}

cmd_health() {
  require_docker; require_generated
  local exposed rc=0
  exposed="$(get_env NB_EXPOSED_ADDRESS)"

  info "Container status"
  ( cd "$SCRIPT_DIR" && docker compose ps ) || rc=1

  info "OIDC discovery (${exposed}/oauth2/.well-known/openid-configuration)"
  if curl -fsS --max-time 10 "${exposed}/oauth2/.well-known/openid-configuration" \
       | grep -q '"issuer"'; then
    ok "Discovery document reachable and well-formed."
  else
    warn "Discovery fetch failed. Check TLS, DNS, and the public port forward."
    rc=1
  fi

  info "STUN UDP port ${NB_STUN_PORT:-$(get_env NB_STUN_PORT)} listener (local)"
  local sp; sp="$(get_env NB_STUN_PORT)"
  if command -v ss >/dev/null 2>&1 && ss -uln 2>/dev/null | grep -q ":${sp} "; then
    ok "Something is listening on UDP ${sp} locally."
  else
    warn "No local UDP ${sp} listener seen (ok if checking from another host)."
  fi

  if [[ "$rc" -eq 0 ]]; then ok "Health check passed."; else warn "Health check found issues."; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# .env read/write helpers
# ---------------------------------------------------------------------------
get_env() { # get_env KEY
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line="$(grep -E "^$1=" "$ENV_FILE" | head -n1 || true)"
  printf '%s' "${line#*=}"
}
set_env() { # set_env KEY VALUE
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    # Use a temp file; value may contain / and @ (digests do).
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' \
      "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
netbird-kit ${KIT_VERSION} — self-hosted NetBird deployment manager

Usage: $0 <command>

  init      Interactive setup: generates .env, config.yaml, docker-compose.yml
  up        Start the stack
  health    Verify containers, OIDC discovery, and STUN
  update    Back up, pull newer images, recreate, health-check
  pin       Freeze current image digests for reproducible redeploys
  down      Stop the stack (keeps data)
  destroy   Stop and DELETE all data (asks first)
  help      Show this help
USAGE
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    init)    cmd_init ;;
    up)      cmd_up ;;
    down)    cmd_down ;;
    destroy) cmd_destroy ;;
    update)  cmd_update ;;
    pin)     cmd_pin ;;
    health)  cmd_health ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
