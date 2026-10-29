#!/usr/bin/env bash
#
# scripts/update.sh — move a deployed panel to another release.
#
#     cd /opt/docker/omnicp && ./scripts/update.sh
#
# Set OMNICP_VERSION in .env.production to the release you want BEFORE running this. There is
# no moving tag to drift onto, so nothing changes under you on a restart or a reboot.
#
# It pulls the new images, applies migrations and restarts. Nothing is stopped until the new
# images are present, so a failed pull leaves the running panel alone.

set -euo pipefail

readonly ENV_FILE='.env.production'
readonly REBASE='true'

main() {
  cd "$(dirname "$(readlink -f "$0")")/.."

  [[ -f $ENV_FILE ]] || { echo "no $ENV_FILE in $PWD — wrong directory?" >&2; exit 1; }
  local dc=(docker compose --env-file "$ENV_FILE")

  local source_mode
  source_mode=$(sed -n 's/^OMNICP_SOURCE=[[:space:]]*\([A-Za-z]*\).*/\1/p' "$ENV_FILE" | tail -1)
  source_mode=${source_mode:-build}
  case $source_mode in
    build|pull) ;;
    *) echo "OMNICP_SOURCE=$source_mode in $ENV_FILE — expected 'build' or 'pull'" >&2; exit 1 ;;
  esac

  local OMNICP_VERSION
  OMNICP_VERSION=$(sed -n 's/^OMNICP_VERSION=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$ENV_FILE" | tail -1)
  export OMNICP_VERSION

  if [[ -n $(git status --porcelain) ]]; then
    echo 'working tree has uncommitted changes:' >&2
    git status --short >&2
    echo 'commit, stash or discard them first.' >&2
    exit 1
  fi

  local before; before=$(git rev-parse HEAD)

  if [[ $source_mode == pull ]]; then
    [[ -n ${OMNICP_VERSION:-} ]] \
      || { echo "OMNICP_SOURCE=pull needs OMNICP_VERSION set to a published tag in $ENV_FILE" >&2; exit 1; }
    echo "== fetching $OMNICP_VERSION"
    git fetch --quiet --tags --prune
    git rev-parse -q --verify "refs/tags/$OMNICP_VERSION^{commit}" >/dev/null \
      || { echo "no tag $OMNICP_VERSION here — check the spelling, or it is not published yet" >&2; exit 1; }
    git checkout --quiet --detach "refs/tags/$OMNICP_VERSION"
  else
    echo '== pulling'
    git pull --rebase="$REBASE" --no-edit
  fi

  local after; after=$(git rev-parse HEAD)
  if [[ $source_mode == pull ]]; then
    if [[ $before == "$after" ]]; then
      echo "   deployment files already at $OMNICP_VERSION"
    else
      echo "   deployment files moved to $OMNICP_VERSION"
    fi
  elif [[ $before == "$after" ]]; then
    echo '   already at the latest commit — rebuilding anyway, in case the image is older'
  else
    echo "   $(git rev-list --count "$before".."$after") new commit(s):"
    git log --oneline --no-merges "$before".."$after" | sed 's/^/     /'
  fi

  echo '== preflight'
  ./scripts/preflight.sh "$ENV_FILE" || exit 1

  if [[ $source_mode == pull ]]; then
    echo "   deploying as: $OMNICP_VERSION (pulled)"
  else
    OMNICP_VERSION=$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)
    export OMNICP_VERSION
    echo "   deploying as: $OMNICP_VERSION (built here)"
  fi

  if [[ $source_mode == pull ]]; then
    echo '== pulling'
    "${dc[@]}" --profile '*' pull
  else
    echo '== building'
    "${dc[@]}" --profile '*' build
  fi

  echo '== deploying'
  "${dc[@]}" up -d

  echo '== migrations'
  "${dc[@]}" logs migrate --tail 5

  local on_disk applied missing extra
  on_disk=$(find prisma/migrations -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  applied=$("${dc[@]}" exec -T postgres sh -c \
    'psql -qtAX -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select migration_name from _prisma_migrations where finished_at is not null"' \
    2>/dev/null | tr -d '\r' | sed '/^$/d' | sort)

  echo "   on disk: $(wc -l <<<"$on_disk")   applied: $(if [[ -n $applied ]]; then wc -l <<<"$applied"; else echo unknown; fi)"

  if [[ -n $applied ]]; then
    missing=$(comm -23 <(echo "$on_disk") <(echo "$applied"))
    extra=$(comm -13 <(echo "$on_disk") <(echo "$applied"))

    if [[ -n $missing ]]; then
      echo 'these migrations are in the checkout and NOT applied:' >&2
      sed 's/^/   - /' <<<"$missing" >&2
      echo 'the migrate image may be stale — try: docker compose --env-file '"$ENV_FILE"' build --no-cache migrate' >&2
      exit 1
    fi

    if [[ -n $extra ]]; then
      echo 'these migrations are applied and NOT in the checkout:' >&2
      sed 's/^/   - /' <<<"$extra" >&2
      echo 'this database is ahead of the code. Deploying older code over it is how data is lost;' >&2
      echo 'find the commit that carried them before going further.' >&2
      exit 1
    fi
  fi

  echo '== verifying'
  "${dc[@]}" ps --format 'table {{.Service}}\t{{.Status}}'

  local image built
  image=$("${dc[@]}" images -q panel 2>/dev/null | head -1)
  built=$([[ -n $image ]] && docker inspect "$image" --format '{{.Created}}' 2>/dev/null || echo '')
  echo "   panel image built: ${built:-unknown}"

  local -i waited=0
  local status
  while :; do
    status=$("${dc[@]}" ps --format '{{.Service}} {{.Status}}' | sed -n 's/^panel //p')
    case $status in
      *'(healthy)'*) echo "   panel healthy after ${waited}s"; break ;;
      '') echo 'panel container is not running — docker compose --env-file '"$ENV_FILE"' logs panel' >&2; exit 1 ;;
    esac
    if (( waited >= 120 )); then
      echo "panel did not become healthy within ${waited}s (last: $status)" >&2
      echo "see: docker compose --env-file $ENV_FILE logs panel" >&2
      exit 1
    fi
    sleep 3
    waited+=3
  done
  echo '   done'
}

main "$@"
