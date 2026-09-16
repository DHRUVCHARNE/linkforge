#!/usr/bin/env bash
#
# load_test.sh — LinkForge load / correctness / benchmark harness
#
# Phase 2: Postgres + read-through cache + negative caching + single-flight.
#
# ---------------------------------------------------------------------------
# DESIGN PRINCIPLE: A TEST THAT PASSES FOR THE WRONG REASON IS WORSE THAN ONE
# THAT FAILS.
# ---------------------------------------------------------------------------
# Two earlier revisions of this script reported PASS while proving nothing:
#
#   1. The "nonexistent" probe codes were 12-15 chars, but ShortCode::parse
#      enforces 1..=10. Every request was rejected by DOMAIN VALIDATION before
#      the cache was consulted. Counters stayed flat, and "0 misses" was read
#      as success.
#   2. The single-flight probe's invalidate call failed silently (`|| red`
#      does not abort under `set -e`), so all 200 requests hit a WARM cache.
#      "0 DB queries" passed vacuously.
#   3. The single-flight probe then measured `misses` (the CACHE layer) to
#      infer DB queries — but coalescing happens BELOW the cache. The probe
#      was structurally incapable of observing the thing it tested.
#
# Every probe below therefore follows the same four-step shape:
#
#   1. ESTABLISH a precondition
#   2. VERIFY the precondition actually took effect
#   3. ACT
#   4. ASSERT the outcome *and* that the probe did real work
#      (a no-op must never be mistakable for success)
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

# Probe tuning
NEG_PROBE_REQUESTS="${NEG_PROBE_REQUESTS:-500}"
SF_PROBE_REQUESTS="${SF_PROBE_REQUESTS:-200}"
LOAD_DURATION="${LOAD_DURATION:-10s}"

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
# never explodes — callers assert on deltas, and a permanently-zero counter is
# caught by the anti-vacuity checks.
stat_field() {
  local val
  val="$(curl -s "${STATS_URL}" 2>/dev/null \
        | grep -o "\"$1\":[0-9.]*" | head -n1 | sed 's/.*://')" || true
  printf '%s' "${val:-0}"
}

# Verify the stats payload exposes every field the probes depend on.
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
#
# CRITICAL: must satisfy ShortCode::parse (base62, length 1..=10). A malformed
# code is rejected by the domain layer and NEVER REACHES THE CACHE — which is
# exactly how revision 1 of this script fooled itself.
random_valid_code() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 8 || true
}

# A generated code must 404 (not 400). A 400 means malformed => probe invalid.
assert_well_formed() {
  local code="$1" label="$2" status
  status="$(http_code "${BASE_URL}/${code}")"
  case "${status}" in
    400) fail "${label}: code '${code}' rejected as malformed (400)."
         detail "It never reached the cache. Check ShortCode::parse constraints."
         return 1 ;;
    404) return 0 ;;
    *)   fail "${label}: unexpected status ${status} for a nonexistent code."
         return 1 ;;
  esac
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

# ===========================================================================
# 0. PRE-FLIGHT
# ===========================================================================
hdr "0. Pre-flight"

info "==> Health check: ${BASE_URL}/health"
if ! curl -fsS "${BASE_URL}/health" >/dev/null; then
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

# ===========================================================================
# 1. CORRECTNESS: concurrent writes must never collide
# ===========================================================================
hdr "1. Correctness probe — ${N} concurrent POST /shorten (c=${CONCURRENCY})"

TMP_CODES="$(mktemp)"
trap 'rm -f "${TMP_CODES}"' EXIT

seq "${N}" | xargs -P"${CONCURRENCY}" -I{} \
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/{}"}' \
  | grep -o '"code":"[^"]*"' >> "${TMP_CODES}" || true

TOTAL="$(wc -l < "${TMP_CODES}" | tr -d ' ')"
UNIQUE="$(sort -u "${TMP_CODES}" | wc -l | tr -d ' ')"
DUPES=$(( TOTAL - UNIQUE ))
FAILED_WRITES=$(( N - TOTAL ))
SUCCESS_PCT="$(awk "BEGIN{printf \"%.2f\", 100*${TOTAL}/${N}}")"

detail "generated codes : ${TOTAL} / ${N}  (${SUCCESS_PCT}%)"
detail "unique codes    : ${UNIQUE}"
detail "duplicates      : ${DUPES}"
detail "failed writes   : ${FAILED_WRITES}"

if [[ "${TOTAL}" -lt $(( N / 2 )) ]]; then
  # Anti-vacuity: zero duplicates among ~zero writes proves nothing.
  fail "only ${TOTAL}/${N} shortens succeeded — probe is not measuring what it claims."
elif [[ "${DUPES}" -ne 0 ]]; then
  fail "found ${DUPES} duplicate code(s) under concurrency."
else
  pass "zero duplicate codes across ${TOTAL} concurrent shortens."
fi

# A small, consistent write-failure rate is usually pool backpressure
# (acquire_timeout), not a bug — but it should be acknowledged, not ignored.
if [[ "${FAILED_WRITES}" -gt 0 ]]; then
  FAIL_PCT="$(awk "BEGIN{printf \"%.2f\", 100*${FAILED_WRITES}/${N}}")"
  if [[ "${FAILED_WRITES}" -gt $(( N / 20 )) ]]; then
    fail "${FAILED_WRITES} writes failed (${FAIL_PCT}%) — above the 5% tolerance."
  else
    warn "${FAILED_WRITES} writes failed (${FAIL_PCT}%)."
    detail "Likely pool acquire_timeout at c=${CONCURRENCY} — i.e. backpressure"
    detail "working as designed. Confirm by logging the sqlx error variant"
    detail "rather than assuming."
  fi
fi

# ===========================================================================
# 2. THROUGHPUT: hot read path (100% cache hits)
# ===========================================================================
hdr "2. Throughput probe — hot read path GET /:code"

SEED_CODE="$(create_link 'https://www.rust-lang.org')"

if [[ -z "${SEED_CODE}" ]]; then
  fail "could not seed a link for the throughput probe."
else
  detail "seeded code: ${SEED_CODE}"
  TARGET_URL="${BASE_URL}/${SEED_CODE}"

  # Warm the cache so this measures the hit path, not a cold start.
  curl -s -o /dev/null "${TARGET_URL}"

  if command -v oha >/dev/null 2>&1; then
    info "  oha: ${LOAD_DURATION}, c=${CONCURRENCY}, keepalive on"
    oha -z "${LOAD_DURATION}" -c "${CONCURRENCY}" --no-tui "${TARGET_URL}"
  elif command -v wrk >/dev/null 2>&1; then
    info "  wrk: ${LOAD_DURATION}, c=${CONCURRENCY}"
    wrk -t4 -c"${CONCURRENCY}" -d"${LOAD_DURATION}" "${TARGET_URL}"
  else
    skipped "neither 'oha' nor 'wrk' found. Install: cargo install oha"
  fi

  warn "Interpretation: the load generator shares this host with the server."
  detail "Throughput here is environment-bound, not application-bound."
  detail "Only compare runs taken on identical hardware, and treat ~2%"
  detail "run-to-run variance as the noise floor."
fi

# ===========================================================================
# 3. NEGATIVE CACHING: repeated 404s must stop reaching Postgres
# ===========================================================================
hdr "3. Negative caching probe — ${NEG_PROBE_REQUESTS} repeat 404s"

if [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
else
  MISSING_CODE="$(random_valid_code)"
  detail "probe code: ${MISSING_CODE} (${#MISSING_CODE} chars, base62)"

  if assert_well_formed "${MISSING_CODE}" "negative-cache probe"; then
    # The well-formedness check itself created a negative entry. Clear it so
    # the measurement starts from "no knowledge".
    invalidate "${MISSING_CODE}" || true

    BEFORE_MISS="$(stat_field misses)"
    BEFORE_NEG="$(stat_field negative_hits)"
    BEFORE_DB="$(stat_field db_queries)"

    # 1st request: no knowledge -> DB query -> writes a negative entry.
    STATUS="$(http_code "${BASE_URL}/${MISSING_CODE}")"
    AFTER_FIRST_MISS="$(stat_field misses)"
    AFTER_FIRST_DB="$(stat_field db_queries)"

    FIRST_MISS_DELTA=$(( AFTER_FIRST_MISS - BEFORE_MISS ))
    FIRST_DB_DELTA=$(( AFTER_FIRST_DB - BEFORE_DB ))

    # N more requests for the SAME code: every one must be a negative hit.
    seq "${NEG_PROBE_REQUESTS}" \
      | xargs -P50 -I{} curl -s -o /dev/null "${BASE_URL}/${MISSING_CODE}"

    AFTER_ALL_MISS="$(stat_field misses)"
    AFTER_ALL_NEG="$(stat_field negative_hits)"
    AFTER_ALL_DB="$(stat_field db_queries)"

    REST_MISS_DELTA=$(( AFTER_ALL_MISS - AFTER_FIRST_MISS ))
    REST_DB_DELTA=$(( AFTER_ALL_DB - AFTER_FIRST_DB ))
    NEG_DELTA=$(( AFTER_ALL_NEG - BEFORE_NEG ))
    NEG_THRESHOLD=$(( NEG_PROBE_REQUESTS * 8 / 10 ))

    detail "status of 1st request      : ${STATUS}  (expect 404)"
    detail "cache misses, 1st request  : ${FIRST_MISS_DELTA}  (expect 1)"
    detail "DB queries,   1st request  : ${FIRST_DB_DELTA}  (expect 1)"
    detail "DB queries,   next ${NEG_PROBE_REQUESTS}     : ${REST_DB_DELTA}  (expect 0)"
    detail "negative hits recorded     : ${NEG_DELTA}  (expect ~${NEG_PROBE_REQUESTS})"

    if [[ "${STATUS}" != "404" ]]; then
      fail "expected 404 for a nonexistent code, got ${STATUS}."
    elif [[ "${FIRST_MISS_DELTA}" -lt 1 ]]; then
      # Anti-vacuity: the request never reached the cache at all.
      fail "first request caused no cache miss — requests are not reaching the cache."
      detail "Domain validation is likely rejecting the code before lookup."
    elif [[ "${NEG_DELTA}" -lt "${NEG_THRESHOLD}" ]]; then
      fail "only ${NEG_DELTA} negative hits for ${NEG_PROBE_REQUESTS} requests."
      detail "Negative caching is not engaging as expected."
    elif [[ "${REST_DB_DELTA}" -ne 0 ]]; then
      fail "${REST_DB_DELTA} repeat 404s still reached the database."
      detail "Is negative_ttl_secs shorter than this probe's runtime?"
    else
      pass "${NEG_PROBE_REQUESTS} repeat 404s absorbed; exactly ${FIRST_DB_DELTA} DB query."
    fi

    # Latency comparison — indicative only.
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
      # That verification request re-warmed the cache. Go cold again.
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

      # THE KEY DISTINCTION, and the bug in revision 2 of this script:
      # every request checks the cache BEFORE reaching the inflight registry,
      # so MISS_DELTA counts would-be DB queries. DB_DELTA counts actual ones.
      # Single-flight exists precisely to make these two numbers diverge.
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
    fi
  fi
fi

# ===========================================================================
# 5. CACHE STATISTICS SUMMARY
# ===========================================================================
hdr "5. Cache statistics (cumulative over this run)"

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

    # Anti-vacuity at the run level: a run exercising probes 3 and 4 must have
    # recorded negative hits AND misses. All-positive means nothing happened.
    if [[ "${NEG}" -eq 0 && "${MISS}" -eq 0 ]]; then
      fail "100% positive hits, zero misses and zero negative hits."
      detail "The cache-aware probes did not exercise their code paths."
    fi

    # Coalescing effectiveness across the whole run.
    if [[ "${MISS}" -gt 0 && "${DBQ}" -gt 0 ]]; then
      OVERALL_COALESCE="$(awk "BEGIN{printf \"%.2f\", ${MISS}/${DBQ}}")"
      detail "overall coalescing: ${OVERALL_COALESCE} cache misses per DB query"
    fi

    # Expected per-lookup cost:  E[cost] = r*hit + (1-r)*miss
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

if [[ "${FAILURES}" -eq 0 ]]; then
  green "  All probes passed.  (${WARNINGS} warning(s))"
  echo
  exit 0
else
  red "  ${FAILURES} probe(s) FAILED.  (${WARNINGS} warning(s))"
  echo
  exit 1
fi
