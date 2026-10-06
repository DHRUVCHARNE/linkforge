#!/usr/bin/env bash
#
# container_test.sh: Phase 5 acceptance against the Docker image.
#
#   1. builds and starts on a fresh database
#   2. image hygiene: non-root, exec-form entrypoint
#   3. end to end: shorten → redirect → stats → metrics, no /debug in prod
#   4. SIGTERM under load: readiness flips first, no 5xx, exit 0 within
#      the grace period, every written click persisted, clicks conserved
#   5. links survive a container restart
#   6. bad config fails fast
#
set -euo pipefail

BASE="${BASE_URL:-http://localhost:3000}"
SERVICE="${APP_SERVICE:-app}"
PG="${PG_SERVICE:-postgres}"
LOAD="${LOAD_DURATION:-15s}"
CONC="${CONCURRENCY:-50}"
KILL_AFTER="${KILL_AFTER_SECS:-5}"
GRACE_SECS="${GRACE_SECS:-30}"

set -a; . ./.env; set +a                         # POSTGRES_USER / POSTGRES_DB for psql
export LINKFORGE__RATE_LIMIT__REQUESTS=100000000  # one bridge IP => one bucket

TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
hdr()  { printf '\n== %s ==\n' "$*"; }
now_ms() { date +%s%3N; }
code_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
psql_q() { docker compose exec -T "$PG" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"; }

wait_ready() {
  for _ in $(seq 120); do
    [[ "$(code_of "$BASE/health/ready")" == 200 ]] && return 0
    sleep 0.5
  done
  return 1
}

# ---------------------------------------------------------------------------
hdr "1. Build and start (fresh database)"
[[ -d .sqlx ]] || { echo ".sqlx/ missing: run 'cargo sqlx prepare -- --all-targets'"; exit 1; }
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker compose up -d --build
if wait_ready; then pass "container ready"; else
  fail "never became ready"; docker compose logs "$SERVICE" | tail -50; exit 1
fi
CID="$(docker compose ps -q "$SERVICE")"

# ---------------------------------------------------------------------------
hdr "2. Image hygiene"
USER_="$(docker inspect -f '{{.Config.User}}' "$CID")"
if [[ -n "$USER_" && "$USER_" != "root" && "$USER_" != "0" ]]; then
  pass "runs as non-root ($USER_)"
else
  fail "runs as root (user='$USER_')"
fi
ENTRY="$(docker inspect -f '{{json .Config.Entrypoint}}' "$CID")"
if [[ "$ENTRY" == '["/app/linkforge"]' ]]; then
  pass "exec-form entrypoint"
else
  fail "entrypoint $ENTRY: shell form never delivers SIGTERM to the app"
fi

# ---------------------------------------------------------------------------
hdr "3. End to end"
CODE="$(curl -s -X POST "$BASE/shorten" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/container"}' | grep -o '"code":"[^"]*"' | sed 's/.*:"//; s/"//')"
[[ -n "$CODE" ]] && pass "shorten -> $CODE" || { fail "shorten failed"; exit 1; }

LOC="$(curl -s -D - -o /dev/null "$BASE/$CODE" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
SMOKE_REDIRECTS=1
[[ "$LOC" == "https://example.com/container" ]] && pass "redirect -> $LOC" || fail "redirect Location='$LOC'"

CLICKS=0
for _ in $(seq 50); do
  CLICKS="$(curl -s "$BASE/$CODE/stats" | grep -o '"clicks":[0-9]*' | cut -d: -f2)"
  [[ "${CLICKS:-0}" -ge 1 ]] && break
  sleep 0.1
done
[[ "${CLICKS:-0}" -ge 1 ]] && pass "/stats counted the click" || fail "/stats never counted the click"

METRICS="$(curl -s "$BASE/metrics")"
for m in linkforge_http_requests_total linkforge_clicks_enqueued_total linkforge_click_queue_depth; do
  grep -q "^$m" <<<"$METRICS" && pass "/metrics exposes $m" || fail "/metrics missing $m"
done

[[ "$(code_of "$BASE/debug/cache")" == 404 ]] && pass "/debug/* absent in production" \
                                              || fail "/debug/cache reachable in production"
[[ "$(code_of "$BASE/health/live")" == 200 ]] && pass "liveness 200" || fail "liveness"

# ---------------------------------------------------------------------------
hdr "4. SIGTERM under load"
oha -z "$LOAD" -c "$CONC" --no-tui "$BASE/$CODE" > "$TMP/oha.txt" 2>&1 &
OHA=$!

# Readiness poller: "<epoch_ms> <status>" every 50 ms. 000 = connection refused.
( while :; do
    printf '%s %s\n' "$(now_ms)" "$(curl -s -o /dev/null -m 1 -w '%{http_code}' "$BASE/health/ready")"
    sleep 0.05
  done ) > "$TMP/ready.log" 2>/dev/null &
POLL=$!

sleep 1
kill -0 "$OHA" 2>/dev/null || { fail "oha exited early"; cat "$TMP/oha.txt"; exit 1; }
sleep "$KILL_AFTER"

T_KILL="$(now_ms)"
docker compose kill -s SIGTERM "$SERVICE" >/dev/null
EXIT_CODE="$(docker wait "$CID")"
T_EXIT="$(now_ms)"
wait "$OHA" || true
kill "$POLL" 2>/dev/null || true
SHUTDOWN_MS=$(( T_EXIT - T_KILL ))

[[ "$EXIT_CODE" == 0 ]] && pass "exit code 0" || fail "exit code $EXIT_CODE"
if (( SHUTDOWN_MS < (GRACE_SECS - 2) * 1000 )); then
  pass "graceful exit in ${SHUTDOWN_MS} ms (grace ${GRACE_SECS}s)"
else
  fail "exit took ${SHUTDOWN_MS} ms, so it was probably SIGKILLed"
fi

FIRST_503="$(awk -v k="$T_KILL" '$1>=k && $2=="503"{print $1; exit}' "$TMP/ready.log")"
FIRST_DOWN="$(awk -v k="$T_KILL" '$1>=k && $2=="000"{print $1; exit}' "$TMP/ready.log")"
if [[ -z "$FIRST_503" ]]; then
  fail "readiness never returned 503 (shutdown_delay_secs = 0?)"
elif [[ -n "$FIRST_DOWN" && "$FIRST_503" -gt "$FIRST_DOWN" ]]; then
  fail "listener closed before readiness flipped"
else
  pass "readiness 503 $(( FIRST_503 - T_KILL )) ms after SIGTERM, before the listener closed"
fi

STATUS="$(sed -n '/Status code distribution/,/^$/p' "$TMP/oha.txt")"
SERVED="$(grep -oE '\[3[0-9]{2}\][[:space:]]+[0-9]+' <<<"$STATUS" | awk '{s+=$2} END{print s+0}')"
if grep -qE '\[5[0-9]{2}\]' <<<"$STATUS"; then
  fail "5xx during shutdown: $STATUS"
else
  pass "no 5xx; $SERVED redirects served"
fi

LOGS="$(docker compose logs --no-color "$SERVICE")"
for ev in 'SIGTERM received' 'readiness failing' 'in-flight requests drained' \
          'click writer drained and stopped' 'shutdown complete'; do
  grep -q "$ev" <<<"$LOGS" && pass "log: $ev" || fail "log missing: $ev"
done

WLINE="$(grep 'click writer drained and stopped' <<<"$LOGS" | tail -1)"
WRITTEN="$(grep -oE 'rows_written[^0-9]*[0-9]+' <<<"$WLINE" | grep -oE '[0-9]+$' || echo '')"
DROPPED="$(grep -oE 'dropped[^0-9]*[0-9]+' <<<"$WLINE" | grep -oE '[0-9]+$' || echo '')"
DB_ROWS="$(psql_q "SELECT COUNT(*) FROM clicks")"
echo "        served=$SERVED written=${WRITTEN:-?} dropped=${DROPPED:-?} db=$DB_ROWS"

if [[ -z "$WRITTEN" || -z "$DROPPED" ]]; then
  fail "couldn't parse writer totals (is the field still spelled rows_writtem?)"
else
  [[ "$WRITTEN" == "$DB_ROWS" ]] && pass "every written click is in Postgres" \
                                 || fail "writer reported $WRITTEN, Postgres has $DB_ROWS"
  if (( WRITTEN + DROPPED == SERVED + SMOKE_REDIRECTS )); then
    pass "conservation: written + dropped = redirects served"
  else
    fail "conservation: $WRITTEN + $DROPPED != $SERVED + $SMOKE_REDIRECTS"
  fi
fi

# ---------------------------------------------------------------------------
hdr "5. Restart persistence"
docker compose up -d "$SERVICE" >/dev/null
if wait_ready && [[ "$(code_of "$BASE/$CODE")" == 307 ]]; then
  pass "link resolves after container restart"
else
  fail "link lost across restart"
fi

# ---------------------------------------------------------------------------
hdr "6. Config fails fast"
set +e
OUT="$(docker compose run --rm --no-deps \
  -e LINKFORGE__RATE_LIMIT__IDLE_TTL_SECS=1 -e LINKFORGE__RATE_LIMIT__WINDOW_SECS=60 \
  "$SERVICE" 2>&1)"; RC=$?
set -e
(( RC != 0 )) && grep -q idle_ttl_secs <<<"$OUT" \
  && pass "idle_ttl < window rejected at startup (exit $RC)" \
  || fail "bad rate-limit config started (exit $RC)"

set +e
OUT="$(docker compose run --rm --no-deps -e APP_ENV=production -e ANALYTICS_IP_SALT= \
  "$SERVICE" 2>&1)"; RC=$?
set -e
(( RC != 0 )) && grep -q ANALYTICS_IP_SALT <<<"$OUT" \
  && pass "production without salt refuses to start" \
  || fail "production started without ANALYTICS_IP_SALT (exit $RC)"

# ---------------------------------------------------------------------------
hdr "Verdict"
if (( FAIL == 0 )); then
  echo "  All Phase 5 acceptance checks passed."
  exit 0
else
  echo "  $FAIL check(s) failed."
  exit 1
fi