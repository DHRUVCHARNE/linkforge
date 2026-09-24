#!/usr/bin/env bash
#
# load_test.sh — LinkForge load / correctness / benchmark harness
#
# Phase 3: Postgres + read-through cache + negative caching + single-flight
#          + tracing + x-request-id + per-IP token-bucket rate limiting.
#
# ---------------------------------------------------------------------------
# DESIGN PRINCIPLE: A TEST THAT PASSES FOR THE WRONG REASON IS WORSE THAN ONE
# THAT FAILS.
# ---------------------------------------------------------------------------
# Earlier revisions of this script reported PASS while proving nothing:
#
#   1. The "nonexistent" probe codes were 12-15 chars, but ShortCode::parse
#      enforces 1..=10. Every request was rejected by DOMAIN VALIDATION before
#      the cache was consulted. Counters stayed flat, and "0 misses" was read
#      as success.
#   2. The single-flight probe's invalidate call failed silently (`|| red`
#      does not abort under `set -e`), so all 200 requests hit a WARM cache.
#   3. The single-flight probe measured `misses` (the CACHE layer) to infer DB
#      queries — but coalescing happens BELOW the cache. The probe was
#      structurally incapable of observing the thing it tested.
#
# ---------------------------------------------------------------------------
# THE NEW PHASE 3 HAZARD: THE RATE LIMITER THROTTLES THIS SCRIPT
# ---------------------------------------------------------------------------
# Every request from this script originates at one IP, so they all share ONE
# token bucket. At ~9,700 req/s any sane bucket rejects the overwhelming
# majority. A throughput probe that is being rate limited measures the
# LIMITER, not the handler — numbers that look plausible and mean nothing.
#
# This script therefore:
#   * detects throttling explicitly before trusting any measurement
#   * counts 429s during load and FAILS if they appear in a non-limiter probe
#   * requires the server to be started with a benchmark-scale bucket
#     (see BENCH MODE below)
#   * exercises the limiter deliberately in ONE probe that expects 429s
#
# BENCH MODE: start the server with a bucket that cannot interfere, e.g.
#   LINKFORGE__RATE_LIMIT__REQUESTS=100000000 \
#   LINKFORGE__RATE_LIMIT__WINDOW_SECS=1 just run
# then run this script. Probe 6 (rate limiting) spells out how it verifies
# the limiter separately.
#
# ---------------------------------------------------------------------------
# REQUIREMENTS
# ---------------------------------------------------------------------------
#   * A running LinkForge server (`just run`)
#   * Dev-only introspection routes, registered when env = development:
#       GET  /debug/cache
#         -> {"hits":N,"negative_hits":N,"misses":N,"db_queries":N,"ratio":F}
#       POST /debug/cache/invalidate/{code}
#   * Optional: `oha` (strongly preferred) or `wrk` for load generation
#
# Usage:
#   ./scripts/load_test.sh [BASE_URL] [N_REQUESTS] [CONCURRENCY]
#
# Exit code: 0 if every probe passed, 1 otherwise (CI-friendly).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_URL="${1:-http://localhost:3000}"
N="${2:-10000}"
CONCURRENCY="${3:-100}"

NEG_PROBE_REQUESTS="${NEG_PROBE_REQUESTS:-500}"
SF_PROBE_REQUESTS="${SF_PROBE_REQUESTS:-200}"
LOAD_DURATION="${LOAD_DURATION:-10s}"

# How many rapid requests probe 6 fires to prove the limiter engages. Must
# exceed the server's configured bucket capacity, or the probe cannot trip it.
RL_PROBE_REQUESTS="${RL_PROBE_REQUESTS:-300}"

# Measured application-level costs (from `cargo bench`). Used to translate a
# hit ratio into an expected per-lookup cost. Update when the bench changes.
BENCH_HIT_NS="${BENCH_HIT_NS:-219}"
BENCH_MISS_NS="${BENCH_MISS_NS:-450000}"

STATS_URL="${BASE_URL}/debug/cache"
FAILURES=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m';  C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_YELLOW=''; C_BOLD=''; C_RESET=''
fi

green() { printf '%s%s%s\n' "${C_GREEN}"  "$*" "${C_RESET}"; }
red()   { printf '%s%s%s\n' "${C_RED}"    "$*" "${C_RESET}"; }
info()  { printf '%s%s%s\n' "${C_CYAN}"   "$*" "${C_RESET}"; }
warn()  { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; WARNINGS=$(( WARNINGS + 1 )); }
hdr()   { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

pass()    { green "  PASS: $*"; }
fail()    { red   "  FAIL: $*"; FAILURES=$(( FAILURES + 1 )); }
skipped() { printf '%s  SKIPPED: %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
detail()  { printf '        %s\n' "$*"; }

# ---------------------------------------------------------------------------
# HTTP / stats helpers
# ---------------------------------------------------------------------------

has_stats() { curl -fsS "${STATS_URL}" >/dev/null 2>&1; }

# Read a numeric field from /debug/cache. Returns 0 if absent so arithmetic
# never explodes — a permanently-zero counter is caught by anti-vacuity checks.
stat_field() {
  local val
  val="$(curl -s "${STATS_URL}" 2>/dev/null \
        | grep -o "\"$1\":[0-9.]*" | head -n1 | sed 's/.*://')" || true
  printf '%s' "${val:-0}"
}

assert_stats_schema() {
  local body missing=""
  body="$(curl -s "${STATS_URL}")"
  for f in hits negative_hits misses db_queries; do
    grep -q "\"${f}\"" <<<"${body}" || missing="${missing} ${f}"
  done
  if [[ -n "${missing}" ]]; then
    fail "/debug/cache is missing field(s):${missing}"
    detail "Probes depending on them cannot run. Add them to handlers/debug.rs."
    return 1
  fi
  return 0
}

http_code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
http_time() { curl -s -o /dev/null -w '%{time_total}' "$1"; }

extract_code() { grep -o '"code":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"//'; }

create_link() {
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d "{\"url\":\"$1\"}" | extract_code
}

invalidate() {
  curl -fsS -X POST "${BASE_URL}/debug/cache/invalidate/$1" >/dev/null 2>&1
}

# Generate a syntactically VALID short code unlikely to exist.
# CRITICAL: must satisfy ShortCode::parse (base62, length 1..=10), or the
# request is rejected by the domain layer and NEVER REACHES THE CACHE.
random_valid_code() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 8 || true
}

assert_well_formed() {
  local code="$1" label="$2" status
  status="$(http_code "${BASE_URL}/${code}")"
  case "${status}" in
    400) fail "${label}: code '${code}' rejected as malformed (400)."
         detail "It never reached the cache. Check ShortCode::parse constraints."
         return 1 ;;
    404) return 0 ;;
    429) fail "${label}: rate limited (429) — cannot establish a baseline."
         detail "Restart the server in BENCH MODE (see header)."
         return 1 ;;
    *)   fail "${label}: unexpected status ${status} for a nonexistent code."
         return 1 ;;
  esac
}

# --- PHASE 3: throttle detection -------------------------------------------
#
# Returns 0 if a single request is currently being rate limited. Used as a
# precondition guard: any probe that measures something OTHER than the limiter
# must first confirm it is not being throttled.
is_throttled() {
  [[ "$(http_code "${BASE_URL}/health")" == "429" ]]
}

# Abort a probe if the limiter is interfering. The whole point: a throttled
# measurement is not a measurement of the thing under test.
guard_not_throttled() {
  local label="$1"
  if is_throttled; then
    fail "${label}: server is rate limiting this client."
    detail "Measurements would reflect the limiter, not the handler."
    detail "Restart in BENCH MODE (see script header) and rerun."
    return 1
  fi
  return 0
}

# Fire N requests at one URL with genuine concurrency.
#
# Prefer oha: it uses async tasks, so requests truly overlap. `xargs -P` spawns
# PROCESSES (~1-5ms startup each) — far slower than a ~450us query — so the
# leader finishes before later requests start and coalescing is understated.
fire_concurrent() {
  local url="$1" count="$2"
  if command -v oha >/dev/null 2>&1; then
    oha -n "${count}" -c "${count}" --no-tui "${url}" >/dev/null 2>&1 || true
  else
    seq "${count}" | xargs -P"${count}" -I{} curl -s -o /dev/null "${url}"
  fi
}

# Fire N sequential requests, printing one status code per line. Used by the
# rate-limit probe, which needs the STATUS DISTRIBUTION, not just a total.
fire_sequential_statuses() {
  local url="$1" count="$2" i
  for (( i = 0; i < count; i++ )); do
    http_code "${url}"
    printf '\n'
  done
}

# ===========================================================================
# 0. PRE-FLIGHT
# ===========================================================================
hdr "0. Pre-flight"

info "==> Health check: ${BASE_URL}/health"
if ! curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
  # A 429 makes curl -f fail too — distinguish the two so the operator gets an
  # actionable message rather than "server is down".
  if [[ "$(http_code "${BASE_URL}/health")" == "429" ]]; then
    red "Server is UP but already rate limiting this client."
    red "Restart in BENCH MODE (see script header) before load testing."
    exit 1
  fi
  red "Server is not responding at ${BASE_URL}. Start it first (just run)."
  exit 1
fi
green "  Server is up."

STATS_AVAILABLE=0
if has_stats && assert_stats_schema; then
  STATS_AVAILABLE=1
  green "  Cache stats endpoint available with full schema."
else
  warn "/debug/cache unavailable or incomplete."
  detail "Cache-aware probes will be SKIPPED (not silently passed)."
  detail "Set env = development so app/router.rs registers the debug routes."
fi

command -v oha >/dev/null 2>&1 \
  || warn "oha not installed — concurrency probes will use the weaker xargs path."

# --- PHASE 3: headline bucket-capacity check -------------------------------
#
# Burst a modest number of requests. If ANY are rejected, the configured bucket
# is far too small for a benchmark and every subsequent number is suspect.
info "==> Rate limiter headroom check"
RL_PREFLIGHT_N=50
RL_PREFLIGHT_429="$(
  fire_sequential_statuses "${BASE_URL}/health" "${RL_PREFLIGHT_N}" \
    | grep -c '^429$' || true
)"
detail "burst of ${RL_PREFLIGHT_N} requests -> ${RL_PREFLIGHT_429} rejected (429)"

BENCH_MODE=1
if [[ "${RL_PREFLIGHT_429}" -gt 0 ]]; then
  BENCH_MODE=0
  warn "Rate limiter engages within ${RL_PREFLIGHT_N} requests."
  detail "Throughput and cache probes will be SKIPPED — they would measure"
  detail "the limiter rather than the application."
  detail "Restart in BENCH MODE (see script header) to run them."
else
  green "  Limiter has headroom; measurement probes can run."
fi

# ===========================================================================
# 1. CORRECTNESS: concurrent writes must never collide
# ===========================================================================
hdr "1. Correctness probe — ${N} concurrent POST /shorten (c=${CONCURRENCY})"

if [[ "${BENCH_MODE}" -eq 0 ]]; then
  skipped "rate limiter would reject most writes; results would be meaningless."
else
  TMP_CODES="$(mktemp)"
  TMP_STATUS="$(mktemp)"
  trap 'rm -f "${TMP_CODES}" "${TMP_STATUS}"' EXIT

  # Capture the HTTP status alongside the body so failures are diagnosable.
  # Previously a failed write was simply an absent line — indistinguishable
  # from a 429, a 500, or a dropped connection.
  seq "${N}" | xargs -P"${CONCURRENCY}" -I{} \
    curl -s -w '\nSTATUS:%{http_code}\n' -X POST "${BASE_URL}/shorten" \
      -H 'content-type: application/json' \
      -d '{"url":"https://example.com/{}"}' \
    >> "${TMP_STATUS}" || true

  grep -o '"code":"[^"]*"' "${TMP_STATUS}" >> "${TMP_CODES}" || true

  TOTAL="$(wc -l < "${TMP_CODES}" | tr -d ' ')"
  UNIQUE="$(sort -u "${TMP_CODES}" | wc -l | tr -d ' ')"
  DUPES=$(( TOTAL - UNIQUE ))
  FAILED_WRITES=$(( N - TOTAL ))
  SUCCESS_PCT="$(awk "BEGIN{printf \"%.2f\", 100*${TOTAL}/${N}}")"

  COUNT_429="$(grep -c '^STATUS:429$' "${TMP_STATUS}" || true)"
  COUNT_500="$(grep -c '^STATUS:500$' "${TMP_STATUS}" || true)"

  detail "generated codes : ${TOTAL} / ${N}  (${SUCCESS_PCT}%)"
  detail "unique codes    : ${UNIQUE}"
  detail "duplicates      : ${DUPES}"
  detail "failed writes   : ${FAILED_WRITES}"
  detail "  of which 429  : ${COUNT_429}  (rate limited)"
  detail "  of which 500  : ${COUNT_500}  (server error)"

  if [[ "${TOTAL}" -lt $(( N / 2 )) ]]; then
    fail "only ${TOTAL}/${N} shortens succeeded — probe is not measuring what it claims."
  elif [[ "${DUPES}" -ne 0 ]]; then
    fail "found ${DUPES} duplicate code(s) under concurrency."
  else
    pass "zero duplicate codes across ${TOTAL} concurrent shortens."
  fi

  # Any 429 here means the limiter interfered with a correctness probe.
  if [[ "${COUNT_429}" -gt 0 ]]; then
    fail "${COUNT_429} writes were rate limited — this probe must not be throttled."
    detail "Restart in BENCH MODE (see script header)."
  fi

  if [[ "${FAILED_WRITES}" -gt 0 ]]; then
    FAIL_PCT="$(awk "BEGIN{printf \"%.2f\", 100*${FAILED_WRITES}/${N}}")"
    if [[ "${FAILED_WRITES}" -gt $(( N / 20 )) ]]; then
      fail "${FAILED_WRITES} writes failed (${FAIL_PCT}%) — above the 5% tolerance."
    else
      warn "${FAILED_WRITES} writes failed (${FAIL_PCT}%)."
    fi
    detail "With tracing now wired, read the server log for the sqlx error"
    detail "variant: PoolTimedOut vs a unique violation are different bugs."
    detail "  RUST_LOG=linkforge=debug,sqlx=warn just run"
    detail "NOTE: write failures grow with table size. Run against a fresh"
    detail "database (just db-reset) for comparable numbers."
  fi
fi

# ===========================================================================
# 2. THROUGHPUT: hot read path (100% cache hits)
# ===========================================================================
hdr "2. Throughput probe — hot read path GET /:code"

if [[ "${BENCH_MODE}" -eq 0 ]]; then
  skipped "rate limiter active; throughput would measure the limiter."
else
  SEED_CODE="$(create_link 'https://www.rust-lang.org')"

  if [[ -z "${SEED_CODE}" ]]; then
    fail "could not seed a link for the throughput probe."
  elif ! guard_not_throttled "throughput probe"; then
    : # guard already recorded the failure
  else
    detail "seeded code: ${SEED_CODE}"
    TARGET_URL="${BASE_URL}/${SEED_CODE}"

    # Warm the cache so this measures the hit path, not a cold start.
    curl -s -o /dev/null "${TARGET_URL}"

    if command -v oha >/dev/null 2>&1; then
      info "  oha: ${LOAD_DURATION}, c=${CONCURRENCY}, keepalive on"
      oha -z "${LOAD_DURATION}" -c "${CONCURRENCY}" --no-tui "${TARGET_URL}"

      # Post-check: did the limiter engage DURING the run? oha's own status
      # distribution is printed above, but we assert explicitly here so a
      # 429-dominated run cannot be mistaken for a throughput result.
      if is_throttled; then
        fail "server is rate limiting immediately after the load run."
        detail "The throughput figure above includes 429 responses and is invalid."
        detail "Check oha's status distribution: it should be 100% 3xx."
      else
        pass "no throttling detected around the throughput run."
      fi
    elif command -v wrk >/dev/null 2>&1; then
      info "  wrk: ${LOAD_DURATION}, c=${CONCURRENCY}"
      wrk -t4 -c"${CONCURRENCY}" -d"${LOAD_DURATION}" "${TARGET_URL}"
    else
      skipped "neither 'oha' nor 'wrk' found. Install: cargo install oha"
    fi

    warn "Interpretation: the load generator shares this host with the server."
    detail "Throughput here is environment-bound, not application-bound."
    detail "Phase 3 adds per-request tracing, which costs real CPU — expect a"
    detail "measurable drop vs the Phase 2 baseline. That is a tradeoff, not"
    detail "a regression. Compare only runs on identical hardware, and treat"
    detail "~2% run-to-run variance as the noise floor."
  fi
fi

# ===========================================================================
# 3. NEGATIVE CACHING: repeated 404s must stop reaching Postgres
# ===========================================================================
hdr "3. Negative caching probe — ${NEG_PROBE_REQUESTS} repeat 404s"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
elif [[ "${BENCH_MODE}" -eq 0 ]]; then
  skipped "rate limiter active; repeat requests would be rejected, not cached."
else
  MISSING_CODE="$(random_valid_code)"
  detail "probe code: ${MISSING_CODE} (${#MISSING_CODE} chars, base62)"

  if assert_well_formed "${MISSING_CODE}" "negative-cache probe"; then
    invalidate "${MISSING_CODE}" || true

    BEFORE_MISS="$(stat_field misses)"
    BEFORE_NEG="$(stat_field negative_hits)"
    BEFORE_DB="$(stat_field db_queries)"

    STATUS="$(http_code "${BASE_URL}/${MISSING_CODE}")"
    AFTER_FIRST_MISS="$(stat_field misses)"
    AFTER_FIRST_DB="$(stat_field db_queries)"

    FIRST_MISS_DELTA=$(( AFTER_FIRST_MISS - BEFORE_MISS ))
    FIRST_DB_DELTA=$(( AFTER_FIRST_DB - BEFORE_DB ))

    seq "${NEG_PROBE_REQUESTS}" \
      | xargs -P50 -I{} curl -s -o /dev/null "${BASE_URL}/${MISSING_CODE}"

    AFTER_ALL_MISS="$(stat_field misses)"
    AFTER_ALL_NEG="$(stat_field negative_hits)"
    AFTER_ALL_DB="$(stat_field db_queries)"

    REST_DB_DELTA=$(( AFTER_ALL_DB - AFTER_FIRST_DB ))
    NEG_DELTA=$(( AFTER_ALL_NEG - BEFORE_NEG ))
    NEG_THRESHOLD=$(( NEG_PROBE_REQUESTS * 8 / 10 ))

    detail "status of 1st request      : ${STATUS}  (expect 404)"
    detail "cache misses, 1st request  : ${FIRST_MISS_DELTA}  (expect 1)"
    detail "DB queries,   1st request  : ${FIRST_DB_DELTA}  (expect 1)"
    detail "DB queries,   next ${NEG_PROBE_REQUESTS}     : ${REST_DB_DELTA}  (expect 0)"
    detail "negative hits recorded     : ${NEG_DELTA}  (expect ~${NEG_PROBE_REQUESTS})"

    if [[ "${STATUS}" == "429" ]]; then
      fail "probe was rate limited; negative caching was never exercised."
    elif [[ "${STATUS}" != "404" ]]; then
      fail "expected 404 for a nonexistent code, got ${STATUS}."
    elif [[ "${FIRST_MISS_DELTA}" -lt 1 ]]; then
      fail "first request caused no cache miss — requests are not reaching the cache."
      detail "Domain validation is likely rejecting the code before lookup."
    elif [[ "${FIRST_DB_DELTA}" -lt 1 ]]; then
      fail "first request caused no DB query — is db_queries wired up?"
      detail "Check query_count() is on the LinkRepository trait impl, not an"
      detail "inherent impl: through Arc<dyn Trait> the default body returns 0."
    elif [[ "${NEG_DELTA}" -lt "${NEG_THRESHOLD}" ]]; then
      fail "only ${NEG_DELTA} negative hits for ${NEG_PROBE_REQUESTS} requests."
      detail "Negative caching is not engaging as expected."
    elif [[ "${REST_DB_DELTA}" -ne 0 ]]; then
      fail "${REST_DB_DELTA} repeat 404s still reached the database."
      detail "Is negative_ttl_secs shorter than this probe's runtime?"
    else
      pass "${NEG_PROBE_REQUESTS} repeat 404s absorbed; exactly ${FIRST_DB_DELTA} DB query."
    fi

    NEG_HIT_S="$(http_time "${BASE_URL}/${MISSING_CODE}")"
    COLD_S="$(http_time "${BASE_URL}/$(random_valid_code)")"
    detail "negative-cache hit : ${NEG_HIT_S}s"
    detail "cold 404 (DB)      : ${COLD_S}s"
    warn "End-to-end curl timings are dominated by TCP + process cost."
    detail "The true ${BENCH_HIT_NS}ns vs ${BENCH_MISS_NS}ns gap is only"
    detail "visible in cargo bench, never through curl."
  fi
fi

# ===========================================================================
# 4. SINGLE-FLIGHT: concurrent misses must collapse into one DB query
# ===========================================================================
hdr "4. Single-flight probe — ${SF_PROBE_REQUESTS} concurrent misses, one cold code"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
elif [[ "${BENCH_MODE}" -eq 0 ]]; then
  skipped "rate limiter active; concurrent misses would be rejected, not coalesced."
else
  SF_CODE="$(create_link 'https://singleflight.example/')"

  if [[ -z "${SF_CODE}" ]]; then
    fail "could not create a link for the single-flight probe."
  elif ! invalidate "${SF_CODE}"; then
    fail "invalidate endpoint failed — cannot make the code cold."
    detail "Without a cold code this probe measures cache HITS, not misses."
  else
    detail "probe code: ${SF_CODE}"

    # --- VERIFY the precondition: one request must register a cache miss ---
    PRE_MISS="$(stat_field misses)"
    curl -s -o /dev/null "${BASE_URL}/${SF_CODE}"
    POST_MISS="$(stat_field misses)"

    if [[ $(( POST_MISS - PRE_MISS )) -lt 1 ]]; then
      fail "code is still cached after invalidate — probe would measure hits."
      detail "Verify POST /debug/cache/invalidate actually removes the entry."
    else
      invalidate "${SF_CODE}"

      SF_DB_BEFORE="$(stat_field db_queries)"
      SF_MISS_BEFORE="$(stat_field misses)"

      detail "firing ${SF_PROBE_REQUESTS} requests @ concurrency ${SF_PROBE_REQUESTS}"
      fire_concurrent "${BASE_URL}/${SF_CODE}" "${SF_PROBE_REQUESTS}"

      SF_DB_AFTER="$(stat_field db_queries)"
      SF_MISS_AFTER="$(stat_field misses)"

      DB_DELTA=$(( SF_DB_AFTER - SF_DB_BEFORE ))
      MISS_DELTA=$(( SF_MISS_AFTER - SF_MISS_BEFORE ))

      detail "requests fired : ${SF_PROBE_REQUESTS}"
      detail "cache misses   : ${MISS_DELTA}   (requests that found no entry)"
      detail "DB queries     : ${DB_DELTA}   (expect ~1 if coalescing works)"

      # THE KEY DISTINCTION: every request checks the cache BEFORE reaching the
      # inflight registry, so MISS_DELTA counts would-be DB queries while
      # DB_DELTA counts actual ones. Single-flight exists to make them diverge.
      if [[ "${MISS_DELTA}" -lt 1 ]]; then
        fail "zero cache misses — the code was not cold; probe is invalid."
      elif [[ "${DB_DELTA}" -lt 1 ]]; then
        fail "zero DB queries for ${MISS_DELTA} cache misses — is db_queries wired up?"
      else
        COALESCE_RATIO="$(awk "BEGIN{printf \"%.1f\", ${MISS_DELTA}/${DB_DELTA}}")"
        detail "coalescing ratio : ${COALESCE_RATIO}x"

        if [[ "${DB_DELTA}" -le 3 ]]; then
          pass "${MISS_DELTA} concurrent misses collapsed into ${DB_DELTA} DB quer(ies)."
          detail "Without single-flight this would be ${MISS_DELTA}."
        elif [[ "${DB_DELTA}" -le 20 ]]; then
          warn "PARTIAL: ${DB_DELTA} DB queries for ${MISS_DELTA} cache misses."
          detail "Coalescing works, but flights did not fully overlap."
          detail "Expected when the leader completes before later arrivals."
        else
          fail "${DB_DELTA} DB queries for ${MISS_DELTA} cache misses — little coalescing."
          detail "Check the inflight registry: is the lock released before the"
          detail "DB call, and deregistration done BEFORE broadcasting?"
        fi
      fi
      detail "NOTE: the ratio is not a constant. It depends on how long the"
      detail "leader's query takes relative to arrival rate — a warm DB yields"
      detail "a lower ratio because fewer requests arrive mid-flight."
    fi
  fi
fi

# ===========================================================================
# 5. REQUEST ID PROPAGATION  (Phase 3 acceptance criterion)
#
# "logs correlate a request across middleware and handler"
#
# The observable half of that is the response header: a supplied x-request-id
# must be echoed back, and an absent one must be generated. Log correlation
# itself must be eyeballed in the server output — the script prints the ID to
# grep for.
# ===========================================================================
hdr "5. Request ID propagation"

# --- 5a. A client-supplied ID must be echoed unchanged ---------------------
SUPPLIED_ID="loadtest-$(date +%s)-$$"
ECHOED_ID="$(
  curl -s -D - -o /dev/null -H "x-request-id: ${SUPPLIED_ID}" \
    "${BASE_URL}/health" \
  | grep -i '^x-request-id:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
)"

detail "sent     x-request-id: ${SUPPLIED_ID}"
detail "received x-request-id: ${ECHOED_ID:-<none>}"

if [[ -z "${ECHOED_ID}" ]]; then
  fail "no x-request-id on the response."
  detail "Is PropagateRequestIdLayer in the middleware stack?"
elif [[ "${ECHOED_ID}" != "${SUPPLIED_ID}" ]]; then
  fail "x-request-id was not preserved (got '${ECHOED_ID}')."
  detail "SetRequestIdLayer should only generate one when absent."
else
  pass "client-supplied x-request-id echoed unchanged."
fi

# --- 5b. An absent ID must be generated ------------------------------------
GENERATED_ID="$(
  curl -s -D - -o /dev/null "${BASE_URL}/health" \
  | grep -i '^x-request-id:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
)"

detail "generated id (no header sent): ${GENERATED_ID:-<none>}"

if [[ -z "${GENERATED_ID}" ]]; then
  fail "no x-request-id generated when the client did not supply one."
  detail "Is SetRequestIdLayer::x_request_id(MakeRequestUuid) wired up?"
elif [[ "${GENERATED_ID}" == "${SUPPLIED_ID}" ]]; then
  fail "generated id equals the previously supplied id — IDs are not unique."
else
  pass "an x-request-id was generated for a request that omitted it."
fi

# --- 5c. Two requests must get distinct generated IDs ----------------------
SECOND_ID="$(
  curl -s -D - -o /dev/null "${BASE_URL}/health" \
  | grep -i '^x-request-id:' | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
)"

if [[ -n "${GENERATED_ID}" && "${GENERATED_ID}" == "${SECOND_ID}" ]]; then
  fail "two requests received the SAME generated id — correlation is impossible."
else
  pass "generated ids are distinct across requests."
fi

# --- 5d. Log correlation: give the operator something to grep --------------
CORRELATE_ID="correlate-$(date +%s)-$$"
curl -s -o /dev/null -H "x-request-id: ${CORRELATE_ID}" \
  "${BASE_URL}/$(random_valid_code)"

info "  Manual check — log correlation across middleware AND handler:"
detail "In the server output, this single id should appear on BOTH the"
detail "middleware span and the handler's own events:"
detail ""
detail "    grep '${CORRELATE_ID}' <server log>"
detail ""
detail "A script cannot verify this without scraping stdout, which couples the"
detail "harness to log formatting. Verify it once by eye, then rely on the"
detail "header assertions above as the regression guard."

# ===========================================================================
# 6. RATE LIMITING  (Phase 3 acceptance criterion)
#
# "exceeding the rate returns 429"
#
# This is the ONE probe that WANTS to be throttled. It runs last so the
# buckets it drains cannot affect any measurement probe.
#
# It requires a server whose bucket is small enough to trip within
# RL_PROBE_REQUESTS. In BENCH MODE the bucket is deliberately enormous, so
# this probe will correctly report that it could not exercise the limiter —
# which is a SKIP, not a pass.
# ===========================================================================
hdr "6. Rate limiting — per-IP 429"

detail "firing ${RL_PROBE_REQUESTS} rapid sequential requests at /health"

RL_STATUSES="$(fire_sequential_statuses "${BASE_URL}/health" "${RL_PROBE_REQUESTS}")"
RL_200="$(grep -c '^200$' <<<"${RL_STATUSES}" || true)"
RL_429="$(grep -c '^429$' <<<"${RL_STATUSES}" || true)"
RL_OTHER=$(( RL_PROBE_REQUESTS - RL_200 - RL_429 ))

detail "200 OK            : ${RL_200}"
detail "429 Too Many Reqs : ${RL_429}"
detail "other             : ${RL_OTHER}"

if [[ "${RL_429}" -eq 0 ]]; then
  if [[ "${BENCH_MODE}" -eq 1 ]]; then
    # Expected in bench mode. Report honestly rather than passing vacuously.
    skipped "no 429 in ${RL_PROBE_REQUESTS} requests — bucket is benchmark-sized."
    detail "This does NOT prove the limiter works. Verify it separately:"
    detail "  LINKFORGE__RATE_LIMIT__REQUESTS=5 \\"
    detail "  LINKFORGE__RATE_LIMIT__WINDOW_SECS=60 just run"
    detail "  ./scripts/load_test.sh   # probe 6 should then report 429s"
    detail "The integration test exceeding_the_bucket_returns_429 is the"
    detail "authoritative check; this probe is a smoke test."
  else
    fail "limiter engaged during pre-flight but produced no 429 here."
    detail "Inconsistent behaviour — investigate the bucket refill math."
  fi
else
  pass "limiter returned ${RL_429} × 429 after ${RL_200} allowed requests."

  # --- Verify the 429 response is well-formed ------------------------------
  RL_HEADERS="$(curl -s -D - -o /dev/null "${BASE_URL}/health")"
  RL_STATUS_LINE="$(head -n1 <<<"${RL_HEADERS}" | tr -d '\r')"

  if grep -qi '^retry-after:' <<<"${RL_HEADERS}"; then
    RETRY_AFTER="$(grep -i '^retry-after:' <<<"${RL_HEADERS}" \
                  | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
    pass "429 carries retry-after: ${RETRY_AFTER}"
  else
    # Not fatal, but a 429 without retry-after gives clients no backoff signal.
    warn "429 response has no retry-after header."
    detail "Clients have no guidance on when to retry. Status line: ${RL_STATUS_LINE}"
    detail "Check the header name is hyphenated ('retry-after'), not underscored."
  fi

  # --- Verify recovery: tokens must refill ---------------------------------
  detail "waiting 3s to confirm the bucket refills..."
  sleep 3
  RECOVERED="$(http_code "${BASE_URL}/health")"
  detail "status after 3s idle: ${RECOVERED}"

  if [[ "${RECOVERED}" == "429" ]]; then
    warn "still throttled after 3s — refill rate may be very low."
    detail "Expected if window_secs is large. Not necessarily a bug."
  else
    pass "bucket refilled; requests are accepted again."
  fi
fi

# ===========================================================================
# 7. CACHE STATISTICS SUMMARY
# ===========================================================================
hdr "7. Cache statistics (cumulative over this run)"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
else
  HITS="$(stat_field hits)"
  NEG="$(stat_field negative_hits)"
  MISS="$(stat_field misses)"
  DBQ="$(stat_field db_queries)"
  TOTAL_LOOKUPS=$(( HITS + NEG + MISS ))

  if [[ "${TOTAL_LOOKUPS}" -eq 0 ]]; then
    fail "no cache lookups recorded across the entire run."
    detail "Every request was rejected before reaching the cache."
  else
    RATIO="$(awk "BEGIN{printf \"%.4f\", (${HITS}+${NEG})/${TOTAL_LOOKUPS}}")"
    PCT="$(awk   "BEGIN{printf \"%.2f\", 100*(${HITS}+${NEG})/${TOTAL_LOOKUPS}}")"

    detail "positive hits : ${HITS}"
    detail "negative hits : ${NEG}"
    detail "cache misses  : ${MISS}"
    detail "DB queries    : ${DBQ}"
    detail "total lookups : ${TOTAL_LOOKUPS}"
    green  "    HIT RATIO : ${PCT}%  (${RATIO})"

    # Anti-vacuity at the run level.
    if [[ "${BENCH_MODE}" -eq 1 && "${NEG}" -eq 0 && "${MISS}" -eq 0 ]]; then
      fail "100% positive hits, zero misses and zero negative hits."
      detail "The cache-aware probes did not exercise their code paths."
    fi

    if [[ "${MISS}" -gt 0 && "${DBQ}" -gt 0 ]]; then
      OVERALL_COALESCE="$(awk "BEGIN{printf \"%.2f\", ${MISS}/${DBQ}}")"
      detail "overall coalescing: ${OVERALL_COALESCE} cache misses per DB query"
    fi

    EXPECTED_NS="$(awk "BEGIN{printf \"%.0f\", ${RATIO}*${BENCH_HIT_NS} + (1-${RATIO})*${BENCH_MISS_NS}}")"
    detail "expected cost/lookup : ~${EXPECTED_NS} ns"
    detail "  E[cost] = r*${BENCH_HIT_NS}ns + (1-r)*${BENCH_MISS_NS}ns   (from cargo bench)"
    detail "  Note how nonlinear this is: small ratio drops are expensive."

    warn "These are CUMULATIVE counters, not a rate."
    detail "They describe the whole process lifetime and converge over time,"
    detail "hiding transient spikes. Prometheus rate() over a window is the"
    detail "correct production form (Phase 5)."
  fi
fi

# ===========================================================================
# VERDICT
# ===========================================================================
hdr "Verdict"

if [[ "${BENCH_MODE}" -eq 0 ]]; then
  warn "Ran in LIMITED mode: measurement probes were skipped because the"
  detail "rate limiter engages at this request volume. For a full run, start"
  detail "the server in BENCH MODE (see script header)."
fi

if [[ "${FAILURES}" -eq 0 ]]; then
  green "  All probes passed.  (${WARNINGS} warning(s))"
  echo
  exit 0
else
  red "  ${FAILURES} probe(s) FAILED.  (${WARNINGS} warning(s))"
  echo
  exit 1
fi
