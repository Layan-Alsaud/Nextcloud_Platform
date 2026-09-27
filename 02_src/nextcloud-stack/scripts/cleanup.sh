#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo "[cleanup] Stopping and removing containers..."

docker compose down --remove-orphans

echo "[cleanup] Cleanup completed."
echo "[cleanup] Persistent volumes were kept."
