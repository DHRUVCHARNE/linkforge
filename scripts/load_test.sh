#!/usr/bin/env bash
#
# load_test.sh — LinkForge load / correctness / benchmark harness
#
# Phase 4: Postgres + read-through cache + negative caching + single-flight
#          + tracing + request ids + per-IP rate limiting
#          + bounded mpsc click pipeline + batched analytics writer.
#
# ===========================================================================
# DESIGN PRINCIPLE: A TEST THAT PASSES FOR THE WRONG REASON IS WORSE THAN ONE
# THAT FAILS.
# ===========================================================================
# Every probe follows the same shape:
#   1. ESTABLISH a precondition
#   2. VERIFY it actually took effect
#   3. ACT
#   4. ASSERT the outcome AND that the probe did real work
#
# Earlier revisions of this script passed vacuously because of: probe codes
# that failed domain validation, an invalidate call that failed silently, a
# single-flight probe that read the wrong layer's counter, a rate limiter
# throttling the harness itself, and a debug-build server. Each guard below
# exists because one of those actually happened.
#
# ===========================================================================
# PHASE 4 ACCEPTANCE (from LINKFORGE.md §7)
# ===========================================================================
#   "redirect p99 under load is materially better than synchronous writes —
#    prove it with the Phase 3 harness."
#
# A shell script cannot restart the server in a different mode, so the
# comparison is done ACROSS TWO RUNS. Each run records its numbers to
# ${RESULTS_DIR}/phase4_<mode>.env; once both files exist, probe 10 compares
# them and issues the verdict.
#
#   # Run A — synchronous click writes (the baseline to beat)
#   CLICK_MODE=sync  RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 \
#     cargo run --release
#   CLICK_MODE=sync  ./scripts/load_test.sh
#
#   # Run B — bounded channel + batched writer
#   CLICK_MODE=async RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 \
#     cargo run --release
#   CLICK_MODE=async ./scripts/load_test.sh
#
# CLICK_MODE in THIS script is only a label for the results file. It must
# match how the server was started, which the script verifies via
# /debug/analytics when available.
#
# ===========================================================================
# REQUIREMENTS
# ===========================================================================
#   * A RELEASE build: `cargo run --release`. A debug build measured ~5x
#     lower throughput on this project and invalidated an entire phase of
#     baselines. The script cannot detect the profile — you must.
#   * BENCH MODE rate limit (the harness is one IP and would throttle itself):
#       RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1
#   * A FRESH database (`just down && just up`). Write throughput degrades as
#     tables grow; numbers from a bloated DB are not comparable.
#   * Dev-only routes (APP_ENV=development):
#       GET  /debug/cache
#         -> {"hits","negative_hits","misses","db_queries","ratio"}
#       POST /debug/cache/invalidate/{code}
#       GET  /debug/analytics          (Phase 4, see bottom of file)
#         -> {"enqueued","dropped","batches","rows_written","failed_batches",
#             "queue_depth","mode"}
#   * oha (cargo install oha). wrk is not supported for Phase 4 probes,
#     because the p99 comparison needs oha's percentile output.
#
# Usage:
#   ./scripts/load_test.sh [BASE_URL] [N_REQUESTS] [CONCURRENCY]
#
# Env:
#   CLICK_MODE=sync|async     label for this run's results (default async)
#   RESULTS_DIR=dir           where run results are stored (default .loadtest)
#   ONLY=1,2,8                run only these probes
#   SKIP=6                    skip these probes
#   LOAD_DURATION=10s
#   CLICK_PROBE_REQUESTS=2000 redirects fired by the click-accounting probe
#
# Exit code: 0 if every probe passed, 1 otherwise.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_URL="${1:-http://localhost:3000}"
N="${2:-10000}"
CONCURRENCY="${3:-100}"

CLICK_MODE="${CLICK_MODE:-async}"
RESULTS_DIR="${RESULTS_DIR:-.loadtest}"
LOAD_DURATION="${LOAD_DURATION:-10s}"

NEG_PROBE_REQUESTS="${NEG_PROBE_REQUESTS:-500}"
SF_PROBE_REQUESTS="${SF_PROBE_REQUESTS:-200}"
CLICK_PROBE_REQUESTS="${CLICK_PROBE_REQUESTS:-2000}"
CLICK_SETTLE_TIMEOUT_S="${CLICK_SETTLE_TIMEOUT_S:-15}"

# Phase 4 verdict threshold: async p99 must be at least this much lower than
# sync p99 to count as "materially better". 20% is deliberately well above
# the ~2-7% run-to-run noise measured on this hardware.
MATERIAL_IMPROVEMENT_PCT="${MATERIAL_IMPROVEMENT_PCT:-20}"

# Measured application-level costs (cargo bench, release, Phase 3).
BENCH_HIT_NS="${BENCH_HIT_NS:-260}"
BENCH_MISS_NS="${BENCH_MISS_NS:-492000}"

STATS_URL="${BASE_URL}/debug/cache"
ANALYTICS_URL="${BASE_URL}/debug/analytics"
FAILURES=0
WARNINGS=0

mkdir -p "${RESULTS_DIR}"
RESULT_FILE="${RESULTS_DIR}/phase4_${CLICK_MODE}.env"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

case "${CLICK_MODE}" in
  sync|async) ;;
  *) echo "CLICK_MODE must be 'sync' or 'async' (got '${CLICK_MODE}')"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_YELLOW=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

green() { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
red()   { printf '%s%s%s\n' "${C_RED}"   "$*" "${C_RESET}"; }
info()  { printf '%s%s%s\n' "${C_CYAN}"  "$*" "${C_RESET}"; }
hdr()   { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

pass()    { green "  PASS  $*"; }
fail()    { red   "  FAIL  $*"; FAILURES=$(( FAILURES + 1 )); }
warn()    { printf '%s  WARN  %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; WARNINGS=$(( WARNINGS + 1 )); }
skipped() { printf '%s  SKIP  %s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
detail()  { printf '        %s\n' "$*"; }

should_run() {
  local id="$1"
  if [[ -n "${ONLY:-}" ]]; then [[ ",${ONLY}," == *",${id},"* ]] || return 1; fi
  if [[ -n "${SKIP:-}" ]]; then [[ ",${SKIP}," == *",${id},"* ]] && return 1; fi
  return 0
}

# ---------------------------------------------------------------------------
# HTTP / stats helpers
# ---------------------------------------------------------------------------
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
http_time() { curl -s -o /dev/null -w '%{time_total}' "$@"; }

# Read a numeric field from a JSON endpoint. Returns 0 if absent so arithmetic
# never explodes; anti-vacuity checks catch a permanently-zero counter.
json_num() {
  local url="$1" field="$2" val
  val="$(curl -s "${url}" 2>/dev/null \
        | grep -o "\"${field}\":[0-9.]*" | head -n1 | sed 's/.*://')" || true
  printf '%s' "${val:-0}"
}
json_str() {
  local url="$1" field="$2"
  curl -s "${url}" 2>/dev/null \
    | grep -o "\"${field}\":\"[^\"]*\"" | head -n1 | sed 's/.*:"//; s/"$//' || true
}

stat_field()      { json_num "${STATS_URL}" "$1"; }
analytics_field() { json_num "${ANALYTICS_URL}" "$1"; }

has_endpoint() { curl -fsS "$1" >/dev/null 2>&1; }

assert_schema() {
  local url="$1" label="$2"; shift 2
  local body missing="" f
  body="$(curl -s "${url}")"
  for f in "$@"; do
    grep -q "\"${f}\"" <<<"${body}" || missing="${missing} ${f}"
  done
  if [[ -n "${missing}" ]]; then
    warn "${label} is missing field(s):${missing}"
    return 1
  fi
  return 0
}

extract_code() { grep -o '"code":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"//'; }

create_link() {
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d "{\"url\":\"$1\"}" | extract_code
}

invalidate() {
  curl -fsS -X POST "${BASE_URL}/debug/cache/invalidate/$1" >/dev/null 2>&1
}

# Must satisfy ShortCode::parse (base62, length 1..=10), or the request is
# rejected by the domain layer and never reaches the cache.
random_valid_code() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 8 || true
}

is_throttled() { [[ "$(http_code "${BASE_URL}/health")" == "429" ]]; }

# Read clicks for a code via the PUBLIC stats endpoint (black-box), not via
# the database. This verifies the whole path: redirect -> channel -> writer
# -> Postgres -> stats query -> JSON.
stats_clicks() { json_num "${BASE_URL}/$1/stats" clicks; }

# Poll until the stats endpoint reports at least `expected` clicks, or time
# out. Never use a fixed sleep: the writer flushes asynchronously and a fixed
# sleep is either flaky (too short) or slow (too long).
wait_for_clicks() {
  local code="$1" expected="$2" timeout_s="$3"
  local deadline=$(( $(date +%s) + timeout_s )) n=0
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    n="$(stats_clicks "${code}")"
    [[ "${n}" -ge "${expected}" ]] && { printf '%s' "${n}"; return 0; }
    sleep 0.2
  done
  printf '%s' "${n}"
  return 1
}

# Run oha and extract rps / p50 / p99 / status distribution into
# OHA_RPS, OHA_P50, OHA_P99, OHA_3XX, OHA_429, OHA_DIALUP.
run_oha() {
  local out="$1"; shift
  oha --no-tui "$@" > "${out}" 2>&1 || true
  OHA_RPS="$(grep -o 'Requests/sec:[[:space:]]*[0-9.]*' "${out}" | grep -o '[0-9.]*$' | head -n1 || true)"
  OHA_P50="$(grep -E '^[[:space:]]*50(\.00)?% in' "${out}" | grep -o '[0-9.]* ms' | grep -o '[0-9.]*' | head -n1 || true)"
  OHA_P99="$(grep -E '^[[:space:]]*99(\.00)?% in' "${out}" | grep -o '[0-9.]* ms' | grep -o '[0-9.]*' | head -n1 || true)"
  OHA_DIALUP="$(grep -o 'DNS+dialup:[[:space:]]*[0-9.]*' "${out}" | grep -o '[0-9.]*$' | head -n1 || true)"
  OHA_3XX="$(grep -oE '\[3[0-9]{2}\][[:space:]]*[0-9]+' "${out}" | awk '{s+=$2} END{print s+0}')"
  OHA_429="$(grep -oE '\[429\][[:space:]]*[0-9]+' "${out}" | awk '{print $2}' | head -n1 || true)"
  OHA_RPS="${OHA_RPS:-0}"; OHA_P50="${OHA_P50:-0}"; OHA_P99="${OHA_P99:-0}"
  OHA_DIALUP="${OHA_DIALUP:-0}"; OHA_429="${OHA_429:-0}"
}

# Record a key=value into this run's results file.
record() { printf '%s=%s\n' "$1" "$2" >> "${RESULT_FILE}.tmp"; }

# ===========================================================================
# 0. PRE-FLIGHT
# ===========================================================================
hdr "0. Pre-flight  (CLICK_MODE=${CLICK_MODE})"

PING="$(http_code "${BASE_URL}/health")"
case "${PING}" in
  200) green "  Server is up." ;;
  429) red "  Server is UP but already throttling this client."
       red "  Restart with RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1."
       exit 1 ;;
  000) red "  Server is not responding at ${BASE_URL}. Start it (cargo run --release)."
       exit 1 ;;
  *)   red "  /health returned ${PING}, expected 200."; exit 1 ;;
esac

command -v oha >/dev/null 2>&1 || {
  red "  oha is required for Phase 4 (p99 extraction). cargo install oha"
  exit 1
}

STATS_AVAILABLE=0
if has_endpoint "${STATS_URL}" \
   && assert_schema "${STATS_URL}" "/debug/cache" hits negative_hits misses db_queries; then
  STATS_AVAILABLE=1
  green "  /debug/cache available."
else
  warn "/debug/cache unavailable — cache probes (3, 4) will be SKIPPED."
fi

ANALYTICS_AVAILABLE=0
if has_endpoint "${ANALYTICS_URL}" \
   && assert_schema "${ANALYTICS_URL}" "/debug/analytics" enqueued dropped rows_written; then
  ANALYTICS_AVAILABLE=1
  green "  /debug/analytics available."

  # Verify the label matches the server. Mislabelled runs would make probe 10
  # compare two async runs and declare a win that does not exist.
  SERVER_MODE="$(json_str "${ANALYTICS_URL}" mode)"
  if [[ -n "${SERVER_MODE}" && "${SERVER_MODE}" != "${CLICK_MODE}" ]]; then
    red "  CLICK_MODE=${CLICK_MODE} but the server reports mode=${SERVER_MODE}."
    red "  Results would be filed under the wrong mode. Aborting."
    exit 1
  fi
  [[ -n "${SERVER_MODE}" ]] && detail "server confirms mode=${SERVER_MODE}"
else
  warn "/debug/analytics unavailable — pipeline accounting probes will be SKIPPED."
  detail "Add it (see bottom of this file) so dropped/queued clicks are visible."
fi

# --- Non-destructive rate-limit check ---------------------------------------
# A concurrent burst of 200 detects a small bucket. A benchmark-sized bucket
# (1e8 tokens) loses nothing measurable from it.
info "  Rate limiter headroom check (concurrent burst of 200)..."
BURST_429="$(
  seq 200 | xargs -P50 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
    "${BASE_URL}/health" | grep -c '^429$' || true
)"
detail "burst of 200 -> ${BURST_429} rejected"
if [[ "${BURST_429}" -gt 0 ]]; then
  red "  The rate limiter engages at 200 requests. Every measurement in this"
  red "  script would measure the limiter, not the application. Restart with:"
  red "    RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 cargo run --release"
  exit 1
fi
green "  Limiter has headroom."

warn "This script cannot detect the build profile."
detail "Confirm the server was started with --release. A debug build is ~5x"
detail "slower on this project and would invalidate the comparison."

# Start a fresh results file for this run.
: > "${RESULT_FILE}.tmp"
record MODE "${CLICK_MODE}"
record TIMESTAMP "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record CONCURRENCY "${CONCURRENCY}"
record LOAD_DURATION "${LOAD_DURATION}"

# ===========================================================================
# 1. CORRECTNESS — concurrent writes never collide
# ===========================================================================
if should_run 1; then
hdr "1. Correctness — ${N} concurrent POST /shorten (c=${CONCURRENCY})"

STATUS_LOG="${TMP_DIR}/writes.log"
seq "${N}" | xargs -P"${CONCURRENCY}" -I{} \
  curl -s -w '\nSTATUS:%{http_code}\n' -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/{}"}' \
  >> "${STATUS_LOG}" 2>/dev/null || true

TOTAL="$(grep -o '"code":"[^"]*"' "${STATUS_LOG}" | wc -l | tr -d ' ')"
UNIQUE="$(grep -o '"code":"[^"]*"' "${STATUS_LOG}" | sort -u | wc -l | tr -d ' ')"
DUPES=$(( TOTAL - UNIQUE ))
C429="$(grep -c '^STATUS:429$' "${STATUS_LOG}" || true)"
C5XX="$(grep -cE '^STATUS:5[0-9]{2}$' "${STATUS_LOG}" || true)"

detail "generated : ${TOTAL}/${N}   unique : ${UNIQUE}   dupes : ${DUPES}"
detail "429s : ${C429}   5xx : ${C5XX}"

if [[ "${TOTAL}" -lt $(( N / 2 )) ]]; then
  fail "only ${TOTAL}/${N} succeeded — zero duplicates among few writes proves nothing."
elif [[ "${DUPES}" -ne 0 ]]; then
  fail "${DUPES} duplicate code(s) under concurrency."
else
  pass "zero duplicates across ${TOTAL} concurrent writes."
fi
[[ "${C429}" -gt 0 ]] && fail "${C429} writes were rate limited — this probe must not be throttled."
if [[ "${C5XX}" -gt 0 ]]; then
  if [[ "${C5XX}" -gt $(( N / 20 )) ]]; then
    fail "${C5XX} writes returned 5xx (>5%)."
  else
    warn "${C5XX} writes returned 5xx."
  fi
  detail "Check the server log for the sqlx variant (PoolTimedOut vs unique violation)."
fi
record WRITES_OK "${TOTAL}"
fi

# ===========================================================================
# 2. THROUGHPUT — hot read path (cache hits + click emission)
#
# This is THE Phase 4 measurement. Every redirect now also produces a click,
# so this run measures the redirect path INCLUDING the analytics cost:
#   sync  : each redirect awaits an INSERT before responding
#   async : each redirect does a non-blocking try_send
# The p99 recorded here is what probe 10 compares across modes.
# ===========================================================================
if should_run 2; then
hdr "2. Throughput — hot read path GET /:code (${LOAD_DURATION}, c=${CONCURRENCY})"

SEED_CODE="$(create_link 'https://www.rust-lang.org')"
if [[ -z "${SEED_CODE}" ]]; then
  fail "could not seed a link."
else
  detail "seeded code: ${SEED_CODE}"
  TARGET="${BASE_URL}/${SEED_CODE}"
  curl -s -o /dev/null "${TARGET}"   # warm the cache

  if [[ "${ANALYTICS_AVAILABLE}" -eq 1 ]]; then
    TP_ENQ_BEFORE="$(analytics_field enqueued)"
    TP_DROP_BEFORE="$(analytics_field dropped)"
    TP_ROWS_BEFORE="$(analytics_field rows_written)"
  fi

  run_oha "${TMP_DIR}/oha_hot.txt" -z "${LOAD_DURATION}" -c "${CONCURRENCY}" "${TARGET}"
    # Full oha report: summary, histogram, percentile distribution,
  # DNS+dialup details and status-code distribution.
  sed 's/^/        /' "${TMP_DIR}/oha_hot.txt"

  # Keep a copy per mode so the sync and async reports can be compared later.
  cp "${TMP_DIR}/oha_hot.txt" "${RESULTS_DIR}/phase4_${CLICK_MODE}_oha.txt"

  detail ""
  detail "req/s       : ${OHA_RPS}"
  detail "p50         : ${OHA_P50} ms"
  detail "p99         : ${OHA_P99} ms"
  detail "DNS+dialup  : ${OHA_DIALUP} ms"
  detail "3xx / 429   : ${OHA_3XX} / ${OHA_429}"

  if [[ "${OHA_429}" -gt 0 ]]; then
    fail "${OHA_429} responses were 429 — the throughput figure includes the limiter."
  elif [[ "${OHA_3XX}" -eq 0 ]]; then
    fail "no 3xx responses recorded — oha output could not be parsed or the run failed."
  else
    pass "${OHA_3XX} redirects served, none throttled."
  fi

  # Connection setup is the best available signal of host contention. Across
  # this project's runs, throughput and DNS+dialup moved together: runs above
  # ~7 ms dialup were environmentally handicapped.
  if awk "BEGIN{exit !(${OHA_DIALUP} > 7)}"; then
    warn "DNS+dialup ${OHA_DIALUP} ms — this run is likely contaminated by host contention."
    detail "Rerun before comparing; prefer the run with the lowest dialup."
  fi

  record HOT_RPS "${OHA_RPS}"
  record HOT_P50 "${OHA_P50}"
  record HOT_P99 "${OHA_P99}"
  record HOT_DIALUP "${OHA_DIALUP}"
  record HOT_REDIRECTS "${OHA_3XX}"

  # --- Click pipeline accounting during the hot run ------------------------
  if [[ "${ANALYTICS_AVAILABLE}" -eq 1 ]]; then
    TP_ENQ=$(( $(analytics_field enqueued) - TP_ENQ_BEFORE ))
    TP_DROP=$(( $(analytics_field dropped) - TP_DROP_BEFORE ))
    detail ""
    detail "clicks enqueued during run : ${TP_ENQ}"
    detail "clicks dropped during run  : ${TP_DROP}"

    # Every redirect should produce exactly one click attempt (enqueued or
    # dropped). A large gap means clicks are not being emitted on some path.
    ATTEMPTS=$(( TP_ENQ + TP_DROP ))
    if [[ "${CLICK_MODE}" == "async" ]]; then
      if [[ "${ATTEMPTS}" -lt $(( OHA_3XX * 95 / 100 )) ]]; then
        fail "only ${ATTEMPTS} click attempts for ${OHA_3XX} redirects."
        detail "Some successful redirect path is not calling clicks.record()."
        detail "Check all three success paths: cache hit, waiter, leader."
      else
        pass "every redirect emitted a click (${ATTEMPTS} attempts / ${OHA_3XX} redirects)."
      fi

      if [[ "${TP_DROP}" -gt 0 ]]; then
        DROP_PCT="$(awk "BEGIN{printf \"%.3f\", 100*${TP_DROP}/(${ATTEMPTS}>0?${ATTEMPTS}:1)}")"
        warn "${TP_DROP} clicks dropped (${DROP_PCT}%) — backpressure engaged."
        detail "This is the documented drop-on-full policy working, not a bug."
        detail "Undercounting is the deliberate price of a fast redirect path."
        record HOT_DROP_PCT "${DROP_PCT}"
      else
        pass "zero clicks dropped at ${OHA_RPS} req/s — the writer kept up."
        record HOT_DROP_PCT 0
      fi
    fi
    record HOT_CLICKS_ENQUEUED "${TP_ENQ}"
    record HOT_CLICKS_DROPPED "${TP_DROP}"
  fi
fi
fi

# ===========================================================================
# 3. NEGATIVE CACHING — repeated 404s stop reaching Postgres
# ===========================================================================
if should_run 3; then
hdr "3. Negative caching — ${NEG_PROBE_REQUESTS} repeat 404s"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
else
  MISSING="$(random_valid_code)"
  if [[ "$(http_code "${BASE_URL}/${MISSING}")" != "404" ]]; then
    fail "probe code ${MISSING} did not 404 — cannot establish precondition."
  else
    invalidate "${MISSING}" || true
    B_MISS="$(stat_field misses)"; B_NEG="$(stat_field negative_hits)"; B_DB="$(stat_field db_queries)"
    ST="$(http_code "${BASE_URL}/${MISSING}")"
    F_MISS=$(( $(stat_field misses) - B_MISS ))
    F_DB=$(( $(stat_field db_queries) - B_DB ))
    A_DB_FIRST="$(stat_field db_queries)"

    seq "${NEG_PROBE_REQUESTS}" | xargs -P50 -I{} curl -s -o /dev/null "${BASE_URL}/${MISSING}"

    R_DB=$(( $(stat_field db_queries) - A_DB_FIRST ))
    NEG=$(( $(stat_field negative_hits) - B_NEG ))

    detail "1st: status ${ST}, misses +${F_MISS}, db +${F_DB}"
    detail "next ${NEG_PROBE_REQUESTS}: db +${R_DB}, negative hits +${NEG}"

    if [[ "${F_MISS}" -lt 1 || "${F_DB}" -lt 1 ]]; then
      fail "first request caused no miss/DB query — the probe exercised nothing."
    elif [[ "${NEG}" -lt $(( NEG_PROBE_REQUESTS * 8 / 10 )) ]]; then
      fail "only ${NEG} negative hits for ${NEG_PROBE_REQUESTS} requests."
    elif [[ "${R_DB}" -ne 0 ]]; then
      fail "${R_DB} repeat 404s still reached the database."
    else
      pass "${NEG_PROBE_REQUESTS} repeat 404s absorbed with 0 DB queries."
    fi

    # Phase 4 addition: 404s must NOT produce clicks. Otherwise a scanner
    # writes analytics rows for links that do not exist, bypassing the
    # protection negative caching provides.
    if [[ "${ANALYTICS_AVAILABLE}" -eq 1 ]]; then
      E_BEFORE="$(analytics_field enqueued)"; D_BEFORE="$(analytics_field dropped)"
      seq 100 | xargs -P20 -I{} curl -s -o /dev/null "${BASE_URL}/${MISSING}"
      E_DELTA=$(( $(analytics_field enqueued) - E_BEFORE + $(analytics_field dropped) - D_BEFORE ))
      if [[ "${E_DELTA}" -gt 0 ]]; then
        fail "100 404s produced ${E_DELTA} click attempts — misses must not be recorded."
      else
        pass "404s produce no click events."
      fi
    fi
  fi
fi
fi

# ===========================================================================
# 4. SINGLE-FLIGHT — concurrent misses collapse into one DB query
# ===========================================================================
if should_run 4; then
hdr "4. Single-flight — ${SF_PROBE_REQUESTS} concurrent misses on one cold code"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
else
  SF="$(create_link 'https://singleflight.example/')"
  if [[ -z "${SF}" ]] || ! invalidate "${SF}"; then
    fail "could not create + invalidate a cold code."
  else
    PRE="$(stat_field misses)"; curl -s -o /dev/null "${BASE_URL}/${SF}"
    if [[ $(( $(stat_field misses) - PRE )) -lt 1 ]]; then
      fail "code still cached after invalidate — probe would measure hits."
    else
      invalidate "${SF}"
      DB0="$(stat_field db_queries)"; M0="$(stat_field misses)"
      oha -n "${SF_PROBE_REQUESTS}" -c "${SF_PROBE_REQUESTS}" --no-tui \
        "${BASE_URL}/${SF}" >/dev/null 2>&1 || true
      DBD=$(( $(stat_field db_queries) - DB0 )); MD=$(( $(stat_field misses) - M0 ))
      detail "cache misses : ${MD}   DB queries : ${DBD}"
      if [[ "${MD}" -lt 1 ]]; then
        fail "zero misses — the code was not cold."
      elif [[ "${DBD}" -lt 1 ]]; then
        fail "zero DB queries — is db_queries wired to the trait impl?"
      elif [[ "${DBD}" -le 3 ]]; then
        pass "${MD} concurrent misses collapsed into ${DBD} DB quer(ies)."
      elif [[ "${DBD}" -le 20 ]]; then
        warn "PARTIAL coalescing: ${DBD} queries for ${MD} misses."
      else
        fail "${DBD} queries for ${MD} misses — little coalescing."
      fi
    fi
  fi
fi
fi

# ===========================================================================
# 5. REQUEST ID PROPAGATION
# ===========================================================================
if should_run 5; then
hdr "5. Request ID propagation"

hdr_id() {
  curl -s -D - -o /dev/null "$@" | grep -i '^x-request-id:' | head -n1 \
    | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

SUP="loadtest-$(date +%s)-$$"
ECHO="$(hdr_id -H "x-request-id: ${SUP}" "${BASE_URL}/health")"
G1="$(hdr_id "${BASE_URL}/health")"; G2="$(hdr_id "${BASE_URL}/health")"
ERR="$(hdr_id "${BASE_URL}/$(random_valid_code)")"
STATS_ID="$(hdr_id "${BASE_URL}/$(random_valid_code)/stats")"

[[ "${ECHO}" == "${SUP}" ]] && pass "supplied id echoed." || fail "supplied id not echoed (got '${ECHO}')."
[[ -n "${G1}" ]] && pass "id generated when absent." || fail "no id generated."
[[ -n "${G1}" && "${G1}" != "${G2}" ]] && pass "generated ids distinct." || fail "generated ids not distinct."
[[ -n "${ERR}" ]] && pass "404 carries x-request-id." || warn "404 has no x-request-id."
[[ -n "${STATS_ID}" ]] && pass "/stats responses carry x-request-id." || warn "/stats has no x-request-id."
fi

# ===========================================================================
# 6. RATE LIMITING — only meaningful against a small bucket
#
# In bench mode this is a SKIP, never a pass. The authoritative check is the
# integration test plus a manual run with RATE_LIMIT_REQUESTS=5.
# ===========================================================================
if should_run 6; then
hdr "6. Rate limiting"
skipped "bench-mode bucket is untrippable by design."
detail "Verify separately:"
detail "  RATE_LIMIT_REQUESTS=5 RATE_LIMIT_WINDOW_SECS=60 cargo run --release"
detail "  for i in \$(seq 10); do curl -s -o /dev/null -w '%{http_code} ' localhost:3000/health; done"
detail "  expect: 200 x5 then 429 x5"
fi

# ===========================================================================
# 7. STATS ENDPOINT CONTRACT  (Phase 4)
#
# GET /:code/stats is new surface area. Pin its contract before anything
# depends on it.
# ===========================================================================
if should_run 7; then
hdr "7. Stats endpoint contract — GET /:code/stats"

FRESH="$(create_link 'https://stats-contract.example/')"
if [[ -z "${FRESH}" ]]; then
  fail "could not create a link for the stats contract probe."
else
  BODY="$(curl -s "${BASE_URL}/${FRESH}/stats")"
  STAT="$(http_code "${BASE_URL}/${FRESH}/stats")"
  CT="$(curl -s -D - -o /dev/null "${BASE_URL}/${FRESH}/stats" | grep -i '^content-type:' | tr -d '\r')"
  detail "existing, never clicked -> ${STAT} ${BODY}"

  [[ "${STAT}" == "200" ]] && pass "existing link -> 200." || fail "existing link -> ${STAT}, expected 200."
  grep -qi 'application/json' <<<"${CT}" && pass "content-type is JSON." || fail "content-type is not JSON (${CT})."
  grep -q "\"code\":\"${FRESH}\"" <<<"${BODY}" && pass "body echoes the code." || fail "body does not contain code=${FRESH}."
  grep -qE '"clicks":0([,}])' <<<"${BODY}" \
    && pass "never-clicked link reports clicks=0." \
    || fail "never-clicked link does not report clicks=0: ${BODY}"

  S_UNKNOWN="$(http_code "${BASE_URL}/$(random_valid_code)/stats")"
  [[ "${S_UNKNOWN}" == "404" ]] \
    && pass "unknown code -> 404 (not clicks=0)." \
    || fail "unknown code -> ${S_UNKNOWN}; a nonexistent link must 404, not report 0."

  S_BAD="$(http_code "${BASE_URL}/has_underscore/stats")"
  [[ "${S_BAD}" == "404" || "${S_BAD}" == "400" ]] \
    && pass "malformed code -> ${S_BAD}." \
    || fail "malformed code -> ${S_BAD}."

  # Reading stats must not itself be counted as a click.
  B="$(stats_clicks "${FRESH}")"
  for _ in $(seq 20); do curl -s -o /dev/null "${BASE_URL}/${FRESH}/stats"; done
  sleep 0.5
  A="$(stats_clicks "${FRESH}")"
  [[ "${A}" -eq "${B}" ]] \
    && pass "reading /stats does not record clicks." \
    || fail "20 /stats reads changed the click count ${B} -> ${A}."

  # /stats must not consume the redirect path's cache in a way that breaks it.
  RD="$(http_code "${BASE_URL}/${FRESH}")"
  [[ "${RD}" =~ ^3 ]] && pass "redirect still works after /stats reads." || fail "redirect broken after /stats (${RD})."
fi
fi

# ===========================================================================
# 8. CLICK ACCOUNTING — no loss under normal load  (Phase 4)
#
# Fire a known number of redirects at a FRESH code below the channel's
# capacity, then poll the public stats endpoint until the count settles.
#
# In async mode the expected count is (redirects - dropped). Under normal
# load dropped should be 0, so stats must equal the redirect count exactly.
# A shortfall with zero drops means clicks are being LOST SILENTLY — the
# worst outcome, because the drop counter is the only loss we accept.
# ===========================================================================
if should_run 8; then
hdr "8. Click accounting — ${CLICK_PROBE_REQUESTS} redirects, exact count"

CODE8="$(create_link "https://click-accounting.example/$(date +%s)")"
if [[ -z "${CODE8}" ]]; then
  fail "could not create a link."
else
  BEFORE8="$(stats_clicks "${CODE8}")"
  if [[ "${BEFORE8}" -ne 0 ]]; then
    fail "fresh link already reports ${BEFORE8} clicks — precondition broken."
  else
    [[ "${ANALYTICS_AVAILABLE}" -eq 1 ]] && D8_BEFORE="$(analytics_field dropped)"

    # oha at moderate concurrency, exact request count. Count the 3xx it got,
    # because only SUCCESSFUL redirects record clicks.
    run_oha "${TMP_DIR}/oha_clicks.txt" -n "${CLICK_PROBE_REQUESTS}" -c 50 "${BASE_URL}/${CODE8}"
    SERVED="${OHA_3XX}"

    D8=0
    [[ "${ANALYTICS_AVAILABLE}" -eq 1 ]] && D8=$(( $(analytics_field dropped) - D8_BEFORE ))
    EXPECTED=$(( SERVED - D8 ))

    detail "redirects served : ${SERVED}"
    detail "clicks dropped   : ${D8}"
    detail "expected in DB   : ${EXPECTED}"

    t0="$(date +%s%N)"
    if GOT="$(wait_for_clicks "${CODE8}" "${EXPECTED}" "${CLICK_SETTLE_TIMEOUT_S}")"; then
      SETTLE_MS=$(( ( $(date +%s%N) - t0 ) / 1000000 ))
      detail "stats reports    : ${GOT}   (settled in ${SETTLE_MS} ms)"
      if [[ "${GOT}" -eq "${EXPECTED}" ]]; then
        pass "exact: ${GOT} clicks persisted for ${SERVED} redirects (${D8} dropped)."
      else
        fail "OVERCOUNT: ${GOT} clicks for ${EXPECTED} expected — duplicate writes?"
        detail "Check that a failed batch is not retried AND logged as written."
      fi
      record CLICK_SETTLE_MS "${SETTLE_MS}"
    else
      detail "stats reports    : ${GOT} after ${CLICK_SETTLE_TIMEOUT_S}s"
      LOST=$(( EXPECTED - GOT ))
      fail "SILENT LOSS: ${LOST} clicks neither persisted nor counted as dropped."
      detail "The drop counter is the only loss the design accepts. Likely causes:"
      detail "  * a failed insert_batch (check server log: 'click batch insert failed')"
      detail "  * the writer task panicked or exited"
      detail "  * clicks emitted on fewer success paths than redirects served"
    fi

    # Staleness bound: async mode trades freshness for throughput. The
    # settle time should be on the order of batch_wait_ms, not seconds.
    if [[ "${CLICK_MODE}" == "async" && -n "${SETTLE_MS:-}" && "${SETTLE_MS}" -gt 2000 ]]; then
      warn "clicks took ${SETTLE_MS} ms to become visible."
      detail "Expected roughly batch_wait_ms + one insert. Is the writer backlogged?"
    fi
  fi
fi
fi

# ===========================================================================
# 9. WRITER HEALTH & BATCHING EFFECTIVENESS  (Phase 4)
#
# Batching is the whole reason the writer is cheap. If rows_written/batches
# is ~1, every click is its own INSERT and the design is buying nothing.
# ===========================================================================
if should_run 9; then
hdr "9. Writer health & batching effectiveness"

if [[ "${ANALYTICS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/analytics."
elif [[ "${CLICK_MODE}" == "sync" ]]; then
  skipped "sync mode has no writer task."
else
  BATCHES="$(analytics_field batches)"
  ROWS="$(analytics_field rows_written)"
  FAILED="$(analytics_field failed_batches)"
  DEPTH="$(analytics_field queue_depth)"
  ENQ="$(analytics_field enqueued)"
  DROP="$(analytics_field dropped)"

  detail "enqueued       : ${ENQ}"
  detail "dropped        : ${DROP}"
  detail "batches        : ${BATCHES}"
  detail "rows written   : ${ROWS}"
  detail "failed batches : ${FAILED}"
  detail "queue depth    : ${DEPTH}  (now, after load)"

  if [[ "${BATCHES}" -eq 0 ]]; then
    fail "the writer has flushed zero batches — it is not running."
  else
    AVG="$(awk "BEGIN{printf \"%.1f\", ${ROWS}/${BATCHES}}")"
    detail "avg batch size : ${AVG} rows"
    record AVG_BATCH "${AVG}"
    if awk "BEGIN{exit !(${AVG} < 2)}"; then
      warn "average batch is ${AVG} rows — batching is not happening."
      detail "Each click is effectively its own INSERT. Under this load the"
      detail "writer should accumulate many rows per flush."
    else
      pass "batching effective: ~${AVG} rows per INSERT."
    fi
  fi

  [[ "${FAILED}" -gt 0 ]] \
    && fail "${FAILED} batch insert(s) failed — those clicks were lost." \
    || pass "no failed batch inserts."

  # Conservation: everything enqueued is either written, still queued, or in
  # a failed batch. A gap means rows vanished between channel and DB.
  sleep 1
  ROWS="$(analytics_field rows_written)"; DEPTH="$(analytics_field queue_depth)"
  IN_FLIGHT_MAX="$(analytics_field max_batch)"; IN_FLIGHT_MAX="${IN_FLIGHT_MAX:-500}"
  GAP=$(( ENQ - ROWS - DEPTH ))
  detail "conservation gap (enqueued - written - queued): ${GAP}"
  if [[ "${GAP}" -lt 0 ]]; then
    fail "more rows written than enqueued (${GAP}) — counters disagree."
  elif [[ "${GAP}" -gt "${IN_FLIGHT_MAX}" && "${FAILED}" -eq 0 ]]; then
    fail "${GAP} clicks unaccounted for with no failed batches."
  else
    pass "click conservation holds (gap ${GAP} ≤ one in-flight batch)."
  fi

  [[ "${DEPTH}" -gt 0 ]] \
    && warn "queue depth ${DEPTH} after load — the writer is still draining." \
    || pass "queue fully drained after load."
fi
fi

# ===========================================================================
# 10. PHASE 4 VERDICT — async vs sync p99  (the acceptance criterion)
# ===========================================================================
mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"

if should_run 10; then
hdr "10. Phase 4 acceptance — redirect p99, async vs sync"

SYNC_FILE="${RESULTS_DIR}/phase4_sync.env"
ASYNC_FILE="${RESULTS_DIR}/phase4_async.env"
detail "this run recorded to ${RESULT_FILE}"

if [[ ! -f "${SYNC_FILE}" || ! -f "${ASYNC_FILE}" ]]; then
  skipped "need BOTH runs to compare."
  [[ -f "${SYNC_FILE}" ]]  || detail "missing: sync run  (CLICK_MODE=sync  server + script)"
  [[ -f "${ASYNC_FILE}" ]] || detail "missing: async run (CLICK_MODE=async server + script)"
else
  get() { grep "^$2=" "$1" | tail -n1 | cut -d= -f2-; }
  S_P99="$(get "${SYNC_FILE}" HOT_P99)";  A_P99="$(get "${ASYNC_FILE}" HOT_P99)"
  S_P50="$(get "${SYNC_FILE}" HOT_P50)";  A_P50="$(get "${ASYNC_FILE}" HOT_P50)"
  S_RPS="$(get "${SYNC_FILE}" HOT_RPS)";  A_RPS="$(get "${ASYNC_FILE}" HOT_RPS)"
  S_DU="$(get "${SYNC_FILE}" HOT_DIALUP)"; A_DU="$(get "${ASYNC_FILE}" HOT_DIALUP)"
  S_TS="$(get "${SYNC_FILE}" TIMESTAMP)"; A_TS="$(get "${ASYNC_FILE}" TIMESTAMP)"
  S_C="$(get "${SYNC_FILE}" CONCURRENCY)"; A_C="$(get "${ASYNC_FILE}" CONCURRENCY)"

  printf '        %-12s %10s %10s %10s %10s\n' "" "req/s" "p50 ms" "p99 ms" "dialup"
  printf '        %-12s %10s %10s %10s %10s\n' "sync"  "${S_RPS}" "${S_P50}" "${S_P99}" "${S_DU}"
  printf '        %-12s %10s %10s %10s %10s\n' "async" "${A_RPS}" "${A_P50}" "${A_P99}" "${A_DU}"
  detail "sync run : ${S_TS}"
  detail "async run: ${A_TS}"

  VALID=1
  if [[ "${S_C}" != "${A_C}" ]]; then
    fail "runs used different concurrency (${S_C} vs ${A_C}) — not comparable."
    VALID=0
  fi
  if awk "BEGIN{exit !(${S_DU} > 7 || ${A_DU} > 7)}"; then
    warn "one or both runs had DNS+dialup > 7 ms — host contention likely."
    detail "Rerun the noisier mode before trusting the verdict."
  fi
  if [[ -z "${S_P99}" || -z "${A_P99}" || "${S_P99}" == "0" ]]; then
    fail "p99 missing from a results file — rerun both modes."
    VALID=0
  fi

  if [[ "${VALID}" -eq 1 ]]; then
    IMPROVE="$(awk "BEGIN{printf \"%.1f\", 100*(${S_P99}-${A_P99})/${S_P99}}")"
    RPS_GAIN="$(awk "BEGIN{printf \"%.1f\", 100*(${A_RPS}-${S_RPS})/${S_RPS}}")"
    detail ""
    detail "p99 improvement   : ${IMPROVE}%"
    detail "throughput change : ${RPS_GAIN}%"

    if awk "BEGIN{exit !(${IMPROVE} >= ${MATERIAL_IMPROVEMENT_PCT})}"; then
      pass "async p99 is ${IMPROVE}% lower than sync — materially better (≥${MATERIAL_IMPROVEMENT_PCT}%)."
      green "  M4: It's fast — acceptance criterion met."
    elif awk "BEGIN{exit !(${IMPROVE} > 0)}"; then
      fail "async p99 only ${IMPROVE}% better — not material (threshold ${MATERIAL_IMPROVEMENT_PCT}%)."
      detail "Possibilities: sync INSERT is faster than expected on a fresh DB,"
      detail "or the server was not actually in sync mode for the sync run."
    else
      fail "async p99 is WORSE than sync (${IMPROVE}%)."
      detail "Suspect a mislabelled run, a debug build, or host contention."
    fi
  fi
fi
fi

# ===========================================================================
# 11. CACHE STATISTICS SUMMARY
# ===========================================================================
if should_run 11 && [[ "${STATS_AVAILABLE}" -eq 1 ]]; then
hdr "11. Cache statistics (cumulative)"
H="$(stat_field hits)"; NG="$(stat_field negative_hits)"
M="$(stat_field misses)"; D="$(stat_field db_queries)"
T=$(( H + NG + M ))
if [[ "${T}" -gt 0 ]]; then
  R="$(awk "BEGIN{printf \"%.4f\", (${H}+${NG})/${T}}")"
  detail "hits ${H} · negative ${NG} · misses ${M} · db ${D}"
  detail "hit ratio ${R}  ->  expected ~$(awk "BEGIN{printf \"%.0f\", ${R}*${BENCH_HIT_NS}+(1-${R})*${BENCH_MISS_NS}}") ns/lookup"
  warn "cumulative counters, not a rate — Prometheus rate() is the Phase 5 form."
fi
fi

# ===========================================================================
# VERDICT
# ===========================================================================
hdr "Verdict  (CLICK_MODE=${CLICK_MODE})"
detail "results: ${RESULT_FILE}"
if [[ "${FAILURES}" -eq 0 ]]; then
  green "  All probes passed.  (${WARNINGS} warning(s))"
  echo; exit 0
else
  red "  ${FAILURES} probe(s) FAILED.  (${WARNINGS} warning(s))"
  echo; exit 1
fi

# ===========================================================================
# APPENDIX — server-side support this script expects
# ===========================================================================
#
# 1. Counters on ClickSender / the writer (workers/analytics_writer.rs):
#
#    #[derive(Default)]
#    pub struct WriterStats {
#        pub enqueued: AtomicU64,
#        pub dropped: AtomicU64,
#        pub batches: AtomicU64,
#        pub rows_written: AtomicU64,
#        pub failed_batches: AtomicU64,
#    }
#
#    - record():  Ok  => enqueued += 1 ;  Err => dropped += 1
#    - writer:    Ok  => batches += 1, rows_written += batch.len()
#                 Err => failed_batches += 1
#    - queue depth: tx.max_capacity() - tx.capacity()
#
# 2. GET /debug/analytics (dev only, next to /debug/cache):
#
#    Json(json!({
#        "mode": "async",                 // or "sync"
#        "enqueued": s.enqueued, "dropped": s.dropped,
#        "batches": s.batches, "rows_written": s.rows_written,
#        "failed_batches": s.failed_batches,
#        "queue_depth": sender.queue_depth(),
#        "max_batch": cfg.max_batch,
#    }))
#
# 3. CLICK_MODE=sync|async read in config::load(). In sync mode,
#    RedirectService awaits click_repo.insert_batch(&[click]) instead of
#    calling clicks.record(). Remove the sync path once Phase 4 is proven —
#    it exists only to produce the baseline the acceptance criterion needs.
