#!/usr/bin/env bash
#
# behaviour_test.sh — LinkForge behavioural & production-readiness probes
#
# ===========================================================================
# WHY THIS IS A SEPARATE SCRIPT
# ===========================================================================
# `load_test.sh` measures THROUGHPUT and must stay comparable across phases.
# Changing what it measures destroys the Phase 1 / Phase 2 baselines.
#
# This script asserts BEHAVIOUR: error contracts, rate-limit semantics,
# concurrency safety, resilience, and production hygiene. It produces no
# headline req/s number, so it can evolve freely.
#
# ===========================================================================
# THE BUG THIS REVISION FIXES
# ===========================================================================
# The previous version's pre-flight fired a 200-request burst to detect
# whether the limiter was active. With a small bucket that burst DRAINED the
# bucket, so the very next probe ("valid url") got a 429 and failed.
#
#     The diagnostic destroyed the thing it was diagnosing.
#
# That is the fourth instance on this project of a probe invalidating its own
# preconditions. The fix is structural, not incremental:
#
#   1. Detect bucket size WITHOUT draining it (binary search on a tiny budget)
#   2. Classify the server into a MODE from that detection
#   3. Run only the probes that mode can support; SKIP the rest explicitly
#   4. Order probes so state-destroying ones run LAST
#   5. Make every destructive probe declare its cost up front
#
# ===========================================================================
# MODES
# ===========================================================================
#   BENCH     bucket effectively unlimited  -> contracts, load, resilience
#   LIMITED   bucket small and drainable    -> rate-limit semantics only
#   UNKNOWN   cannot classify               -> low-volume contracts only
#
# Start the server accordingly:
#
#   BENCH:    RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 just run
#   LIMITED:  RATE_LIMIT_REQUESTS=50        RATE_LIMIT_WINDOW_SECS=60 just run
#
# ===========================================================================
# PROBE INVENTORY
# ===========================================================================
#   A  Write path error contract        400/415/422 vs 500        [any mode]
#   B  Read path error contract         malformed codes, traversal[any mode]
#   C  Response hygiene                 headers, leaks, caching   [any mode]
#   D  Idempotency & determinism        same input -> same shape  [any mode]
#   E  Concurrency safety               parallel writes, no dupes [BENCH]
#   F  Cache correctness under churn    invalidate/re-read races  [BENCH]
#   G  Realistic key distribution       many keys, shard spread   [BENCH]
#   H  Resilience                       slow clients, big bodies  [BENCH]
#   I  Rate limit semantics             429, retry-after, refill  [LIMITED]
#   J  Rate limit isolation             per-IP vs global          [LIMITED]
#   K  Observability                    request-id, correlation   [any mode]
#
# Usage:
#   ./scripts/behaviour_test.sh [BASE_URL]
#
# Env:
#   JSON_OUT=path        machine-readable summary
#   ONLY=A,B,I           run only these probes
#   SKIP=G,H             skip these probes
#   SPREAD_LINKS=N       keys for probe G (default 200)
#   STRICT=1             treat warnings as failures
#
# Exit: 0 all passed, 1 any failed.
#
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
SPREAD_LINKS="${SPREAD_LINKS:-200}"
SPREAD_DURATION="${SPREAD_DURATION:-10s}"
SPREAD_CONCURRENCY="${SPREAD_CONCURRENCY:-50}"
STRICT="${STRICT:-}"

STATS_URL="${BASE_URL}/debug/cache"
FAILURES=0
WARNINGS=0
MODE="UNKNOWN"
BUCKET_ESTIMATE=0

declare -A RESULTS

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_YELLOW=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

green() { printf '%s%s%s\n' "${C_GREEN}"  "$*" "${C_RESET}"; }
red()   { printf '%s%s%s\n' "${C_RED}"    "$*" "${C_RESET}"; }
info()  { printf '%s%s%s\n' "${C_CYAN}"   "$*" "${C_RESET}"; }
hdr()   { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

pass()    { green "  PASS  $*"; }
fail()    { red   "  FAIL  $*"; FAILURES=$(( FAILURES + 1 )); }
warn()    { printf '%s  WARN  %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"
            WARNINGS=$(( WARNINGS + 1 ))
            [[ -n "${STRICT}" ]] && FAILURES=$(( FAILURES + 1 )); return 0; }
skipped() { printf '%s  SKIP  %s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
detail()  { printf '        %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Probe selection
# ---------------------------------------------------------------------------
should_run() {
  local id="$1"
  if [[ -n "${ONLY:-}" ]]; then
    [[ ",${ONLY}," == *",${id},"* ]] || return 1
  fi
  if [[ -n "${SKIP:-}" ]]; then
    [[ ",${SKIP}," == *",${id},"* ]] && return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
http_time() { curl -s -o /dev/null -w '%{time_total}' "$@"; }
http_headers() { curl -s -D - -o /dev/null "$@"; }

extract_code() { grep -o '"code":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"//'; }

create_link() {
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d "{\"url\":\"$1\"}" | extract_code
}

stat_field() {
  local val
  val="$(curl -s "${STATS_URL}" 2>/dev/null \
        | grep -o "\"$1\":[0-9.]*" | head -n1 | sed 's/.*://')" || true
  printf '%s' "${val:-0}"
}

has_stats() { curl -fsS "${STATS_URL}" >/dev/null 2>&1; }

invalidate() {
  curl -fsS -X POST "${BASE_URL}/debug/cache/invalidate/$1" >/dev/null 2>&1
}

random_valid_code() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 8 || true
}

# Assert a status is in an accepted set. Several contracts have more than one
# defensible answer (415 vs 422 for a missing content-type), so we accept a
# set and report which was chosen rather than dictating one.
assert_status_in() {
  local actual="$1" label="$2"; shift 2
  local accepted=("$@") a
  for a in "${accepted[@]}"; do
    [[ "${actual}" == "${a}" ]] && { pass "${label}: ${actual}"; return 0; }
  done
  fail "${label}: got ${actual}, expected one of: ${accepted[*]}"
  return 1
}

# ===========================================================================
# 0. PRE-FLIGHT — NON-DESTRUCTIVE MODE DETECTION
#
# The old version burned 200 requests here and broke everything downstream.
# This one spends a strictly bounded budget and stops the instant it learns
# what it needs.
#
# Strategy: probe in small escalating batches, aborting on the FIRST 429.
# Worst case for a BENCH server is 1+2+4+...+64 = 127 requests, which is
# nothing against an unlimited bucket. For a LIMITED server we stop within a
# few requests of the bucket size, leaving most of it intact.
# ===========================================================================
hdr "0. Pre-flight"

PING_STATUS="$(http_code "${BASE_URL}/health")"
case "${PING_STATUS}" in
  200) green "  Server is up." ;;
  429) red "  Server is UP but ALREADY throttling before any probe ran."
       red "  A previous run drained the bucket. Wait for refill, or restart."
       exit 1 ;;
  000) red "  Server is not responding at ${BASE_URL}. Start it (just run)."
       exit 1 ;;
  *)   red "  /health returned ${PING_STATUS} — expected 200."
       exit 1 ;;
esac

STATS_AVAILABLE=0
has_stats && STATS_AVAILABLE=1
if [[ "${STATS_AVAILABLE}" -eq 1 ]]; then
  green "  /debug/cache available."
else
  warn "/debug/cache unavailable — cache assertions will be SKIPPED."
  detail "Set APP_ENV=development so the debug routes are registered."
fi

# --- Bounded, escalating bucket probe --------------------------------------
detect_bucket() {
  local spent=0 batch=1 hit429=0 codes
  while [[ "${batch}" -le 64 ]]; do
    codes="$(
      seq "${batch}" | xargs -P"${batch}" -I{} \
        curl -s -o /dev/null -w '%{http_code}\n' "${BASE_URL}/health" || true
    )"
    spent=$(( spent + batch ))
    if grep -q '^429$' <<<"${codes}"; then
      hit429=1
      break
    fi
    batch=$(( batch * 2 ))
  done
  BUCKET_ESTIMATE="${spent}"
  return $(( 1 - hit429 ))
}

info "  Detecting rate limit configuration (bounded probe)..."
if detect_bucket; then
  MODE="LIMITED"
  detail "limiter engaged after ~${BUCKET_ESTIMATE} requests"
  detail "-> MODE=LIMITED: rate-limit probes (I, J) will run;"
  detail "   load-generating probes (E, F, G, H) will be SKIPPED."
else
  MODE="BENCH"
  detail "no 429 within ${BUCKET_ESTIMATE} requests"
  detail "-> MODE=BENCH: contract + load probes run;"
  detail "   rate-limit probes (I, J) will be SKIPPED (bucket untrippable)."
fi
RESULTS[mode]="${MODE}"
RESULTS[bucket_estimate]="${BUCKET_ESTIMATE}"

# In LIMITED mode the detection just consumed most of the bucket. Wait for a
# refill before running anything that needs successful requests. This is the
# explicit acknowledgement the old version lacked.
if [[ "${MODE}" == "LIMITED" ]]; then
  info "  Waiting 5s for bucket refill before contract probes..."
  sleep 5
  if [[ "$(http_code "${BASE_URL}/health")" == "429" ]]; then
    warn "bucket has not refilled; contract probes may report spurious 429s."
    detail "Increase RATE_LIMIT_REQUESTS or shorten RATE_LIMIT_WINDOW_SECS."
  fi
fi

command -v oha >/dev/null 2>&1 || warn "oha not installed (cargo install oha)."
command -v jq  >/dev/null 2>&1 || detail "jq not installed — JSON body checks are string-based."

# ===========================================================================
# A. WRITE PATH ERROR CONTRACT
#
# load_test.sh only sends VALID payloads, so it cannot catch a 500 where a
# 400 belongs. AppError::IntoResponse is the single place business errors
# become status codes; this is its black-box contract test.
# ===========================================================================
if should_run A; then
hdr "A. Write path error contract — POST /shorten"

post_raw() {
  if [[ -n "${2:-}" ]]; then
    http_code -X POST "${BASE_URL}/shorten" -H "content-type: $2" -d "$1"
  else
    http_code -X POST "${BASE_URL}/shorten" -d "$1"
  fi
}

check_write() {
  local label="$1" body="$2" ct="$3"; shift 3
  local status; status="$(post_raw "${body}" "${ct}")"
  # A 429 means the limiter interfered — report it as inconclusive, never as
  # a contract failure.
  if [[ "${status}" == "429" ]]; then
    warn "${label}: throttled (429) — contract not verified."
    return 0
  fi
  assert_status_in "${status}" "${label}" "$@"
  printf '%s' "${status}"
}

RESULTS[write_valid]="$(check_write 'valid url' \
  '{"url":"https://valid.example/"}' 'application/json' 200 201)"
RESULTS[write_bad_scheme]="$(check_write 'rejected scheme (ftp)' \
  '{"url":"ftp://not-allowed.example"}' 'application/json' 400)"
RESULTS[write_garbage]="$(check_write 'garbage url string' \
  '{"url":"definitely not a url"}' 'application/json' 400)"
RESULTS[write_empty]="$(check_write 'empty url' \
  '{"url":""}' 'application/json' 400)"
RESULTS[write_whitespace]="$(check_write 'whitespace-only url' \
  '{"url":"   "}' 'application/json' 400)"
RESULTS[write_bad_json]="$(check_write 'malformed JSON body' \
  'this is not json' 'application/json' 400 422)"
RESULTS[write_wrong_field]="$(check_write 'wrong field name' \
  '{"link":"https://example.com"}' 'application/json' 400 422)"
RESULTS[write_wrong_type]="$(check_write 'url is a number, not a string' \
  '{"url":12345}' 'application/json' 400 422)"
RESULTS[write_null]="$(check_write 'url is null' \
  '{"url":null}' 'application/json' 400 422)"
RESULTS[write_array]="$(check_write 'body is an array' \
  '[{"url":"https://example.com"}]' 'application/json' 400 422)"
RESULTS[write_no_content_type]="$(check_write 'missing content-type' \
  '{"url":"https://example.com"}' '' 400 415 422)"
RESULTS[write_wrong_content_type]="$(check_write 'text/plain content-type' \
  '{"url":"https://example.com"}' 'text/plain' 400 415 422)"

S_NOBODY="$(http_code -X POST "${BASE_URL}/shorten")"
[[ "${S_NOBODY}" == "429" ]] \
  && warn "no body at all: throttled" \
  || assert_status_in "${S_NOBODY}" "no body at all" 400 411 415 422
RESULTS[write_no_body]="${S_NOBODY}"

# --- SSRF-shaped inputs ----------------------------------------------------
#
# A URL shortener that will happily shorten http://169.254.169.254/ becomes a
# a redirect-based SSRF primitive. Whether to block these is a PRODUCT
# decision; this probe only records the behaviour so it is deliberate.
detail ""
detail "SSRF-shaped targets (informational — policy decision, not a bug):"
for target in \
  'http://169.254.169.254/latest/meta-data/' \
  'http://localhost:22/' \
  'http://127.0.0.1:5432/' \
  'http://[::1]:3000/'
do
  s="$(post_raw "{\"url\":\"${target}\"}" 'application/json')"
  detail "  ${target} -> ${s}"
done
detail "If these return 200, the service will redirect users to internal"
detail "addresses. Consider an allowlist/denylist before public exposure."

# --- Oversized input -------------------------------------------------------
LONG_URL="https://example.com/$(head -c 4000 /dev/zero | tr '\0' 'a')"
S_LONG="$(post_raw "{\"url\":\"${LONG_URL}\"}" 'application/json')"
detail "4KB url -> ${S_LONG}"
[[ "${S_LONG}" == "500" ]] \
  && fail "4KB url produced a 500 — unbounded input is not handled." \
  || pass "4KB url handled deliberately (${S_LONG})."
RESULTS[write_long_url]="${S_LONG}"

HUGE_URL="https://example.com/$(head -c 100000 /dev/zero | tr '\0' 'a')"
S_HUGE="$(post_raw "{\"url\":\"${HUGE_URL}\"}" 'application/json' || echo 000)"
detail "100KB url -> ${S_HUGE}"
if [[ "${S_HUGE}" == "500" ]]; then
  fail "100KB url produced a 500."
  detail "Add a request body limit (tower_http::limit::RequestBodyLimitLayer)."
elif [[ "${S_HUGE}" == "200" ]]; then
  warn "100KB url ACCEPTED — no body size limit is enforced."
  detail "An attacker can store arbitrarily large rows. Add a limit layer."
else
  pass "100KB url rejected deliberately (${S_HUGE})."
fi
RESULTS[write_huge_url]="${S_HUGE}"

# --- THE headline assertion ------------------------------------------------
FIVE_HUNDREDS=0
for k in write_bad_scheme write_garbage write_empty write_whitespace \
         write_bad_json write_wrong_field write_wrong_type write_null \
         write_array write_no_content_type write_wrong_content_type \
         write_no_body; do
  [[ "${RESULTS[$k]:-}" == "500" ]] && FIVE_HUNDREDS=$(( FIVE_HUNDREDS + 1 ))
done
[[ "${FIVE_HUNDREDS}" -gt 0 ]] \
  && { fail "${FIVE_HUNDREDS} malformed input(s) produced a 500."
       detail "Client errors must never surface as server errors."; } \
  || pass "no malformed input produced a 500."
RESULTS[write_500_count]="${FIVE_HUNDREDS}"
fi

# ===========================================================================
# B. READ PATH ERROR CONTRACT
#
# ShortCode::parse enforces base62 and length 1..=10. Codes violating that
# are rejected by the DOMAIN before the cache is consulted — the exact
# behaviour that silently invalidated three earlier probe generations.
# ===========================================================================
if should_run B; then
hdr "B. Read path error contract — GET /:code"

check_read() {
  local label="$1" path="$2"; shift 2
  local status; status="$(http_code "${BASE_URL}/${path}")"
  [[ "${status}" == "429" ]] && { warn "${label}: throttled"; return 0; }
  assert_status_in "${status}" "${label}" "$@"
  printf '%s' "${status}"
}

RESULTS[read_unknown]="$(check_read 'well-formed unknown code' 'aZ09xY' 404)"
RESULTS[read_bad_charset]="$(check_read 'invalid charset (underscore)' 'has_under' 404 400)"
RESULTS[read_too_long]="$(check_read 'over-length code' 'waytoolongforacode' 404 400)"
RESULTS[read_single_char]="$(check_read 'single char (boundary, valid)' 'a' 404)"

# Inputs that must be boring 404s, never 500s and never anything exciting.
detail ""
detail "Hostile-shaped paths (must never 500):"
HOSTILE_500=0
for probe in \
  '..%2f..%2fetc%2fpasswd' \
  '%E2%98%83%E2%98%83' \
  '%00nullbyte' \
  'a%27%20OR%201%3D1--' \
  '%3Cscript%3Ealert(1)%3C%2Fscript%3E' \
  '....//....//etc/passwd'
do
  s="$(http_code "${BASE_URL}/${probe}")"
  detail "  ${probe} -> ${s}"
  [[ "${s}" == "500" ]] && HOSTILE_500=$(( HOSTILE_500 + 1 ))
done
[[ "${HOSTILE_500}" -gt 0 ]] \
  && fail "${HOSTILE_500} hostile path(s) produced a 500." \
  || pass "all hostile-shaped paths handled safely."
RESULTS[read_hostile_500s]="${HOSTILE_500}"

S_METHOD="$(http_code -X DELETE "${BASE_URL}/health")"
assert_status_in "${S_METHOD}" "unsupported method on /health" 405
RESULTS[read_wrong_method]="${S_METHOD}"

S_UNKNOWN_ROUTE="$(http_code "${BASE_URL}/api/v1/does/not/exist")"
detail "deep unknown path -> ${S_UNKNOWN_ROUTE}"
assert_status_in "${S_UNKNOWN_ROUTE}" "unknown nested route" 404
RESULTS[read_unknown_route]="${S_UNKNOWN_ROUTE}"
fi

# ===========================================================================
# C. RESPONSE HYGIENE
#
# Production concerns that no functional test covers: does an error body leak
# internals? Is the redirect cacheable in a way that breaks analytics? Does
# the server advertise its stack?
# ===========================================================================
if should_run C; then
hdr "C. Response hygiene"

# --- Error bodies must not leak internals ---------------------------------
ERR_BODY="$(curl -s "${BASE_URL}/$(random_valid_code)")"
detail "404 body: ${ERR_BODY:0:120}"
LEAKED=0
for pattern in 'sqlx' 'postgres' 'panicked' 'src/' '.rs:' 'backtrace' \
               'DATABASE_URL' 'password'; do
  grep -qi "${pattern}" <<<"${ERR_BODY}" && {
    fail "error body leaks '${pattern}'"; LEAKED=$(( LEAKED + 1 )); }
done
[[ "${LEAKED}" -eq 0 ]] && pass "error body leaks no internals."
RESULTS[error_leaks]="${LEAKED}"

# --- Redirect semantics ----------------------------------------------------
HYG_CODE="$(create_link 'https://hygiene.example/')"
if [[ -n "${HYG_CODE}" ]]; then
  RH="$(http_headers "${BASE_URL}/${HYG_CODE}")"
  STATUS_LINE="$(head -n1 <<<"${RH}" | tr -d '\r')"
  detail "redirect status: ${STATUS_LINE}"

  if grep -qi '^location:' <<<"${RH}"; then
    pass "redirect carries a Location header."
  else
    fail "redirect has NO Location header — clients cannot follow it."
  fi

  # 301/308 are cached by browsers indefinitely. That is a deliberate
  # tradeoff: it removes load, but makes click analytics (Phase 4) blind to
  # repeat visits and makes a wrong mapping effectively permanent.
  if grep -qiE '^HTTP/[0-9.]+ (301|308)' <<<"${STATUS_LINE}"; then
    warn "permanent redirect (301/308) — browsers will cache indefinitely."
    detail "Repeat visits will NOT reach the server, so Phase 4 click"
    detail "analytics will undercount. Confirm this is intended."
  else
    pass "temporary redirect — repeat visits still reach the server."
  fi

  if grep -qi '^cache-control:' <<<"${RH}"; then
    detail "cache-control: $(grep -i '^cache-control:' <<<"${RH}" | tr -d '\r')"
  else
    detail "no cache-control header (relying on status-code defaults)"
  fi
  RESULTS[redirect_status]="$(grep -oE '[0-9]{3}' <<<"${STATUS_LINE}" | head -n1)"
fi

# --- Server banner ---------------------------------------------------------
HEALTH_H="$(http_headers "${BASE_URL}/health")"
if grep -qi '^server:' <<<"${HEALTH_H}"; then
  SRV="$(grep -i '^server:' <<<"${HEALTH_H}" | tr -d '\r')"
  detail "${SRV}"
  grep -qiE 'axum|hyper|rust|[0-9]+\.[0-9]+' <<<"${SRV}" \
    && warn "Server header advertises the stack/version." \
    || pass "Server header is generic."
else
  pass "no Server header (nothing advertised)."
fi

# --- Security headers (informational) --------------------------------------
detail ""
detail "Security headers (informational — add via a tower layer if needed):"
for h in x-content-type-options x-frame-options strict-transport-security \
         content-security-policy referrer-policy; do
  grep -qi "^${h}:" <<<"${HEALTH_H}" \
    && detail "  ${h}: present" \
    || detail "  ${h}: absent"
done

# --- Debug routes must not exist in production -----------------------------
if [[ "${STATS_AVAILABLE}" -eq 1 ]]; then
  warn "/debug/cache is REACHABLE."
  detail "Correct for development. Verify APP_ENV=production removes it —"
  detail "it exposes cache internals and an invalidation endpoint."
fi
fi

# ===========================================================================
# D. IDEMPOTENCY & DETERMINISM
#
# Shortening the same URL twice: does it return the same code or a new one?
# Either is defensible, but the behaviour must be DELIBERATE and stable.
# ===========================================================================
if should_run D; then
hdr "D. Idempotency & determinism"

DUP_URL="https://idempotency.example/$(date +%s)"
CODE_1="$(create_link "${DUP_URL}")"
CODE_2="$(create_link "${DUP_URL}")"

detail "first  shorten -> ${CODE_1:-<none>}"
detail "second shorten -> ${CODE_2:-<none>}"

if [[ -z "${CODE_1}" || -z "${CODE_2}" ]]; then
  warn "could not create links (throttled?) — idempotency not verified."
  RESULTS[idempotency]="unverified"
elif [[ "${CODE_1}" == "${CODE_2}" ]]; then
  pass "idempotent: identical URLs share one code."
  detail "Requires a lookup-by-url index; confirm it exists and is indexed."
  RESULTS[idempotency]="deduplicated"
else
  pass "non-idempotent by design: each request mints a new code."
  detail "Storage grows with request volume, not distinct URLs. Phase 9's"
  detail "idempotency keys would change this — record the decision."
  RESULTS[idempotency]="always_new"
fi

# Both codes must resolve to the same target regardless.
if [[ -n "${CODE_1}" && -n "${CODE_2}" ]]; then
  L1="$(http_headers "${BASE_URL}/${CODE_1}" | grep -i '^location:' | tr -d '\r')"
  L2="$(http_headers "${BASE_URL}/${CODE_2}" | grep -i '^location:' | tr -d '\r')"
  [[ "${L1}" == "${L2}" ]] \
    && pass "both codes resolve to the same target." \
    || fail "codes for the same URL resolve differently: '${L1}' vs '${L2}'"
fi
fi

# ===========================================================================
# E. CONCURRENCY SAFETY  [BENCH]
#
# The AtomicU64 guarantees uniqueness WITHIN one process. This probe hammers
# the write path in parallel and asserts the guarantee holds end to end,
# including through the database's UNIQUE constraint.
# ===========================================================================
if should_run E; then
hdr "E. Concurrency safety — parallel writes"

if [[ "${MODE}" != "BENCH" ]]; then
  skipped "needs BENCH mode (this generates 500 writes)."
else
  CONC_N=500
  TMP_CONC="$(mktemp)"
  trap 'rm -f "${TMP_CONC}"' EXIT

  detail "firing ${CONC_N} concurrent POST /shorten"
  seq "${CONC_N}" | xargs -P100 -I{} \
    curl -s -X POST "${BASE_URL}/shorten" \
      -H 'content-type: application/json' \
      -d '{"url":"https://concurrency.example/{}"}' \
    >> "${TMP_CONC}" 2>/dev/null || true

  CONC_CODES="$(grep -o '"code":"[^"]*"' "${TMP_CONC}" | wc -l | tr -d ' ')"
  CONC_UNIQUE="$(grep -o '"code":"[^"]*"' "${TMP_CONC}" | sort -u | wc -l | tr -d ' ')"
  CONC_DUPES=$(( CONC_CODES - CONC_UNIQUE ))

  detail "returned codes : ${CONC_CODES}/${CONC_N}"
  detail "unique codes   : ${CONC_UNIQUE}"
  detail "duplicates     : ${CONC_DUPES}"

  if [[ "${CONC_CODES}" -lt $(( CONC_N / 2 )) ]]; then
    fail "only ${CONC_CODES}/${CONC_N} succeeded — probe proves nothing."
    detail "Zero duplicates among ~zero writes is not evidence."
  elif [[ "${CONC_DUPES}" -ne 0 ]]; then
    fail "${CONC_DUPES} duplicate code(s) under concurrency."
  else
    pass "zero duplicates across ${CONC_CODES} concurrent writes."
  fi
  RESULTS[concurrent_writes]="${CONC_CODES}"
  RESULTS[concurrent_dupes]="${CONC_DUPES}"

  # Every returned code must actually resolve — a code returned but not
  # persisted is worse than a failed write.
  SAMPLE_MISSING=0
  while read -r c; do
    s="$(http_code "${BASE_URL}/${c}")"
    [[ "${s}" =~ ^3 ]] || SAMPLE_MISSING=$(( SAMPLE_MISSING + 1 ))
  done < <(grep -o '"code":"[^"]*"' "${TMP_CONC}" \
           | sed 's/.*:"//; s/"//' | shuf | head -20)

  [[ "${SAMPLE_MISSING}" -gt 0 ]] \
    && { fail "${SAMPLE_MISSING}/20 sampled codes do not resolve."
         detail "A code was returned to the client but not persisted."; } \
    || pass "all 20 sampled codes resolve (write is durable before response)."
  RESULTS[unresolvable_sample]="${SAMPLE_MISSING}"
fi
fi

# ===========================================================================
# F. CACHE CORRECTNESS UNDER CHURN  [BENCH]
#
# Cache tests usually run in quiet conditions. This one interleaves reads
# with invalidations to surface races between eviction and backfill.
# ===========================================================================
if should_run F; then
hdr "F. Cache correctness under churn"

if [[ "${MODE}" != "BENCH" ]]; then
  skipped "needs BENCH mode."
elif [[ "${STATS_AVAILABLE}" -eq 0 ]]; then
  skipped "no /debug/cache."
else
  CHURN_CODE="$(create_link 'https://churn.example/target')"
  if [[ -z "${CHURN_CODE}" ]]; then
    fail "could not create a link for the churn probe."
  else
    EXPECTED_LOC='https://churn.example/target'
    detail "code: ${CHURN_CODE}, hammering reads while invalidating"

    # Background: invalidate repeatedly while foreground reads.
    ( for _ in $(seq 40); do invalidate "${CHURN_CODE}" || true; sleep 0.05; done ) &
    CHURN_PID=$!

    WRONG=0; ERRORS=0; TOTAL=0
    for _ in $(seq 200); do
      loc="$(http_headers "${BASE_URL}/${CHURN_CODE}" \
            | grep -i '^location:' | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
      TOTAL=$(( TOTAL + 1 ))
      if [[ -z "${loc}" ]]; then
        ERRORS=$(( ERRORS + 1 ))
      elif [[ "${loc}" != "${EXPECTED_LOC}" ]]; then
        WRONG=$(( WRONG + 1 ))
      fi
    done
    wait "${CHURN_PID}" 2>/dev/null || true

    detail "reads: ${TOTAL}, wrong target: ${WRONG}, no location: ${ERRORS}"

    if [[ "${WRONG}" -gt 0 ]]; then
      fail "${WRONG} read(s) returned the WRONG target during invalidation."
      detail "A cache race is serving stale or crossed entries."
    elif [[ "${ERRORS}" -gt 0 ]]; then
      fail "${ERRORS} read(s) failed during invalidation."
      detail "Invalidation must never make an existing link unresolvable —"
      detail "a miss should fall through to the database, not 404."
    else
      pass "all ${TOTAL} reads correct despite concurrent invalidation."
    fi
    RESULTS[churn_wrong]="${WRONG}"
    RESULTS[churn_errors]="${ERRORS}"
  fi
fi
fi

# ===========================================================================
# G. REALISTIC KEY DISTRIBUTION  [BENCH]
#
# Every other probe hammers ONE code, measuring a permanently-hot cache line
# and a single DashMap shard. Real traffic spreads across many keys.
#
# NOTE: a DIFFERENT measurement from load_test.sh's single-key throughput.
# Compare each to its own history, never to the other.
# ===========================================================================
if should_run G; then
hdr "G. Realistic key distribution — ${SPREAD_LINKS} distinct codes"

if [[ "${MODE}" != "BENCH" ]]; then
  skipped "needs BENCH mode (sustained load)."
elif ! command -v oha >/dev/null 2>&1; then
  skipped "oha not installed."
else
  TMP_URLS="$(mktemp)"
  trap 'rm -f "${TMP_URLS}"' EXIT

  detail "seeding ${SPREAD_LINKS} links..."
  SEEDED=0
  for i in $(seq "${SPREAD_LINKS}"); do
    c="$(create_link "https://example.com/spread/${i}")"
    [[ -n "${c}" ]] && { printf '%s/%s\n' "${BASE_URL}" "${c}" >> "${TMP_URLS}"
                         SEEDED=$(( SEEDED + 1 )); }
  done
  detail "seeded ${SEEDED}/${SPREAD_LINKS}"

  if [[ "${SEEDED}" -lt $(( SPREAD_LINKS / 2 )) ]]; then
    fail "only seeded ${SEEDED} links — cannot spread load meaningfully."
  else
    while read -r u; do curl -s -o /dev/null "${u}"; done < "${TMP_URLS}"
    BEFORE_DB="$(stat_field db_queries)"

    info "  oha: ${SPREAD_DURATION}, c=${SPREAD_CONCURRENCY}, ${SEEDED} keys"
    OHA_OUT="$(oha -z "${SPREAD_DURATION}" -c "${SPREAD_CONCURRENCY}" --no-tui \
                 --urls-from-file "${TMP_URLS}" 2>/dev/null || true)"
    if [[ -n "${OHA_OUT}" ]]; then
      printf '%s\n' "${OHA_OUT}"
      SPREAD_RPS="$(grep -o 'Requests/sec:[[:space:]]*[0-9.]*' <<<"${OHA_OUT}" \
                    | head -n1 | grep -o '[0-9.]*' || true)"
      RESULTS[spread_rps]="${SPREAD_RPS:-0}"
    else
      warn "oha --urls-from-file unsupported; using a sampled loop."
      detail "Numbers will be lower (process-per-request). Not comparable."
      shuf "${TMP_URLS}" | head -2000 \
        | xargs -P"${SPREAD_CONCURRENCY}" -I{} curl -s -o /dev/null {}
    fi

    SPREAD_DB_DELTA=$(( $(stat_field db_queries) - BEFORE_DB ))
    detail "DB queries during spread load: ${SPREAD_DB_DELTA}"
    [[ "${SPREAD_DB_DELTA}" -gt "${SEEDED}" ]] \
      && { warn "more DB queries than distinct keys — cache is not holding."
           detail "Is the cache evicting, or negative_ttl expiring mid-run?"; } \
      || pass "spread load served from cache (${SPREAD_DB_DELTA} DB queries)."
    RESULTS[spread_db_queries]="${SPREAD_DB_DELTA}"
    RESULTS[spread_keys]="${SEEDED}"

    detail "INTERPRETATION: exercises many DashMap shards, unlike the"
    detail "single-key probe. Compare against load_test.sh at the SAME"
    detail "concurrency — differing c makes the two incomparable."
  fi
fi
fi

# ===========================================================================
# H. RESILIENCE  [BENCH]
#
# Production servers meet clients that behave badly: they connect and stall,
# disconnect mid-request, or send headers forever. None of it should degrade
# service for well-behaved clients.
# ===========================================================================
if should_run H; then
hdr "H. Resilience — hostile client behaviour"

if [[ "${MODE}" != "BENCH" ]]; then
  skipped "needs BENCH mode."
else
  # --- Slow-loris-shaped: open connections that send nothing --------------
  detail "opening 20 connections that stall mid-request..."
  for _ in $(seq 20); do
    ( curl -s --max-time 3 --limit-rate 1 \
        -X POST "${BASE_URL}/shorten" \
        -H 'content-type: application/json' \
        -d '{"url":"https://slow.example/"}' >/dev/null 2>&1 || true ) &
  done

  sleep 1
  HEALTH_DURING="$(http_code "${BASE_URL}/health")"
  HEALTH_TIME="$(http_time "${BASE_URL}/health")"
  detail "/health during slow clients -> ${HEALTH_DURING} in ${HEALTH_TIME}s"

  wait 2>/dev/null || true

  if [[ "${HEALTH_DURING}" != "200" ]]; then
    fail "server degraded while slow clients were connected (${HEALTH_DURING})."
    detail "Add a request timeout layer (Phase 5) so stalled connections"
    detail "cannot occupy resources indefinitely."
  else
    pass "server stayed responsive under slow clients."
  fi
  RESULTS[slowloris_health]="${HEALTH_DURING}"

  # --- Abrupt disconnects --------------------------------------------------
  detail "issuing 50 requests aborted after 1ms..."
  for _ in $(seq 50); do
    curl -s --max-time 0.001 "${BASE_URL}/health" >/dev/null 2>&1 || true
  done
  sleep 0.5
  AFTER_ABORT="$(http_code "${BASE_URL}/health")"
  [[ "${AFTER_ABORT}" == "200" ]] \
    && pass "server healthy after 50 aborted connections." \
    || fail "server unhealthy after aborted connections (${AFTER_ABORT})."
  RESULTS[after_abort]="${AFTER_ABORT}"

  # --- Header flood --------------------------------------------------------
  HDR_ARGS=(); for i in $(seq 100); do HDR_ARGS+=(-H "x-junk-${i}: value${i}"); done
  S_HDRS="$(http_code "${HDR_ARGS[@]}" "${BASE_URL}/health" || echo 000)"
  detail "100 extra headers -> ${S_HDRS}"
  [[ "${S_HDRS}" == "500" ]] \
    && fail "header flood produced a 500." \
    || pass "header flood handled (${S_HDRS})."
  RESULTS[header_flood]="${S_HDRS}"

  # --- Recovery ------------------------------------------------------------
  sleep 1
  RECOVER="$(http_code "${BASE_URL}/health")"
  [[ "${RECOVER}" == "200" ]] \
    && pass "server fully recovered after the resilience probes." \
    || fail "server did NOT recover (${RECOVER})."
fi
fi

# ===========================================================================
# I. RATE LIMIT SEMANTICS  [LIMITED]
#
# Runs only when the bucket is small. Verifies 429 shape and refill, and
# declares up front that it will drain the bucket.
# ===========================================================================
if should_run I; then
hdr "I. Rate limit semantics — 429, retry-after, refill"

if [[ "${MODE}" != "LIMITED" ]]; then
  skipped "needs LIMITED mode — bucket is untrippable in BENCH."
  detail "  RATE_LIMIT_REQUESTS=50 RATE_LIMIT_WINDOW_SECS=60 just run"
  RESULTS[rl_semantics]="skipped"
else
  detail "⚠ This probe DRAINS the bucket. Nothing after it may assume 200s."

  DRAIN_N=$(( BUCKET_ESTIMATE * 3 + 50 ))
  STATUSES="$(
    seq "${DRAIN_N}" | xargs -P20 -I{} \
      curl -s -o /dev/null -w '%{http_code}\n' "${BASE_URL}/health" || true
  )"
  N_200="$(grep -c '^200$' <<<"${STATUSES}" || true)"
  N_429="$(grep -c '^429$' <<<"${STATUSES}" || true)"

  detail "fired ${DRAIN_N}: ${N_200} × 200, ${N_429} × 429"

  if [[ "${N_429}" -eq 0 ]]; then
    fail "no 429 in ${DRAIN_N} requests despite LIMITED mode detection."
    detail "Inconsistent — check the bucket refill math."
    RESULTS[rl_semantics]="no_429"
  else
    pass "limiter rejected ${N_429} requests after allowing ${N_200}."
    RESULTS[rl_allowed]="${N_200}"
    RESULTS[rl_rejected]="${N_429}"

    RL_H="$(http_headers "${BASE_URL}/health")"

    grep -qi '^retry-after:' <<<"${RL_H}" \
      && pass "429 carries retry-after: $(grep -i '^retry-after:' <<<"${RL_H}" \
              | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')" \
      || { warn "429 has no retry-after — clients get no backoff signal."
           detail "Check the header name is hyphenated, not underscored."; }

    # A 429 without a request id cannot be correlated in logs. That is a
    # middleware ORDERING bug: trace/request-id must WRAP the limiter.
    grep -qi '^x-request-id:' <<<"${RL_H}" \
      && pass "429 carries x-request-id (rejections remain traceable)." \
      || { warn "429 has no x-request-id."
           detail "Middleware ordering: trace/request-id must wrap the"
           detail "limiter, not sit inside it."; }

    BODY="$(curl -s "${BASE_URL}/health")"
    grep -qi 'rate' <<<"${BODY}" \
      && pass "429 body explains the rejection." \
      || warn "429 body does not mention rate limiting: ${BODY:0:80}"

    # --- Refill ------------------------------------------------------------
    detail "waiting 5s to observe refill..."
    sleep 5
    AFTER="$(http_code "${BASE_URL}/health")"
    detail "after 5s -> ${AFTER}"
    if [[ "${AFTER}" == "429" ]]; then
      warn "still throttled after 5s."
      detail "Expected with a long window. Not necessarily a bug, but a"
      detail "client seeing this has no way to make progress."
    else
      pass "bucket refilled; requests accepted again."
    fi
    RESULTS[rl_refill]="${AFTER}"
  fi
fi
fi

# ===========================================================================
# J. RATE LIMIT ISOLATION  [LIMITED]
#
# load_test.sh proves SOME request gets a 429. It does NOT prove buckets are
# PER-IP — a single global counter satisfies every existing assertion.
#
# Runs LAST because it is the most destructive probe in the suite.
# ===========================================================================
if should_run J; then
hdr "J. Rate limit isolation — per-IP, not global"

if [[ "${MODE}" != "LIMITED" ]]; then
  skipped "needs LIMITED mode."
  RESULTS[rl_isolation]="skipped"
else
  IP_A="203.0.113.10"   # TEST-NET-3 — reserved for documentation
  IP_B="203.0.113.20"

  detail "⚠ Final probe: drains buckets for ${IP_A} and possibly loopback."
  detail "waiting 5s for a clean starting state..."
  sleep 5

  DRAIN_N=$(( BUCKET_ESTIMATE * 3 + 50 ))
  A_429="$(
    seq "${DRAIN_N}" | xargs -P20 -I{} \
      curl -s -o /dev/null -w '%{http_code}\n' \
        -H "x-forwarded-for: ${IP_A}" "${BASE_URL}/health" \
    | grep -c '^429$' || true
  )"
  detail "drained ${IP_A} with ${DRAIN_N} requests -> ${A_429} rejected"

  if [[ "${A_429}" -eq 0 ]]; then
    skipped "could not drain a bucket in ${DRAIN_N} requests."
    RESULTS[rl_isolation]="undrainable"
  else
    A_STATUS="$(http_code -H "x-forwarded-for: ${IP_A}" "${BASE_URL}/health")"
    B_STATUS="$(http_code -H "x-forwarded-for: ${IP_B}" "${BASE_URL}/health")"
    LOOPBACK="$(http_code "${BASE_URL}/health")"

    detail "IP A (drained)       -> ${A_STATUS}"
    detail "IP B (fresh)         -> ${B_STATUS}"
    detail "no header (loopback) -> ${LOOPBACK}"

    if [[ "${A_STATUS}" != "429" ]]; then
      warn "IP A no longer throttled — the bucket refilled mid-probe."
      detail "Lengthen window_secs or lower DRAIN_N."
      RESULTS[rl_isolation]="inconclusive"
    elif [[ "${B_STATUS}" != "429" ]]; then
      pass "buckets are PER-IP: A throttled, B unaffected."
      RESULTS[rl_isolation]="per_ip"
    elif [[ "${LOOPBACK}" == "429" ]]; then
      # Everything throttled, including a client never touched. Two causes,
      # and this probe cannot distinguish them. Say so rather than guess.
      skipped "all clients throttled — two indistinguishable causes:"
      detail "  (1) x-forwarded-for ignored (trust_proxy_headers off), so"
      detail "      every request drained the loopback bucket; or"
      detail "  (2) the bucket really is global."
      detail "Build with --features trust_proxy_headers to disambiguate."
      RESULTS[rl_isolation]="indistinguishable"
    else
      fail "IP B throttled although it sent no prior requests — GLOBAL bucket."
      detail "Check extract_ip(): absent ConnectInfo returns 0.0.0.0 for"
      detail "every client, silently collapsing all buckets into one."
      detail "Is the server using into_make_service_with_connect_info?"
      RESULTS[rl_isolation]="global"
    fi

    # --- Spoofing note -----------------------------------------------------
    if [[ "${B_STATUS}" != "429" && "${A_STATUS}" == "429" ]]; then
      warn "x-forwarded-for is TRUSTED from a direct client."
      detail "Any client can rotate this header to bypass the limiter."
      detail "Only honour it behind a proxy that overwrites it."
    fi
  fi
fi
fi

# ===========================================================================
# K. OBSERVABILITY
#
# Request-id propagation is the machine-checkable half of the Phase 3
# criterion. Log correlation itself needs a human eye — we print the id.
# ===========================================================================
if should_run K; then
hdr "K. Observability — request id propagation"

SUPPLIED="behaviour-$(date +%s)-$$"
ECHOED="$(http_headers -H "x-request-id: ${SUPPLIED}" "${BASE_URL}/health" \
        | grep -i '^x-request-id:' | head -n1 \
        | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"

detail "sent     : ${SUPPLIED}"
detail "received : ${ECHOED:-<none>}"

if [[ -z "${ECHOED}" ]]; then
  fail "no x-request-id on the response."
  detail "Is PropagateRequestIdLayer in the stack?"
elif [[ "${ECHOED}" != "${SUPPLIED}" ]]; then
  fail "x-request-id not preserved (got '${ECHOED}')."
else
  pass "client-supplied x-request-id echoed unchanged."
fi
RESULTS[request_id_echo]="${ECHOED:-none}"

GEN_1="$(http_headers "${BASE_URL}/health" | grep -i '^x-request-id:' \
        | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
GEN_2="$(http_headers "${BASE_URL}/health" | grep -i '^x-request-id:' \
        | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"

[[ -z "${GEN_1}" ]] \
  && { fail "no x-request-id generated when the client omitted it."
       detail "Is SetRequestIdLayer wired up?"; } \
  || pass "an x-request-id was generated (${GEN_1:0:13}...)."

[[ -n "${GEN_1}" && "${GEN_1}" == "${GEN_2}" ]] \
  && fail "two requests received the SAME generated id." \
  || pass "generated ids are distinct across requests."

# --- Ids must survive error paths too --------------------------------------
ERR_ID="$(http_headers "${BASE_URL}/$(random_valid_code)" \
        | grep -i '^x-request-id:' | head -n1 || true)"
[[ -n "${ERR_ID}" ]] \
  && pass "404 responses also carry x-request-id." \
  || warn "404 has no x-request-id — errors cannot be correlated."

# --- The half a script cannot check ----------------------------------------
CORRELATE="correlate-$(date +%s)-$$"
curl -s -o /dev/null -H "x-request-id: ${CORRELATE}" \
  "${BASE_URL}/$(random_valid_code)"
info "  Manual check — correlation across middleware AND handler:"
detail ""
detail "    grep '${CORRELATE}' <server log>"
detail ""
detail "The id must appear on BOTH the middleware span and the handler's"
detail "own events. Scraping stdout would couple this harness to log"
detail "formatting, so verify once by eye; the header assertions above are"
detail "the regression guard."
RESULTS[correlate_id]="${CORRELATE}"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
hdr "Summary"

detail "mode: ${MODE} (bucket estimate ~${BUCKET_ESTIMATE} requests)"

if [[ "${STATS_AVAILABLE}" -eq 1 ]]; then
  H="$(stat_field hits)"; NG="$(stat_field negative_hits)"
  M="$(stat_field misses)"; D="$(stat_field db_queries)"
  T=$(( H + NG + M ))
  detail "cache: ${H} hits, ${NG} negative, ${M} misses, ${D} db queries"
  if [[ "${T}" -gt 0 ]]; then
    R="$(awk "BEGIN{printf \"%.2f\", 100*(${H}+${NG})/${T}}")"
    detail "hit ratio: ${R}%"
    RESULTS[hit_ratio]="${R}"
  fi
  RESULTS[hits]="${H}"; RESULTS[negative_hits]="${NG}"
  RESULTS[misses]="${M}"; RESULTS[db_queries]="${D}"
fi

detail "failures: ${FAILURES}, warnings: ${WARNINGS}"

if [[ "${MODE}" == "BENCH" ]]; then
  detail ""
  detail "Rate-limit probes (I, J) were SKIPPED. Rerun in LIMITED mode:"
  detail "  RATE_LIMIT_REQUESTS=50 RATE_LIMIT_WINDOW_SECS=60 just run"
  detail "  ONLY=I,J ./scripts/behaviour_test.sh"
elif [[ "${MODE}" == "LIMITED" ]]; then
  detail ""
  detail "Load probes (E, F, G, H) were SKIPPED. Rerun in BENCH mode:"
  detail "  RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 just run"
  detail "  SKIP=I,J ./scripts/behaviour_test.sh"
fi

# --- Machine-readable output -----------------------------------------------
#
# Without history, one anomalous run invites a confident causal story built
# on n=1 — which has already happened twice on this project.
if [[ -n "${JSON_OUT:-}" ]]; then
  {
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "base_url": "%s",\n' "${BASE_URL}"
    printf '  "mode": "%s",\n' "${MODE}"
    printf '  "failures": %d,\n' "${FAILURES}"
    printf '  "warnings": %d,\n' "${WARNINGS}"
    printf '  "results": {\n'
    first=1
    for k in "${!RESULTS[@]}"; do
      [[ "${first}" -eq 0 ]] && printf ',\n'
      printf '    "%s": "%s"' "${k}" "${RESULTS[$k]}"
      first=0
    done
    printf '\n  }\n}\n'
  } > "${JSON_OUT}"
  detail "wrote ${JSON_OUT}"
fi

# ===========================================================================
# VERDICT
# ===========================================================================
hdr "Verdict"

if [[ "${FAILURES}" -eq 0 ]]; then
  green "  All probes passed in ${MODE} mode.  (${WARNINGS} warning(s))"
  echo
  exit 0
else
  red "  ${FAILURES} probe(s) FAILED in ${MODE} mode.  (${WARNINGS} warning(s))"
  echo
  exit 1
fi
