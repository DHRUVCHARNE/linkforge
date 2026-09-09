#!/usr/bin/env bash
#
# load_test.sh — LinkForge load / benchmark harness
#
# NOTE ON PHASING: the guide formally introduces load testing in **Phase 3**
# ("measure before you optimize"). This script is written so it works TODAY
# for a Phase 1 smoke/soak, and grows into the Phase 3 baseline harness.
#
# It does two things:
#   1. A correctness probe  — fires many concurrent /shorten requests and
#      asserts ZERO duplicate codes (mirrors the Phase 1 acceptance criterion).
#   2. A throughput probe   — uses `oha` or `wrk` if available to record a
#      baseline number you can paste into the README (Phase 3 deliverable).
#
# Usage:
#   ./scripts/load_test.sh [BASE_URL] [N_REQUESTS] [CONCURRENCY]
#
# Examples:
#   ./scripts/load_test.sh                              # defaults below
#   ./scripts/load_test.sh http://localhost:3000 2000 100
#
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
N="${2:-10000}"
CONCURRENCY="${3:-100}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Pre-flight: is the server up?
# ---------------------------------------------------------------------------
info "==> Health check: ${BASE_URL}/health"
if ! curl -fsS "${BASE_URL}/health" >/dev/null; then
  red "Server is not responding at ${BASE_URL}. Start it first (just run)."
  exit 1
fi
green "Server is up."

# ---------------------------------------------------------------------------
# 1. Correctness probe: concurrent shortens must never collide.
# ---------------------------------------------------------------------------
info "==> Correctness probe: ${N} concurrent POST /shorten (concurrency=${CONCURRENCY})"

TMP_CODES="$(mktemp)"
trap 'rm -f "${TMP_CODES}"' EXIT

seq "${N}" | xargs -P"${CONCURRENCY}" -I{} \
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/{}"}' \
  | grep -o '"code":"[^"]*"' \
  >> "${TMP_CODES}" || true

TOTAL="$(wc -l < "${TMP_CODES}" | tr -d ' ')"
UNIQUE="$(sort -u "${TMP_CODES}" | wc -l | tr -d ' ')"
DUPES=$(( TOTAL - UNIQUE ))

echo "    generated codes : ${TOTAL}"
echo "    unique codes    : ${UNIQUE}"
echo "    duplicates      : ${DUPES}"

if [[ "${DUPES}" -ne 0 ]]; then
  red "FAIL: found ${DUPES} duplicate code(s) under concurrency."
  exit 1
fi
green "PASS: zero duplicate codes under concurrency."

# ---------------------------------------------------------------------------
# 2. Throughput probe: prefer `oha`, fall back to `wrk`, else skip.
#    We benchmark the hot READ path (GET /:code) after seeding one link.
# ---------------------------------------------------------------------------
info "==> Throughput probe (hot read path GET /:code)"

SEED_CODE="$(
  curl -s -X POST "${BASE_URL}/shorten" \
    -H 'content-type: application/json' \
    -d '{"url":"https://www.rust-lang.org"}' \
  | grep -o '"code":"[^"]*"' | head -n1 | sed 's/.*:"//; s/"//'
)"

if [[ -z "${SEED_CODE}" ]]; then
  red "Could not seed a link for the throughput probe; skipping."
  exit 0
fi
echo "    seeded code: ${SEED_CODE}"
TARGET_URL="${BASE_URL}/${SEED_CODE}"

if command -v oha >/dev/null 2>&1; then
  info "    using oha (10s, ${CONCURRENCY} connections) — redirects disabled"
  oha -z 10s -c "${CONCURRENCY}" --no-tui "${TARGET_URL}"
elif command -v wrk >/dev/null 2>&1; then
  info "    using wrk (10s, ${CONCURRENCY} connections)"
  wrk -t4 -c"${CONCURRENCY}" -d10s "${TARGET_URL}"
else
  red "Neither 'oha' nor 'wrk' found — skipping throughput probe."
  echo "    Install one:  cargo install oha    (or)    apt-get install wrk"
fi

green "Load test complete."
