#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo "[redeploy] Stopping current deployment..."

docker compose down --remove-orphans

echo "[redeploy] Pulling Docker images..."

docker compose pull

echo "[redeploy] Starting deployment..."

bash deploy.sh

echo "[redeploy] Redeployment completed."

docker compose ps