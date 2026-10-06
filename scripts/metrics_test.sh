#!/usr/bin/env bash
#
# metrics_test.sh — LinkForge /metrics + Prometheus acceptance probes (Phase 5)
#
# ===========================================================================
# WHAT THIS PROVES
# ===========================================================================
#   1. /metrics is valid Prometheus exposition (content-type, syntax, promtool)
#   2. Every metric we rely on exists and has the right TYPE
#   3. Counters are EXACT: N redirects => +N requests, +N latency samples,
#      +N click attempts, and the writer eventually persists them
#   4. The latency histogram is internally consistent (buckets monotone,
#      +Inf bucket == _count)
#   5. Labels are BOUNDED: route is a template ("/{code}"), never a real code
#   6. Status labels are correct (307 for hits, 404 for unknown codes)
#   7. Scraping is cheap (latency + payload size)
#   8. A real Prometheus server can scrape it, and PromQL works on it
#
# Same principle as load_test.sh: every probe asserts that it did real work.
# A counter that never moves must fail, not pass vacuously.
#
# ===========================================================================
# BASH NOTE
# ===========================================================================
# This script runs under `set -euo pipefail`. A grep that matches nothing
# exits 1, pipefail propagates that through the pipe, and set -e then kills
# the script SILENTLY. Every grep whose "no match" is a legitimate outcome is
# therefore wrapped as `{ grep ... || true; }`.
#
# ===========================================================================
# REQUIREMENTS
# ===========================================================================
#   * A running server in BENCH MODE (one IP => one rate-limit bucket):
#       just bench-app
#       # or: LINKFORGE__RATE_LIMIT__REQUESTS=100000000 docker compose up -d --build app
#   * curl, awk, sed. Optional: oha (exact request counts, sustained load),
#     docker (promtool + the real Prometheus probe).
#
# Usage:
#   ./scripts/metrics_test.sh [BASE_URL]
#
# Env:
#   N=500                  redirects fired by the exactness probe
#   ROUTE_LABEL='/{code}'  matched-path template your middleware records
#   PROMETHEUS=0           skip the real Prometheus server probe
#   PROM_IMAGE=prom/prometheus:latest
#   PROM_PORT=9090
#
# Exit: 0 all passed, 1 any failed.
#
set -euo pipefail

BASE="${1:-http://localhost:3000}"
METRICS_URL="$BASE/metrics"
N="${N:-500}"
ROUTE_LABEL="${ROUTE_LABEL:-/{code\}}"
ROUTE_LABEL="${ROUTE_LABEL//\\/}"           # tolerate escaped braces
PROMETHEUS="${PROMETHEUS:-1}"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:latest}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_CONTAINER="linkforge-metrics-test-prom"

# Metric names — keep in sync with src/observability/metrics.rs
HTTP_REQ="linkforge_http_requests_total"
HTTP_DUR="linkforge_http_request_duration_seconds"
CLK_ENQ="linkforge_clicks_enqueued_total"
CLK_DROP="linkforge_clicks_dropped_total"
CLK_ROWS="linkforge_click_rows_written_total"
CLK_BATCH="linkforge_click_batches_total"
CLK_FAIL="linkforge_click_batch_failures_total"
CLK_DEPTH="linkforge_click_queue_depth"
CACHE="linkforge_cache_lookups_total"
RL_REJ="linkforge_rate_limit_rejections_total"
RL_BUCKETS="linkforge_rate_limit_buckets"

FAILURES=0
WARNINGS=0
TMP="$(mktemp -d)"
TRAFFIC=""

cleanup() {
  [[ -n "$TRAFFIC" ]] && kill "$TRAFFIC" 2>/dev/null || true
  docker rm -f "$PROM_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; D=''; X=''
fi
hdr()    { printf '\n%s%s%s\n' "$B" "$*" "$X"; }
pass()   { printf '%s  PASS  %s%s\n' "$G" "$*" "$X"; }
fail()   { printf '%s  FAIL  %s%s\n' "$R" "$*" "$X"; FAILURES=$((FAILURES + 1)); }
warn()   { printf '%s  WARN  %s%s\n' "$Y" "$*" "$X"; WARNINGS=$((WARNINGS + 1)); }
skip()   { printf '%s  SKIP  %s%s\n' "$D" "$*" "$X"; }
detail() { printf '        %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Helpers — every "no match is fine" grep is guarded with || true
# ---------------------------------------------------------------------------
code_of() { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }
scrape()  { curl -s "$METRICS_URL" || true; }

# Lines of <name> (exact metric name, with or without labels).
metric_lines() { { grep -E "^${2}(\{| )" <<<"$1" || true; }; }

# Sum every series of <name> whose line contains ALL given label fragments.
# Fragments are fixed strings, e.g. 'route="/{code}"' 'status="307"'.
# Label order in the exposition is not guaranteed, hence one grep per fragment.
metric_sum() {
  local text="$1" name="$2"; shift 2
  local lines f
  lines="$(metric_lines "$text" "$name")"
  for f in "$@"; do lines="$({ grep -F -- "$f" <<<"$lines" || true; })"; done
  awk '{ s += $NF } END { printf "%.0f", s + 0 }' <<<"$lines"
}
metric_sum_f() {
  local text="$1" name="$2"; shift 2
  local lines f
  lines="$(metric_lines "$text" "$name")"
  for f in "$@"; do lines="$({ grep -F -- "$f" <<<"$lines" || true; })"; done
  awk '{ s += $NF } END { printf "%.6f", s + 0 }' <<<"$lines"
}
has_metric()   { grep -qE "^${2}(\{| )" <<<"$1"; }   # used only in `if`
metric_type()  { { grep -E "^# TYPE ${2} " <<<"$1" || true; } | awk '{print $4}' | head -n1; }
series_count() { metric_lines "$1" "$2" | awk 'NF{c++} END{print c+0}'; }

extract_code() { { grep -o '"code":"[^"]*"' || true; } | head -n1 | sed 's/.*:"//; s/"//'; }
create_link() {
  curl -s -X POST "$BASE/shorten" -H 'content-type: application/json' \
    -d "{\"url\":\"$1\"}" | extract_code
}
random_code() { LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 8 || true; }

# Fire exactly $2 GETs at $1. Prints the number of 3xx responses received.
fire_exact() {
  local url="$1" n="$2"
  if command -v oha >/dev/null 2>&1; then
    oha -n "$n" -c 20 --no-tui "$url" > "$TMP/oha.txt" 2>&1 || true
    sed -n '/Status code distribution/,/^$/p' "$TMP/oha.txt" \
      | { grep -oE '\[3[0-9]{2}\][[:space:]]+[0-9]+' || true; } \
      | awk '{s+=$2} END{print s+0}'
  else
    seq "$n" | xargs -P20 -I{} curl -s -o /dev/null -w '%{http_code}\n' "$url" \
      | awk '/^3/{c++} END{print c+0}'
  fi
}

# ===========================================================================
# 0. PRE-FLIGHT
# ===========================================================================
hdr "0. Pre-flight"

case "$(code_of "$BASE/health/ready")" in
  200) pass "server ready at $BASE" ;;
  000) echo "server not reachable at $BASE"; exit 1 ;;
  *)   echo "/health/ready did not return 200"; exit 1 ;;
esac

# Exact-count probes are meaningless if the limiter rejects part of the traffic.
BURST_429="$(seq 200 | xargs -P50 -I{} curl -s -o /dev/null -w '%{http_code}\n' "$BASE/health" \
             | awk '/^429$/{c++} END{print c+0}')"
if (( BURST_429 > 0 )); then
  echo "rate limiter rejected $BURST_429/200 — start the server in bench mode:"
  echo "  LINKFORGE__RATE_LIMIT__REQUESTS=100000000 docker compose up -d --build app"
  exit 1
fi
pass "rate limiter has headroom (bench mode)"

SCRAPE="$(scrape)"
if [[ -n "$SCRAPE" ]]; then
  pass "/metrics returned a body"
else
  fail "/metrics body is empty"
  exit 1
fi

# ===========================================================================
# 1. EXPOSITION FORMAT
# ===========================================================================
hdr "1. Exposition format"

CT="$(curl -s -D - -o /dev/null "$METRICS_URL" | tr -d '\r' \
      | awk -F': ' 'tolower($1)=="content-type"{print $2}')"
if [[ "$CT" == *text/plain* ]]; then
  pass "content-type: $CT"
else
  fail "content-type is '$CT' (Prometheus expects text/plain; version=0.0.4)"
fi

# Every sample line must be: name{optional labels} value.
# Label VALUES may contain braces ("/{code}"), hence \{.*\} rather than \{[^}]*\}.
BAD="$({ grep -vE '^#|^$' <<<"$SCRAPE" || true; } \
       | { grep -vE '^[a-zA-Z_:][a-zA-Z0-9_:]*(\{.*\})? [-+0-9.eEInfa]+$' || true; })"
if [[ -z "$BAD" ]]; then
  pass "all sample lines are syntactically valid"
else
  fail "malformed sample lines:"
  head -5 <<<"$BAD" | sed 's/^/        /'
fi

BYTES="$(printf '%s' "$SCRAPE" | wc -c | tr -d ' ')"
SERIES="$({ grep -vE '^#|^$' <<<"$SCRAPE" || true; } | awk 'NF{c++} END{print c+0}')"
detail "payload: ${BYTES} bytes, ${SERIES} series"

# promtool: the authoritative parser + linter.
PROMTOOL=()
if command -v promtool >/dev/null 2>&1; then
  PROMTOOL=(promtool)
elif command -v docker >/dev/null 2>&1; then
  PROMTOOL=(docker run --rm -i --entrypoint promtool "$PROM_IMAGE")
fi
if (( ${#PROMTOOL[@]} )); then
  set +e
  OUT="$(printf '%s\n' "$SCRAPE" | "${PROMTOOL[@]}" check metrics 2>&1)"
  RC=$?
  set -e
  if (( RC == 0 )); then
    pass "promtool check metrics: clean"
  elif grep -qi 'error while parsing\|parse error' <<<"$OUT"; then
    fail "promtool could not parse the exposition:"
    head -10 <<<"$OUT" | sed 's/^/        /'
  else
    warn "promtool lint findings (naming/units — not fatal):"
    head -10 <<<"$OUT" | sed 's/^/        /'
  fi
else
  skip "promtool unavailable (no promtool binary, no docker)"
fi

# ===========================================================================
# 2. REQUIRED METRICS + TYPES
# ===========================================================================
hdr "2. Required metrics and types"

# Make sure lazily-registered series exist before checking: one hit, one 404.
SEED="$(create_link "https://example.com/metrics-seed")"
if [[ -z "$SEED" ]]; then
  fail "could not create a seed link"
  exit 1
fi
curl -s -o /dev/null "$BASE/$SEED"
curl -s -o /dev/null "$BASE/$(random_code)"
sleep 0.5
SCRAPE="$(scrape)"

check_type() {   # name expected_type...
  local name="$1"; shift
  if ! has_metric "$SCRAPE" "$name" && ! has_metric "$SCRAPE" "${name}_count"; then
    fail "$name missing"
    return 0
  fi
  local t ok=0 e
  t="$(metric_type "$SCRAPE" "$name")"
  for e in "$@"; do [[ "$t" == "$e" ]] && ok=1; done
  if (( ok )); then
    pass "$name ($t)"
  else
    fail "$name has TYPE '${t:-none}', expected: $*"
  fi
}
check_type "$HTTP_REQ"   counter
check_type "$HTTP_DUR"   histogram summary
check_type "$CLK_ENQ"    counter
check_type "$CLK_ROWS"   counter
check_type "$CLK_BATCH"  counter
check_type "$CLK_DEPTH"  gauge
check_type "$CACHE"      counter

# These only appear on their first event unless initialised to 0 at startup.
for lazy in "$CLK_DROP" "$CLK_FAIL" "$RL_REJ" "$RL_BUCKETS"; do
  if has_metric "$SCRAPE" "$lazy"; then
    pass "$lazy present"
  else
    warn "$lazy absent until its first event"
    detail "initialise it at startup, e.g. metrics::counter!(\"$lazy\").absolute(0);"
  fi
done

# Stray metrics that should have been folded into the ones above.
STRAY="$({ grep -E '^# TYPE linkforge_' <<<"$SCRAPE" || true; } | awk '{print $3}' \
         | { grep -vxE "${HTTP_REQ}|${HTTP_DUR}|${CLK_ENQ}|${CLK_DROP}|${CLK_ROWS}|${CLK_BATCH}|${CLK_FAIL}|${CLK_DEPTH}|${CACHE}|${RL_REJ}|${RL_BUCKETS}" || true; })"
if [[ -z "$STRAY" ]]; then
  pass "no unexpected linkforge_* metrics"
else
  warn "unexpected metrics (typo or leftover?):"
  sed 's/^/        /' <<<"$STRAY"
fi

# ===========================================================================
# 3. COUNTERS ARE EXACT
# ===========================================================================
hdr "3. Counters are exact (N=$N redirects)"

CODE="$(create_link "https://example.com/metrics-exact")"
if [[ -z "$CODE" ]]; then
  fail "could not create a link for the exactness probe"
  exit 1
fi
curl -s -o /dev/null "$BASE/$CODE"     # warm cache, register series
sleep 0.3

BEFORE="$(scrape)"
REQ0="$(metric_sum "$BEFORE" "$HTTP_REQ" "route=\"$ROUTE_LABEL\"" 'status="307"')"
CNT0="$(metric_sum "$BEFORE" "${HTTP_DUR}_count" "route=\"$ROUTE_LABEL\"")"
ENQ0="$(metric_sum "$BEFORE" "$CLK_ENQ")"
DROP0="$(metric_sum "$BEFORE" "$CLK_DROP")"
ROWS0="$(metric_sum "$BEFORE" "$CLK_ROWS")"
CACHE0="$(metric_sum "$BEFORE" "$CACHE")"

SERVED="$(fire_exact "$BASE/$CODE" "$N")"
detail "redirects served: $SERVED / $N"
(( SERVED == N )) || fail "only $SERVED of $N requests returned 3xx — exact counts invalid"

AFTER="$(scrape)"
dREQ=$(( $(metric_sum "$AFTER" "$HTTP_REQ" "route=\"$ROUTE_LABEL\"" 'status="307"') - REQ0 ))
dCNT=$(( $(metric_sum "$AFTER" "${HTTP_DUR}_count" "route=\"$ROUTE_LABEL\"") - CNT0 ))
dENQ=$(( $(metric_sum "$AFTER" "$CLK_ENQ") - ENQ0 ))
dDROP=$(( $(metric_sum "$AFTER" "$CLK_DROP") - DROP0 ))
dCACHE=$(( $(metric_sum "$AFTER" "$CACHE") - CACHE0 ))

detail "Δ requests{route=$ROUTE_LABEL,status=307} = $dREQ"
detail "Δ latency _count                       = $dCNT"
detail "Δ clicks enqueued + dropped            = $((dENQ + dDROP))"
detail "Δ cache lookups                        = $dCACHE"

if (( dREQ == 0 )); then
  fail "request counter did not move — wrong ROUTE_LABEL? series present:"
  metric_lines "$AFTER" "$HTTP_REQ" | head -3 | sed 's/^/        /'
elif (( dREQ == SERVED )); then
  pass "request counter exact (+$dREQ for $SERVED redirects)"
else
  fail "request counter +$dREQ for $SERVED redirects"
fi

if (( dCNT == SERVED )); then
  pass "latency observations exact (+$dCNT)"
else
  fail "latency _count +$dCNT for $SERVED redirects"
fi

# Every redirect is either enqueued or dropped (sync mode: neither).
if (( dENQ + dDROP == 0 )); then
  warn "no click activity — server in click_mode=sync? click checks skipped"
elif (( dENQ + dDROP == SERVED )); then
  pass "click attempts exact: enqueued $dENQ + dropped $dDROP = $SERVED"
else
  fail "click attempts $((dENQ + dDROP)) for $SERVED redirects"
fi

if (( dCACHE >= SERVED )); then
  pass "cache lookups moved (+$dCACHE)"
else
  fail "cache lookups +$dCACHE for $SERVED redirects"
fi

# Writer catches up: rows_written delta reaches enqueued delta, depth returns to 0.
if (( dENQ > 0 )); then
  DEADLINE=$(( $(date +%s) + 15 ))
  dROWS=0
  DEPTH=-1
  while (( $(date +%s) < DEADLINE )); do
    NOW="$(scrape)"
    dROWS=$(( $(metric_sum "$NOW" "$CLK_ROWS") - ROWS0 ))
    DEPTH="$(metric_sum "$NOW" "$CLK_DEPTH")"
    (( dROWS >= dENQ && DEPTH == 0 )) && break
    sleep 0.2
  done
  detail "Δ rows written = $dROWS, queue depth = $DEPTH"
  if (( dROWS >= dENQ )); then
    pass "writer persisted every enqueued click"
  else
    fail "writer persisted $dROWS of $dENQ enqueued clicks"
  fi
  if (( DEPTH == 0 )); then
    pass "queue depth gauge returned to 0"
  else
    fail "queue depth gauge stuck at $DEPTH (set it from queue_depth() at scrape time)"
  fi
fi

# ===========================================================================
# 4. LATENCY HISTOGRAM CONSISTENCY
# ===========================================================================
hdr "4. Latency histogram / summary consistency"

DTYPE="$(metric_type "$AFTER" "$HTTP_DUR")"
SUM="$(metric_sum_f "$AFTER" "${HTTP_DUR}_sum" "route=\"$ROUTE_LABEL\"")"
COUNT="$(metric_sum "$AFTER" "${HTTP_DUR}_count" "route=\"$ROUTE_LABEL\"")"

if awk "BEGIN{exit !($SUM > 0)}"; then
  pass "_sum > 0 ($SUM s over $COUNT requests)"
else
  fail "_sum is $SUM"
fi
if (( COUNT > 0 )); then
  MEAN_US="$(awk "BEGIN{printf \"%.1f\", 1000000*$SUM/$COUNT}")"
  detail "mean server-side latency: ${MEAN_US} µs"
  awk "BEGIN{exit !($MEAN_US < 1000000)}" || warn "mean ${MEAN_US} µs — units recorded in ms, not seconds?"
fi

case "$DTYPE" in
  histogram)
    BUCKETS="$(metric_lines "$AFTER" "${HTTP_DUR}_bucket" | { grep -F "route=\"$ROUTE_LABEL\"" || true; })"
    if [[ -z "$BUCKETS" ]]; then
      fail "histogram declared but no _bucket series for route=$ROUTE_LABEL"
    else
      ORDERED="$(sed -E 's/.*le="([^"]+)".* ([0-9.eE+]+)$/\1 \2/' <<<"$BUCKETS" \
                 | sed 's/^+Inf/1e308/' | sort -g -k1,1)"
      if awk 'NR>1 && $2 < prev {bad=1} {prev=$2} END{exit bad}' <<<"$ORDERED"; then
        pass "bucket counts are monotonically non-decreasing"
      else
        fail "bucket counts decrease — histogram is corrupt"
      fi
      INF="$(awk 'END{printf "%.0f", $2}' <<<"$ORDERED")"
      if (( INF == COUNT )); then
        pass "+Inf bucket == _count ($INF)"
      else
        fail "+Inf bucket $INF != _count $COUNT"
      fi
      detail "$(awk 'NF{c++} END{print c+0}' <<<"$ORDERED") buckets"
      # Where do requests actually land? Show the cumulative distribution.
      awk -v total="$COUNT" '{ le=($1=="1e308")?"+Inf":$1;
             printf "        le=%-10s %6.2f%%\n", le, (total>0?100*$2/total:0) }' <<<"$ORDERED"
    fi
    ;;
  summary)
    warn "$HTTP_DUR is a SUMMARY (the exporter's default)"
    detail "Configure buckets via PrometheusBuilder::set_buckets_for_metric(...)"
    detail "so histogram_quantile() works and instances can be aggregated."
    ;;
  *)
    fail "$HTTP_DUR has unexpected TYPE '${DTYPE:-none}'"
    ;;
esac

# ===========================================================================
# 5. LABEL CARDINALITY IS BOUNDED
# ===========================================================================
hdr "5. Label cardinality"

S0="$(series_count "$(scrape)" "$HTTP_REQ")"
CODES=()
for i in $(seq 30); do
  c="$(create_link "https://example.com/card/$i")"
  if [[ -n "$c" ]]; then
    CODES+=("$c")
    curl -s -o /dev/null "$BASE/$c"
  fi
done
for _ in $(seq 30); do curl -s -o /dev/null "$BASE/$(random_code)"; done
curl -s -o /dev/null "$BASE/no/such/deep/path"
CARD="$(scrape)"
S1="$(series_count "$CARD" "$HTTP_REQ")"
detail "${#CODES[@]} new codes + 30 unknown codes + 1 unmatched path"
detail "$HTTP_REQ series: $S0 → $S1"

if (( S1 - S0 <= 3 )); then
  pass "series count stayed bounded (+$((S1 - S0)))"
else
  fail "series grew by $((S1 - S0)) — a label is unbounded"
fi

LEAKED=0
for c in "${CODES[@]}"; do
  grep -qF "=\"/$c\"" <<<"$CARD" && LEAKED=$((LEAKED + 1))
done
if (( LEAKED == 0 )); then
  pass "no concrete short code appears in any label"
else
  fail "$LEAKED short codes leaked into labels (use MatchedPath, not uri())"
fi

if grep -qF '/no/such/deep/path' <<<"$CARD"; then
  fail "unmatched raw path leaked into a label"
else
  pass "unmatched paths collapse to a fixed label"
fi

ROUTES="$({ grep -oE 'route="[^"]*"' <<<"$CARD" || true; } | sort -u | tr '\n' ' ')"
detail "distinct route labels: $ROUTES"

# ===========================================================================
# 6. STATUS LABELS
# ===========================================================================
hdr "6. Status labels"

B404="$(metric_sum "$(scrape)" "$HTTP_REQ" "route=\"$ROUTE_LABEL\"" 'status="404"')"
for _ in $(seq 10); do curl -s -o /dev/null "$BASE/$(random_code)"; done
A404="$(metric_sum "$(scrape)" "$HTTP_REQ" "route=\"$ROUTE_LABEL\"" 'status="404"')"
if (( A404 - B404 == 10 )); then
  pass "10 unknown codes => +10 {status=\"404\"}"
else
  fail "10 unknown codes => +$((A404 - B404)) {status=\"404\"}"
fi

# ===========================================================================
# 7. SCRAPE COST
# ===========================================================================
hdr "7. Scrape cost"

T0="$(date +%s%N)"
for _ in $(seq 20); do curl -s -o /dev/null "$METRICS_URL"; done
AVG_MS=$(( ( $(date +%s%N) - T0 ) / 20 / 1000000 ))
BYTES="$(scrape | wc -c | tr -d ' ')"
detail "avg scrape ${AVG_MS} ms (includes curl process start), payload ${BYTES} bytes"
if (( AVG_MS < 50 )); then
  pass "scrape is cheap (${AVG_MS} ms)"
else
  warn "scrape takes ${AVG_MS} ms"
fi
if (( BYTES < 200000 )); then
  pass "payload ${BYTES} B"
else
  warn "payload ${BYTES} B — check for cardinality growth"
fi

# ===========================================================================
# 8. REAL PROMETHEUS SERVER
# ===========================================================================
hdr "8. Real Prometheus scrape + PromQL"

if [[ "$PROMETHEUS" != "1" ]]; then
  skip "PROMETHEUS=0"
elif ! command -v docker >/dev/null 2>&1; then
  skip "docker not available"
else
  TARGET="$(sed -E 's#^https?://##; s#/.*$##' <<<"$BASE")"
  cat > "$TMP/prometheus.yml" <<EOF
global:
  scrape_interval: 1s
  evaluation_interval: 1s
scrape_configs:
  - job_name: linkforge
    static_configs:
      - targets: ["$TARGET"]
EOF
  chmod 644 "$TMP/prometheus.yml"
  chmod 755 "$TMP"

  # Host networking: the app may be on the host network, and bridge DNS is
  # unreliable in this Codespace.
  docker rm -f "$PROM_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$PROM_CONTAINER" --network host \
    -v "$TMP/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    "$PROM_IMAGE" \
    --config.file=/etc/prometheus/prometheus.yml \
    --web.listen-address=":$PROM_PORT" >/dev/null

  PROM="http://localhost:$PROM_PORT"

  # Prometheus query helpers. An empty result vector is NORMAL (e.g. before
  # the first scrape), so first_value must not fail on "no match".
  q() { curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$1" || true; }
  first_value() {
    { grep -oE '"value":\[[^]]*\]' || true; } | head -n1 | sed -E 's/.*,"([^"]*)"\]/\1/'
  }

  for _ in $(seq 60); do
    [[ "$(code_of "$PROM/-/ready")" == 200 ]] && break
    sleep 0.5
  done

  if [[ "$(code_of "$PROM/-/ready")" != 200 ]]; then
    fail "Prometheus did not become ready"
    docker logs "$PROM_CONTAINER" 2>&1 | tail -5 | sed 's/^/        /'
  else
    pass "Prometheus ready on :$PROM_PORT"

    # 8.1 Wait until Prometheus has actually scraped the target (ready != scraped).
    UP=""
    for _ in $(seq 60); do
      UP="$(q 'up{job="linkforge"}' | first_value)"
      [[ "$UP" == "1" ]] && break
      sleep 0.5
    done
    if [[ "$UP" == "1" ]]; then
      pass "target health: up == 1"
    else
      fail "up{job=\"linkforge\"} = '${UP:-none}' (Prometheus can't scrape $TARGET)"
    fi

    # 8.2 Sustained traffic that outlasts the query window.
    if command -v oha >/dev/null 2>&1; then
      oha -z 25s -c 10 --no-tui "$BASE/$CODE" >/dev/null 2>&1 &
    else
      ( end=$((SECONDS + 25)); while (( SECONDS < end )); do curl -s -o /dev/null "$BASE/$CODE"; done ) &
    fi
    TRAFFIC=$!

    # 8.3 Let ~15 scrapes land under load; query while traffic is still running.
    sleep 18
    W="15s"

    RATE="$(q "sum(rate(${HTTP_REQ}{route=\"$ROUTE_LABEL\"}[$W]))" | first_value)"
    if [[ -n "$RATE" && "$RATE" != "NaN" ]] && awk "BEGIN{exit !($RATE > 1)}"; then
      pass "rate(${HTTP_REQ}{route=$ROUTE_LABEL}[$W]) = $(printf '%.0f' "$RATE") req/s"
    else
      fail "rate() under load returned '${RATE:-no data}'"
    fi

    if [[ "$DTYPE" == "histogram" ]]; then
      for qn in 0.50 0.99; do
        V="$(q "histogram_quantile($qn, sum by (le) (rate(${HTTP_DUR}_bucket{route=\"$ROUTE_LABEL\"}[$W])))" | first_value)"
        if [[ -n "$V" && "$V" != "NaN" ]]; then
          pass "histogram_quantile p${qn#0.} = $(awk "BEGIN{printf \"%.1f\", 1000000*$V}") µs (server-side)"
        else
          fail "histogram_quantile($qn) returned '${V:-no data}'"
        fi
      done
    else
      skip "histogram_quantile (metric is a summary)"
    fi

    HIT="$(q "sum(rate(${CACHE}{result=\"hit\"}[$W])) / sum(rate(${CACHE}[$W]))" | first_value)"
    if [[ -n "$HIT" && "$HIT" != "NaN" ]]; then
      pass "cache hit ratio (PromQL, $W window) = $(awk "BEGIN{printf \"%.4f\", $HIT}")"
    else
      warn "cache hit ratio returned '${HIT:-no data}' (label value differs from result=\"hit\"?)"
    fi

    DROPR="$(q "sum(rate(${CLK_DROP}[$W]))" | first_value)"
    detail "click drop rate: ${DROPR:-n/a}/s"

    wait "$TRAFFIC" 2>/dev/null || true
    TRAFFIC=""

    NSERIES="$(q "count({job=\"linkforge\"})" | first_value)"
    detail "series ingested for job=linkforge: ${NSERIES:-?}"
  fi
fi

# ===========================================================================
# VERDICT
# ===========================================================================
hdr "Verdict"
if (( FAILURES == 0 )); then
  printf '%s  All metrics probes passed. (%d warning(s))%s\n\n' "$G" "$WARNINGS" "$X"
  exit 0
else
  printf '%s  %d probe(s) FAILED. (%d warning(s))%s\n\n' "$R" "$FAILURES" "$WARNINGS" "$X"
  exit 1
fi
