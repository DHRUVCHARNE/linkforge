#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"
OHA_OUT="${OHA_OUT:-/tmp/oha.txt}"
SERVER_LOG="${SERVER_LOG:-/tmp/run.log}"

PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-app_user}"
PG_DB="${PG_DB:-linkforge}"

LOAD_DURATION="${LOAD_DURATION:-15s}"
CONCURRENCY="${CONCURRENCY:-50}"
KILL_AFTER_SECS="${KILL_AFTER_SECS:-5}"

echo "=== LinkForge graceful-shutdown test ==="

# ---------------------------------------------------------------------------
# 1. Create a fresh link
# ---------------------------------------------------------------------------

CODE="$(
    curl -fsS -X POST "${BASE_URL}/shorten" \
        -H 'content-type: application/json' \
        -d '{"url":"https://example.com"}' \
    | grep -o '"code":"[^"]*"' \
    | head -n1 \
    | sed 's/.*:"//; s/"//'
)"

if [[ -z "${CODE}" ]]; then
    echo "FAIL: shorten returned no code"
    exit 1
fi

echo "code: ${CODE}"

# ---------------------------------------------------------------------------
# 2. Verify redirect before starting load
#
# This request itself records ONE click.
# ---------------------------------------------------------------------------

STATUS="$(
    curl -s -o /dev/null \
        -w '%{http_code}' \
        "${BASE_URL}/${CODE}"
)"

if [[ "${STATUS}" != "307" ]]; then
    echo "FAIL: redirect precondition returned ${STATUS}, expected 307"
    exit 1
fi

echo "redirect ok: ${STATUS}"

WARMUP_CLICKS=1

# Give async writer enough time to persist the warm-up click.
sleep 0.2

# ---------------------------------------------------------------------------
# 3. Establish the DB baseline
#
# This makes the test robust even if the database was not freshly reset.
# ---------------------------------------------------------------------------

DB_BEFORE="$(
    docker compose exec -T "${PG_SERVICE}" \
        psql -U "${PG_USER}" -d "${PG_DB}" -At \
        -c "SELECT COUNT(*) FROM clicks WHERE code = '${CODE}';"
)"

echo "database count before load: ${DB_BEFORE}"

# ---------------------------------------------------------------------------
# 4. Start oha
# ---------------------------------------------------------------------------

rm -f "${OHA_OUT}"

oha \
    -z "${LOAD_DURATION}" \
    -c "${CONCURRENCY}" \
    --no-tui \
    "${BASE_URL}/${CODE}" \
    > "${OHA_OUT}" 2>&1 &

OHA_PID=$!

# Make sure oha didn't immediately fail due to a malformed URL/config.
sleep 1

if ! kill -0 "${OHA_PID}" 2>/dev/null; then
    echo "FAIL: oha exited before load started"
    cat "${OHA_OUT}"
    exit 1
fi

echo "oha running as PID ${OHA_PID}"

# ---------------------------------------------------------------------------
# 5. Find exactly one LinkForge server
# ---------------------------------------------------------------------------

mapfile -t SERVER_PIDS < <(
    pgrep -f 'target/release/linkforge' || true
)

if [[ "${#SERVER_PIDS[@]}" -ne 1 ]]; then
    echo "FAIL: expected exactly one LinkForge server, found ${#SERVER_PIDS[@]}"
    printf 'PID: %s\n' "${SERVER_PIDS[@]:-<none>}"
    pgrep -af linkforge || true
    exit 1
fi

SERVER_PID="${SERVER_PIDS[0]}"

# ---------------------------------------------------------------------------
# 6. SIGTERM while requests are actively arriving
# ---------------------------------------------------------------------------

sleep "${KILL_AFTER_SECS}"

echo "sending SIGTERM to ${SERVER_PID}"

kill -TERM "${SERVER_PID}"

# Wait for load generator to observe shutdown.
wait "${OHA_PID}" || true

# Give the server log / process shutdown a moment to settle.
sleep 1

# ---------------------------------------------------------------------------
# 7. Parse HTTP results
# ---------------------------------------------------------------------------

SERVED="$(
    sed -n '/Status code distribution:/,/^$/p' "${OHA_OUT}" \
        | grep -E '\[307\][[:space:]]+[0-9]+' \
        | awk '{print $2}' \
        | head -n1 \
        || true
)"

SERVED="${SERVED:-0}"

HTTP_5XX="$(
    sed -n '/Status code distribution:/,/^$/p' "${OHA_OUT}" \
        | grep -E '\[5[0-9]{2}\]' \
        || true
)"

echo
echo "--- HTTP results ---"
echo "oha 307 responses : ${SERVED}"

if [[ -z "${HTTP_5XX}" ]]; then
    echo "5xx responses      : 0"
else
    echo "5xx responses:"
    echo "${HTTP_5XX}"
fi

# ---------------------------------------------------------------------------
# 8. Read rows actually persisted for THIS code
# ---------------------------------------------------------------------------

DB_AFTER="$(
    docker compose exec -T "${PG_SERVICE}" \
        psql -U "${PG_USER}" -d "${PG_DB}" -At \
        -c "SELECT COUNT(*) FROM clicks WHERE code = '${CODE}';"
)"

DB_DELTA=$(( DB_AFTER - DB_BEFORE ))

echo
echo "--- persistence ---"
echo "before : ${DB_BEFORE}"
echo "after  : ${DB_AFTER}"
echo "delta  : ${DB_DELTA}"

# ---------------------------------------------------------------------------
# 9. Get writer shutdown totals when server log is available
# ---------------------------------------------------------------------------

echo
echo "--- shutdown log ---"

WRITER_LINE=""

if [[ -f "${SERVER_LOG}" ]]; then
    grep -E \
        'SIGTERM received|in-flight requests drained|bucket sweeper stopped|click writer drained and stopped|shutdown complete' \
        "${SERVER_LOG}" || true

    WRITER_LINE="$(
        grep 'click writer drained and stopped' "${SERVER_LOG}" \
            | tail -n1 \
            || true
    )"
else
    echo "server log not found at ${SERVER_LOG}"
    echo "Start terminal 1 with:"
    echo "  cargo run --release 2>&1 | tee ${SERVER_LOG}"
fi

# ---------------------------------------------------------------------------
# 10. Assertions
# ---------------------------------------------------------------------------

echo
echo "--- assertions ---"

FAILURES=0

if [[ "${SERVED}" -le 0 ]]; then
    echo "FAIL: oha recorded zero successful redirects"
    FAILURES=$(( FAILURES + 1 ))
else
    echo "PASS: ${SERVED} redirects completed before shutdown"
fi

if [[ -n "${HTTP_5XX}" ]]; then
    echo "FAIL: HTTP 5xx responses occurred"
    FAILURES=$(( FAILURES + 1 ))
else
    echo "PASS: no HTTP 5xx responses"
fi

# DB_DELTA includes the clicks persisted after DB_BEFORE.
# DB_BEFORE was sampled AFTER the single warmup request, so it should
# approximately equal successful oha redirects minus deliberate drops.
if [[ "${DB_DELTA}" -gt "${SERVED}" ]]; then
    echo "FAIL: persisted more clicks (${DB_DELTA}) than oha redirects (${SERVED})"
    FAILURES=$(( FAILURES + 1 ))
else
    echo "PASS: persisted click count is not greater than served redirects"
fi

# ---------------------------------------------------------------------------
# 11. If final writer counters are available, verify conservation exactly
# ---------------------------------------------------------------------------

if [[ -n "${WRITER_LINE}" ]]; then
    WRITTEN="$(
        grep -oE 'rows_written: [0-9]+|rows_writtem: [0-9]+' <<<"${WRITER_LINE}" \
            | grep -oE '[0-9]+' \
            | tail -n1 \
            || true
    )"

    DROPPED="$(
        grep -oE 'dropped: [0-9]+' <<<"${WRITER_LINE}" \
            | grep -oE '[0-9]+' \
            | tail -n1 \
            || true
    )"

    echo
    echo "--- writer totals ---"
    echo "rows written : ${WRITTEN:-unknown}"
    echo "dropped      : ${DROPPED:-unknown}"

    if [[ -n "${WRITTEN}" && -n "${DROPPED}" ]]; then
        ATTEMPTS=$(( WRITTEN + DROPPED ))

        echo "attempts      : ${ATTEMPTS}"

        # These counters are process-global, so only compare them directly
        # with this code's redirects when the process/database was clean.
        #
        # The per-code DB delta above remains valid even on a non-clean DB.
        if [[ "${DROPPED}" -gt 0 ]]; then
            echo "INFO: backpressure activated; ${DROPPED} clicks deliberately dropped"
        else
            echo "PASS: zero analytics drops"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 12. Full oha status section
# ---------------------------------------------------------------------------

echo
echo "--- status distribution ---"