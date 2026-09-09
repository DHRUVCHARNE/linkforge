#!/usr/bin/env bash
#
# setup_db.sh — prepare the local database for LinkForge
#
# NOTE ON PHASING: persistence (sqlx + SQLite) arrives in **Phase 2**. In
# Phase 1 the store is purely in-memory, so you don't strictly need this yet.
# It's scaffolded now so the command exists the moment Phase 2 begins.
#
# What it does:
#   * ensures the sqlx CLI is available
#   * reads DATABASE_URL from the environment or .env (defaults to a local
#     SQLite file)
#   * creates the database and runs migrations from ./migrations
#
# Usage:
#   ./scripts/setup_db.sh
#   DATABASE_URL="sqlite://linkforge.db" ./scripts/setup_db.sh
#
set -euo pipefail

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Load .env if present (never commit real secrets — see .env.example).
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
  info "==> Loading .env"
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

# Default to a local SQLite file if DATABASE_URL is unset (Phase 2 default).
DATABASE_URL="${DATABASE_URL:-sqlite://linkforge.db}"
export DATABASE_URL
info "==> DATABASE_URL = ${DATABASE_URL}"

# ---------------------------------------------------------------------------
# 2. Ensure the sqlx CLI is installed.
# ---------------------------------------------------------------------------
if ! command -v sqlx >/dev/null 2>&1; then
  red "sqlx CLI not found."
  echo "    Install it with:"
  echo "      cargo install sqlx-cli --no-default-features --features rustls,sqlite"
  exit 1
fi
green "sqlx CLI found: $(sqlx --version)"

# ---------------------------------------------------------------------------
# 3. Create the database (idempotent) and run migrations.
# ---------------------------------------------------------------------------
info "==> Creating database (if it does not exist)"
sqlx database create

if [[ -d migrations ]] && compgen -G "migrations/*.sql" >/dev/null; then
  info "==> Running migrations from ./migrations"
  sqlx migrate run
  green "Migrations applied."
else
  red "No migrations found in ./migrations — nothing to run yet."
  echo "    Create your first one in Phase 2:  sqlx migrate add init"
fi

green "Database setup complete."
