#!/usr/bin/env bash
#
# scripts/preflight.sh — check this host and .env.production before anything starts.
#
#     ./scripts/preflight.sh
#
# Needs only bash. No images, no database, no network — because the moment it is most useful
# is the moment none of those exist yet. Errors stop it; warnings do not.

set -uo pipefail

ENV_FILE="${1:-.env.production}"
EXAMPLE='.env.production.example'
COMPOSE='compose.yaml'

cd "$(dirname "$(readlink -f "$0")")/.."

errors=0
warnings=0

err()  { echo "  ✗ $*" >&2; errors=$((errors + 1)); }
warn() { echo "  ! $*"; warnings=$((warnings + 1)); }
ok()   { echo "  ✓ $*"; }

section() { echo; echo "── $1"; }

section 'files'

for f in "$COMPOSE" "$EXAMPLE"; do
  [[ -f $f ]] || { echo "  ✗ $f is missing — is this the repository root?" >&2; exit 1; }
done

if [[ ! -f $ENV_FILE ]]; then
  echo "  ✗ $ENV_FILE does not exist." >&2
  echo "    cp $EXAMPLE $ENV_FILE   # then fill it in" >&2
  exit 1
fi
ok "$ENV_FILE is present"

perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')
if [[ -n $perms && $perms != 600 && $perms != 400 ]]; then
  warn "$ENV_FILE is mode $perms — it holds the encryption key; 600 is the right mode"
fi

is_set() {
  local key="$1" line value
  line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -1)
  if [[ -n $line ]]; then
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    [[ -n ${value// /} ]] && return 0
  fi
  [[ -n ${!key:-} ]]
}

section 'variables compose refuses to start without'

required=$(grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' "$COMPOSE" | sed 's/^\${//; s/:?$//' | sort -u)
for key in $required; do
  if is_set "$key"; then ok "$key"; else err "$key is not set in $ENV_FILE"; fi
done

section 'the key that cannot be regenerated'

if is_set PANEL_ENCRYPTION_KEY; then
  raw=$(grep -E '^[[:space:]]*PANEL_ENCRYPTION_KEY=' "$ENV_FILE" | tail -1)
  raw="${raw#*=}"; raw="${raw%\"}"; raw="${raw#\"}"; raw="${raw%\'}"; raw="${raw#\'}"
  bytes=$(printf '%s' "$raw" | base64 -d 2>/dev/null | wc -c)
  if [[ $bytes == 32 ]]; then
    ok 'PANEL_ENCRYPTION_KEY decodes to 32 bytes'
  else
    err "PANEL_ENCRYPTION_KEY decodes to ${bytes} bytes, not 32 — generate one with: openssl rand -base64 32"
  fi
fi

section 'the database URL agrees with the database'

if grep -q 'CHANGE_ME' "$ENV_FILE"; then
  err "$ENV_FILE still contains CHANGE_ME — look for it inside DATABASE_URL, not only on its own line"
else
  ok 'no placeholders left in the file'
fi

db_url=$(grep -E '^[[:space:]]*DATABASE_URL=' "$ENV_FILE" | tail -1)
db_url="${db_url#*=}"; db_url="${db_url%\"}"; db_url="${db_url#\"}"
if [[ -n $db_url ]]; then
  rest="${db_url#*://}"
  creds="${rest%%@*}"
  hostpart="${rest#*@}"
  url_user="${creds%%:*}"
  url_pass="${creds#*:}"
  url_host="${hostpart%%[:/]*}"
  url_db="${hostpart##*/}"; url_db="${url_db%%\?*}"

  if [[ $url_host != 'postgres' ]]; then
    ok "DATABASE_URL points at ${url_host}, not this stack's postgres — not checked further"
  else
    env_user=$(grep -E '^[[:space:]]*POSTGRES_USER=' "$ENV_FILE" | tail -1); env_user="${env_user#*=}"
    env_db=$(grep -E '^[[:space:]]*POSTGRES_DB=' "$ENV_FILE" | tail -1); env_db="${env_db#*=}"
    env_pass=$(grep -E '^[[:space:]]*POSTGRES_PASSWORD=' "$ENV_FILE" | tail -1); env_pass="${env_pass#*=}"
    : "${env_user:=onepanel}" "${env_db:=onepanel}"

    [[ $url_user == "$env_user" ]] \
      && ok "the user in DATABASE_URL matches POSTGRES_USER" \
      || err "DATABASE_URL connects as '$url_user' but POSTGRES_USER is '$env_user'"

    [[ $url_db == "$env_db" ]] \
      && ok "the database in DATABASE_URL matches POSTGRES_DB" \
      || err "DATABASE_URL names database '$url_db' but POSTGRES_DB is '$env_db'"

    if [[ $url_pass == "$env_pass" ]]; then
      ok 'the password in DATABASE_URL matches POSTGRES_PASSWORD'
    elif [[ $url_pass == *%* ]]; then
      warn 'the password in DATABASE_URL is percent-encoded; check by eye that it decodes to POSTGRES_PASSWORD'
    else
      err 'the password in DATABASE_URL does not match POSTGRES_PASSWORD — the panel will not be able to log in'
    fi
  fi
fi

section 'variables added since this env file was written'

missing_new=''
while read -r key; do
  [[ -z $key ]] && continue
  grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$ENV_FILE" || missing_new+=" $key"
done < <(grep -oE '^#?[[:space:]]*[A-Z_][A-Z0-9_]*=' "$EXAMPLE" | tr -d '#= ' | sort -u)

if [[ -n ${missing_new// /} ]]; then
  warn "documented in $EXAMPLE and absent from $ENV_FILE:"
  for k in $missing_new; do echo "      $k"; done
  echo "      These have defaults unless listed as an error above — but read $EXAMPLE to see"
  echo '      what they do before assuming the default is right for this site.'
else
  ok "$ENV_FILE knows every variable $EXAMPLE documents"
fi

section 'host'

if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose $(docker compose version --short 2>/dev/null)"
  else
    err 'the docker compose plugin is not installed (docker-compose v1 is not supported)'
  fi
else
  err 'docker is not installed'
fi

avail=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n $avail ]]; then
  if   (( avail < 5 ));  then err "${avail}G free here — a full build needs more than that"
  elif (( avail < 15 )); then warn "${avail}G free here; a full rebuild is comfortable above 15G"
  else ok "${avail}G free"
  fi
fi

if command -v ss >/dev/null 2>&1; then
  for port in 80 443; do
    holder=$(ss -lntpH "sport = :$port" 2>/dev/null | head -1)
    if [[ -n $holder ]]; then
      if grep -q 'docker\|caddy' <<<"$holder"; then
        ok "port $port is held by this stack"
      elif grep -q 'users:' <<<"$holder"; then
        warn "port $port is already in use by something else:"
        echo "      $(tr -s ' ' <<<"$holder")"
      else
        warn "port $port is in use; run as root to see by what (this stack's own Caddy would hold it)"
      fi
    else
      ok "port $port is free"
    fi
  done
fi

echo
if (( errors > 0 )); then
  echo "preflight FAILED: $errors error(s), $warnings warning(s). Nothing has been started." >&2
  exit 1
fi
echo "preflight passed${warnings:+ with $warnings warning(s)}."
