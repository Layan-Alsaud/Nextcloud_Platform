set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
ENV_EXAMPLE=".env.example"
CADDYFILE_TEMPLATE="Caddyfile.template"
CADDYFILE="Caddyfile"
HEALTH_URL_PATH="/status.php"
HEALTH_TIMEOUT_SECONDS=180
HEALTH_POLL_INTERVAL=5
# Must match the "nextcloud_net" subnet in docker-compose.yml — this is
# the range Nextcloud is told to trust as a reverse proxy (Caddy), so it
# correctly reads X-Forwarded-Proto/X-Forwarded-For instead of ignoring them.
DOCKER_NETWORK_SUBNET="172.28.0.0/24"

log()  { printf '\n[deploy] %s\n' "$*"; }
warn() { printf '\n[deploy][WARN] %s\n' "$*" >&2; }
die()  { printf '\n[deploy][ERROR] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Docker + Compose plugin
# ---------------------------------------------------------------------------

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + Compose plugin already installed ($(docker --version))."
    return
  fi

  log "Docker (or the Compose plugin) not found — installing..."
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
  else
    SUDO=""
  fi

  curl -fsSL https://get.docker.com | $SUDO sh

  # Let the invoking (non-root) user run docker without sudo from now on.
  if [ -n "${SUDO:-}" ] && [ -n "${SUDO_USER:-${USER:-}}" ]; then
    $SUDO usermod -aG docker "${SUDO_USER:-$USER}" || true
    warn "Added $(id -un) to the 'docker' group. If subsequent docker" \
         "commands in THIS shell still fail with a permission error," \
         "log out and back in (or run 'newgrp docker') and re-run this script."
  fi

  command -v docker >/dev/null 2>&1 || die "Docker install appears to have failed."
  $SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing after install."
  log "Docker installed: $(docker --version)"
}

# ---------------------------------------------------------------------------
# 2. .env bootstrap + secret generation
# ---------------------------------------------------------------------------

# Upsert KEY=VALUE in $ENV_FILE, replacing an existing line for KEY if
# present (exact match on the key), or appending it if not.
set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Escape & and | for sed's replacement side.
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

get_env_var() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs
}

gen_secret() {
  openssl rand -base64 24 | tr -d '/+=' | cut -c1-32
}

is_placeholder() {
  local value="$1"
  case "$value" in
    ""|*changeme*|YOUR.VM.PUBLIC.IP) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE not found — cannot bootstrap $ENV_FILE."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    log "Created $ENV_FILE from $ENV_EXAMPLE."
  else
    log "$ENV_FILE already exists — filling in only what's missing."
  fi

  for key in POSTGRES_PASSWORD NEXTCLOUD_ADMIN_PASSWORD REDIS_PASSWORD; do
    current="$(get_env_var "$key" || true)"
    if is_placeholder "$current"; then
      set_env_var "$key" "$(gen_secret)"
      log "Generated a new random value for $key."
    fi
  done

  # POSTGRES_DB / POSTGRES_USER / NEXTCLOUD_ADMIN_USER: leave whatever is
  # already there (or the .env.example default) — these aren't secrets.
  for key in POSTGRES_DB POSTGRES_USER NEXTCLOUD_ADMIN_USER; do
    current="$(get_env_var "$key" || true)"
    [ -n "$current" ] || die "$key is empty in $ENV_FILE — set it manually and re-run."
  done

  chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# 3. Public IP detection + trusted_domains sync
# ---------------------------------------------------------------------------

detect_public_ip() {
  local ip=""
  # Azure Instance Metadata Service (works only from inside an Azure VM).
  ip=$(curl -fs --max-time 3 -H "Metadata:true" --noproxy "*" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
    2>/dev/null || true)

  # Fallback for non-Azure hosts / IMDS unreachable.
  if [ -z "$ip" ]; then
    ip=$(curl -fs --max-time 5 https://ifconfig.me 2>/dev/null || true)
  fi

  [ -n "$ip" ] || die "Could not auto-detect this host's public IP (checked Azure IMDS and ifconfig.me)."
  printf '%s' "$ip"
}

# The real Caddyfile is generated from Caddyfile.template every run
# (rather than being static) because the site address needs the VM's
# current public IP baked in. TLS is currently OFF on purpose — see the
# comments in Caddyfile.template for why and how to re-enable it.
render_caddyfile() {
  local ip="$1"
  [ -f "$CADDYFILE_TEMPLATE" ] || die "$CADDYFILE_TEMPLATE not found in $SCRIPT_DIR."

  local rendered
  rendered=$(sed "s/{{VM_PUBLIC_IP}}/${ip}/g" "$CADDYFILE_TEMPLATE")

  if [ -f "$CADDYFILE" ] && [ "$(cat "$CADDYFILE")" = "$rendered" ]; then
    CADDYFILE_CHANGED=0
    return
  fi

  printf '%s\n' "$rendered" > "$CADDYFILE"
  CADDYFILE_CHANGED=1
  log "Wrote $CADDYFILE for current public IP ($ip)."
}

sync_trusted_domain() {
  local current_ip="$1"
  local configured
  configured="$(get_env_var "NEXTCLOUD_TRUSTED_DOMAINS" || true)"

  if [ "$configured" = "$current_ip" ]; then
    log "NEXTCLOUD_TRUSTED_DOMAINS already matches current public IP ($current_ip)."
    return
  fi

  log "Public IP is $current_ip; .env currently has '${configured:-<empty>}' — updating."
  set_env_var "NEXTCLOUD_TRUSTED_DOMAINS" "$current_ip"

  # If Nextcloud is already installed (from a previous run against a
  # different IP), the env var alone won't retroactively update
  # config.php — push it via occ too, once the app container is up.
  NEED_OCC_TRUSTED_DOMAIN_UPDATE=1
}

apply_occ_trusted_domain_update() {
  local ip="$1"
  if ! docker compose ps --status running app >/dev/null 2>&1 || \
     [ -z "$(docker compose ps -q app 2>/dev/null)" ]; then
    return  # app isn't up yet — nothing to patch (fresh install will pick up .env directly)
  fi

  if ! docker compose exec -T -u www-data app php occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    return  # not installed yet — the env var will be used by the installer
  fi

  log "Nextcloud already installed under a different IP — updating trusted_domains via occ."
  docker compose exec -T -u www-data app php occ config:system:set trusted_domains 1 --value="$ip" \
    || warn "Failed to update trusted_domains via occ — you may need to do this manually."
}

# Nextcloud sits behind Caddy, which forwards requests to it internally.
# TLS is currently OFF on purpose (see Caddyfile.template), so Caddy is
# forwarding plain HTTP — overwriteprotocol is set to "http" to match.
# trusted_proxies still matters so Nextcloud reads X-Forwarded-For
# correctly instead of logging every request as coming from Caddy's
# internal IP. Safe to run every time — occ config:system:set is
# idempotent. If HTTPS is re-enabled later, change the value below back
# to "https" (see Caddyfile.template for the full re-enable checklist).
ensure_reverse_proxy_config() {
  if [ -z "$(docker compose ps -q app 2>/dev/null)" ]; then
    return
  fi
  if ! docker compose exec -T -u www-data app php occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    return  # not installed yet
  fi

  log "Ensuring Nextcloud trusts the Caddy reverse proxy..."
  docker compose exec -T -u www-data app php occ config:system:set overwriteprotocol --value="http" \
    || warn "Failed to set overwriteprotocol via occ."
  docker compose exec -T -u www-data app php occ config:system:set trusted_proxies 0 --value="$DOCKER_NETWORK_SUBNET" \
    || warn "Failed to set trusted_proxies via occ."
}

# ---------------------------------------------------------------------------
# 4/6. Start stack + health check
# ---------------------------------------------------------------------------

start_stack() {
  log "Starting the stack (docker compose up -d)..."
  docker compose up -d
}

wait_for_health() {
  local ip="$1"
  # Plain http:// for now — TLS is deliberately off, see Caddyfile.template.
  # If HTTPS is re-enabled later, change this back to "https://" and add
  # curl's -k flag back (self-signed cert, so verification must be skipped).
  local url="http://${ip}${HEALTH_URL_PATH}"
  local elapsed=0

  log "Waiting for Nextcloud to report healthy at ${url} (timeout ${HEALTH_TIMEOUT_SECONDS}s)..."
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    if body=$(curl -fs --max-time 5 "$url" 2>/dev/null) && printf '%s' "$body" | grep -q '"installed":true'; then
      log "Nextcloud is up: $body"
      return 0
    fi
    sleep "$HEALTH_POLL_INTERVAL"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL))
    printf '.'
  done

  echo
  warn "Nextcloud did not report healthy within ${HEALTH_TIMEOUT_SECONDS}s."
  warn "Check container status and logs:"
  warn "  docker compose ps"
  warn "  docker compose logs app"
  warn "  docker compose logs db"
  return 1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  [ -f "$COMPOSE_FILE" ] || die "$COMPOSE_FILE not found in $SCRIPT_DIR."

  install_docker_if_missing
  bootstrap_env_file

  NEED_OCC_TRUSTED_DOMAIN_UPDATE=0
  CADDYFILE_CHANGED=0
  PUBLIC_IP="$(detect_public_ip)"
  render_caddyfile "$PUBLIC_IP"
  sync_trusted_domain "$PUBLIC_IP"

  start_stack

  if [ "$CADDYFILE_CHANGED" -eq 1 ] && [ -n "$(docker compose ps -q caddy 2>/dev/null)" ]; then
    log "Caddy's config changed (public IP) — restarting Caddy to pick it up..."
    docker compose restart caddy \
      || warn "Failed to restart Caddy — run 'docker compose restart caddy' manually."
  fi

  if [ "$NEED_OCC_TRUSTED_DOMAIN_UPDATE" -eq 1 ]; then
    # Give the app container a moment to be ready for `exec` before trying occ.
    sleep 5
    apply_occ_trusted_domain_update "$PUBLIC_IP"
  fi

  if wait_for_health "$PUBLIC_IP"; then
    ensure_reverse_proxy_config
    log "Done. Open http://${PUBLIC_IP}/ in a browser to log in."
    log "(HTTPS is deliberately deferred for now — see Caddyfile.template" \
        "for why and how to re-enable it later.)"
  else
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi