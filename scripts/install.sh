#!/usr/bin/env bash
#
# scripts/install.sh — install OmniCP on this host, start to finish.
#
#     ./scripts/install.sh
#
# Writes .env.production, checks the host, pulls, starts, and creates the first
# administrator. It asks for the hostname, the TLS mode, the release tag and that
# administrator's address; it GENERATES the database password and the encryption key, because
# neither should ever be a human's choice.
#
# Safe to run twice. An env file that already exists is read and never rewritten — its secrets
# are the only copy of themselves — so a run that failed partway resumes rather than restarts.
#
# Start at INSTALL.md.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

ENV_FILE="${1:-.env.production}"
EXAMPLE='.env.production.example'
DEFAULT_REGISTRY='ghcr.io/armar-reggans'

step() { echo; echo "── $* ────────────────────────────────────────────"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
die()  { echo; echo "  ✗ $*" >&2; exit 1; }

die_resumable() {
  echo >&2
  echo "  ✗ $*" >&2
  echo >&2
  echo "  $ENV_FILE is written and has been left alone. Fix the above and run this again;" >&2
  echo "  it will reuse the secrets it already generated rather than making new ones." >&2
  exit 1
}

[[ -f $EXAMPLE ]] || die "$EXAMPLE is missing — run this from inside the deployment checkout."
[[ -t 0 ]] || die 'this asks questions, so it needs a terminal. Run it interactively.'

ask() {   # ask <VAR> <prompt> [default]
  local var="$1" prompt="$2" default="${3:-}" answer
  default="${!var:-$default}"
  while true; do
    if [[ -n $default ]]; then
      read -r -p "  $prompt [$default]: " answer || die 'ran out of input.'
      answer="${answer:-$default}"
    else
      read -r -p "  $prompt: " answer || die 'ran out of input.'
    fi
    [[ -n ${answer// /} ]] && { printf -v "$var" '%s' "$answer"; return; }
    echo "    required."
  done
}

ask_secret() {   # ask_secret <VAR> <prompt> — typed twice, never echoed
  local var="$1" prompt="$2" first second
  while true; do
    read -r -s -p "  $prompt: " first || die 'ran out of input.'; echo
    read -r -s -p "  and again: " second || die 'ran out of input.'; echo
    [[ $first == "$second" ]] || { echo "    they do not match."; continue; }
    [[ -n $first ]] || { echo "    required."; continue; }
    printf -v "$var" '%s' "$first"; return
  done
}

ask_admin() {
  step 'the first administrator'
  echo
  echo '    MFA is mandatory for this role: the first thing this account must do after'
  echo '    signing in is enrol an authenticator.'
  echo
  ask ADMIN_EMAIL 'email address'
  [[ $ADMIN_EMAIL == *@*.* ]] || die "'$ADMIN_EMAIL' does not look like an email address."
  echo
  echo '    Leave the password empty to have one generated and shown once.'
  echo
  read -r -s -p '  password (at least 12 characters, or empty to generate): ' ADMIN_PASSWORD \
    || die 'ran out of input.'
  echo
  ADMIN_GENERATED=0
  if [[ -z $ADMIN_PASSWORD ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
    ADMIN_GENERATED=1
  else
    (( ${#ADMIN_PASSWORD} >= 12 )) || die 'that password is shorter than 12 characters.'
    read -r -s -p '  and again: ' confirm || die 'ran out of input.'; echo
    [[ $ADMIN_PASSWORD == "$confirm" ]] || die 'the two passwords do not match.'
  fi
}

set_var() {   # set_var <KEY> <VALUE>
  local key="$1" value="$2"
  SV_KEY="$key" SV_VALUE="$value" awk '
    BEGIN { key = ENVIRON["SV_KEY"]; value = ENVIRON["SV_VALUE"]; done = 0 }
    !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$ENV_FILE" > "$ENV_FILE.tmp" || return 1
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

get_var() {   # get_var <KEY>
  sed -n "s/^$1=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$ENV_FILE" | tail -1
}

if [[ -f $ENV_FILE ]]; then
  step "using the $ENV_FILE that is already here"
  ok 'not rewriting it: its secrets are the only copy of themselves'
  TLS_MODE="$(get_var TLS_MODE)"; TLS_MODE="${TLS_MODE:-acme}"
  PANEL_DOMAIN="$(get_var PANEL_DOMAIN)"
  echo "    domain ${PANEL_DOMAIN:-unset}, TLS mode $TLS_MODE, version $(get_var OMNICP_VERSION)"
else
  step 'what this deployment is called'
  echo
  ask PANEL_DOMAIN 'the hostname this panel answers on (no scheme)'
  case "$PANEL_DOMAIN" in
    *://*|*/*) die 'a bare hostname, please — panel.example.com, not https://panel.example.com/' ;;
  esac

  ask PANEL_ORIGIN 'origins allowed to submit a write (comma-separated)' "https://$PANEL_DOMAIN"
  ask PANEL_PUBLIC_URL 'the canonical address links are built from' "${PANEL_ORIGIN%%,*}"

  for o in ${PANEL_ORIGIN//,/ }; do
    [[ $o == http://* || $o == https://* ]] || die "PANEL_ORIGIN entry '$o' needs a scheme."
    [[ ${o#*://} == */* ]] && die "PANEL_ORIGIN entry '$o' must be a bare origin — no path, no trailing slash."
  done
  grep -qE "(^|,)${PANEL_PUBLIC_URL}(,|$)" <<<"$PANEL_ORIGIN" \
    || die "PANEL_PUBLIC_URL must be one of the PANEL_ORIGIN entries; the panel refuses to start otherwise."

  step 'how TLS is terminated'
  cat <<'EOF'

    acme        (default) Caddy gets and renews a Let's Encrypt certificate.
                Needs the hostname resolving here and ports 80 + 443 reachable.
    own-cert    you supply panel.crt (leaf + chain) and panel.key.
    cloudflare  behind Cloudflare's proxy, with a Cloudflare Origin Certificate.
    tunnel      Cloudflare Tunnel. No inbound ports at all; needs a connector token.

EOF
  ask TLS_MODE 'TLS mode' 'acme'
  TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
  TLS_CERT_DIR="${TLS_CERT_DIR:-./certs}"
  case "$TLS_MODE" in
    acme)
      resolved=$(getent ahostsv4 "$PANEL_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
      if [[ -n $resolved ]]; then
        ok "$PANEL_DOMAIN resolves to $resolved — check that that is this host"
      else
        warn "$PANEL_DOMAIN does not resolve yet; Let's Encrypt will refuse until it does"
      fi
      ;;
    own-cert|cloudflare)
      ask TLS_CERT_DIR 'directory holding panel.crt and panel.key' './certs'
      for f in panel.crt panel.key; do
        [[ -f "$TLS_CERT_DIR/$f" ]] || die "$TLS_CERT_DIR/$f is not there. Put both files in place and re-run."
      done
      ok "found panel.crt and panel.key in $TLS_CERT_DIR"
      ;;
    tunnel)
      echo
      echo '    Zero Trust → Networks → Tunnels → Create a tunnel, then add a Public Hostname'
      echo "    for $PANEL_DOMAIN pointing at http://caddy:80 — not at http://panel:3000, which"
      echo '    would hand the login rate limiter an address the caller chose.'
      echo
      ask_secret TUNNEL_TOKEN 'the tunnel connector token'
      ;;
    *) die "'$TLS_MODE' is not one of acme, own-cert, cloudflare, tunnel." ;;
  esac

  step 'where the images come from'
  echo
  echo '    Images are pulled, never built here. You need the release tag we gave you — there'
  echo '    is no moving tag and no latest, so an upgrade is always something somebody chose.'
  echo
  ask OMNICP_REGISTRY 'registry' "$DEFAULT_REGISTRY"
  ask OMNICP_VERSION 'release tag'
  [[ $OMNICP_VERSION == v* ]] || die "a release tag looks like v2026.10.29c, not '$OMNICP_VERSION'."

  ask_admin

  step 'ready to write'
  cat <<EOF

    env file     $ENV_FILE  (from $EXAMPLE, with every comment kept)
    domain       $PANEL_DOMAIN
    origins      $PANEL_ORIGIN
    links built  $PANEL_PUBLIC_URL
    TLS          $TLS_MODE
    images       $OMNICP_REGISTRY, tag $OMNICP_VERSION, pulled
    admin        $ADMIN_EMAIL
    generated    POSTGRES_PASSWORD, PANEL_ENCRYPTION_KEY

EOF
  read -r -p '  write it and bring the stack up? [y/N] ' go || die 'ran out of input.'
  [[ ${go,,} == y* ]] || { echo '  nothing written.'; exit 1; }

  umask 077
  cp "$EXAMPLE" "$ENV_FILE" || die "could not write $ENV_FILE"
  chmod 600 "$ENV_FILE"

  PG_PASSWORD="$(openssl rand -hex 24)"
  set_var POSTGRES_PASSWORD "$PG_PASSWORD"
  set_var DATABASE_URL "postgresql://onepanel:${PG_PASSWORD}@postgres:5432/onepanel"
  set_var PANEL_ENCRYPTION_KEY "$(openssl rand -base64 32)"
  set_var PANEL_DOMAIN "$PANEL_DOMAIN"
  set_var PANEL_ORIGIN "$PANEL_ORIGIN"
  set_var PANEL_PUBLIC_URL "$PANEL_PUBLIC_URL"
  set_var TLS_MODE "$TLS_MODE"
  set_var OMNICP_SOURCE pull
  set_var OMNICP_REGISTRY "$OMNICP_REGISTRY"
  set_var OMNICP_VERSION "$OMNICP_VERSION"
  [[ $TLS_MODE == own-cert || $TLS_MODE == cloudflare ]] && set_var TLS_CERT_DIR "$TLS_CERT_DIR"
  [[ $TLS_MODE == tunnel ]] && set_var TUNNEL_TOKEN "$TUNNEL_TOKEN"

  ok "$ENV_FILE written, mode 600"
  echo
  echo "  ── PANEL_ENCRYPTION_KEY is the one value that cannot be regenerated ──"
  echo '  It seals every region credential and every MFA enrolment in the database. A backup of'
  echo '  the database without it is unopenable, by anything, for ever. Copy it off this host'
  echo '  now, to somewhere that is not where the database backups go:'
  echo
  echo "      grep '^PANEL_ENCRYPTION_KEY=' $ENV_FILE"
  echo
  read -r -p '  press Enter when it is stored elsewhere. ' _ || true
fi

step 'preflight'
./scripts/preflight.sh "$ENV_FILE" || die_resumable 'preflight refused this installation.'

files=()
if [[ $(get_var TLS_MODE) == tunnel ]]; then
  files=(-f compose.yaml -f compose.tunnel.yaml)
  [[ -f compose.override.yaml ]] && files+=(-f compose.override.yaml)
fi
dc=(docker compose --env-file "$ENV_FILE" "${files[@]}")

step 'the registry'
registry_host="$(get_var OMNICP_REGISTRY)"; registry_host="${registry_host%%/*}"
registry_host="${registry_host:-ghcr.io}"
if grep -q "\"$registry_host\"" "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null; then
  ok "already logged in to $registry_host"
else
  echo
  echo "    The username is the one that OWNS the token we issued, not your own GitHub"
  echo '    account — a registry token only ever authenticates as its owner.'
  echo
  ask REGISTRY_USER "username for $registry_host"
  read -r -s -p '  token: ' REGISTRY_TOKEN; echo
  printf '%s' "$REGISTRY_TOKEN" | docker login "$registry_host" -u "$REGISTRY_USER" --password-stdin \
    || die_resumable "could not log in to $registry_host."
  unset REGISTRY_TOKEN
fi

step 'pulling the images'
"${dc[@]}" --profile '*' pull </dev/null || die_resumable 'the pull failed. A lapsed token and a tag that was never published look the same here; check both.'
ok "pulled $(get_var OMNICP_REGISTRY)/omnicp-{panel,tools}:$(get_var OMNICP_VERSION)"

step 'starting'
"${dc[@]}" up -d </dev/null || die_resumable 'the stack did not come up. `docker compose ... logs` has the reason.'

printf '  waiting for the panel to answer'
answered=''
for _ in $(seq 1 90); do
  code=$("${dc[@]}" exec -T panel node -e \
    'fetch("http://127.0.0.1:3000/login").then(r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log("000");process.exit(0)})' \
    </dev/null 2>/dev/null | tr -d '[:space:]')
  [[ $code == 200 ]] && { answered=yes; break; }
  printf '.'
  sleep 2
done
echo
[[ -n $answered ]] || die_resumable 'the panel never answered on /login. Start with `docker compose ... logs migrate` — the schema step runs first and the panel waits for it.'
ok 'GET /login -> 200'

PASSWORD_IGNORED=0

run_bootstrap() {
  local log; log="$(mktemp)"
  export BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD"
  "${dc[@]}" run --rm -e BOOTSTRAP_ADMIN_EMAIL -e BOOTSTRAP_ADMIN_PASSWORD tools pnpm bootstrap \
    </dev/null 2>&1 | tee "$log" \
    || { rm -f "$log"; die_resumable 'bootstrap failed.'; }
  unset BOOTSTRAP_ADMIN_PASSWORD

  grep -qE '^[[:space:]]+password[[:space:]]+' "$log" && PASSWORD_IGNORED=1
  rm -f "$log"
}

if [[ -n ${ADMIN_EMAIL:-} ]]; then
  run_bootstrap
else
  step 'the first administrator'
  echo
  read -r -p '  create one now? [y/N] ' make_admin || make_admin=n
  if [[ ${make_admin,,} == y* ]]; then
    ask_admin
    run_bootstrap
  else
    ok 'skipped'
    echo "      create one later with: ${dc[*]} run --rm tools pnpm bootstrap"
  fi
fi

step 'installed'
cat <<EOF

  Sign in at $(get_var PANEL_PUBLIC_URL)
EOF
if [[ -n ${ADMIN_EMAIL:-} ]]; then
  echo "    user      $ADMIN_EMAIL"
  if (( PASSWORD_IGNORED )); then
    echo '    password  the one printed by bootstrap above — NOT the one you typed.'
    echo '              This image predates reading the password from the environment, so it'
    echo '              generated its own. Sign in with that one and change it in the panel.'
  elif (( ${ADMIN_GENERATED:-0} )); then
    echo "    password  $ADMIN_PASSWORD"
    echo '              ^ shown once, here, and nowhere else. Store it now.'
  fi
fi
cat <<EOF

  Then, in this order:

    1. Enrol an authenticator. MFA is mandatory for an administrator, and a brand-new one is
       the single state where the panel cannot enforce it yet.
    2. Register a region at /admin/regions and probe it. A region is a database row, not
       configuration — adding one is an ordinary operational act, never a redeployment.
    3. Curate the catalog at /admin/catalog, and set prices at /admin/prices if you will bill.

  /admin/status is the page to know, and the first thing to quote if you contact us.

  To upgrade: set OMNICP_VERSION in $ENV_FILE to the new tag, then ./scripts/update.sh
  Host-specific settings go in compose.override.yaml, never in compose.yaml.
EOF
