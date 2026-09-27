#!/usr/bin/env bash
set -euo pipefail

# This script is stored inside scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BACKUP_DIR="$PROJECT_DIR/backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [ ! -f ".env" ]; then
  echo "[backup][ERROR] .env file not found in $PROJECT_DIR"
  exit 1
fi

# Load environment variables
set -a
source .env
set +a

: "${POSTGRES_USER:?POSTGRES_USER is missing from .env}"
: "${POSTGRES_DB:?POSTGRES_DB is missing from .env}"

DB_BACKUP="$BACKUP_DIR/db-$TIMESTAMP.sql"
FILES_BACKUP="$BACKUP_DIR/nextcloud-$TIMESTAMP.tar.gz"

maintenance_enabled=0

disable_maintenance() {
  if [ "$maintenance_enabled" -eq 1 ]; then
    echo "[backup] Disabling Nextcloud maintenance mode..."
    docker compose exec -T -u www-data app \
      php occ maintenance:mode --off || true
  fi
}

trap disable_maintenance EXIT

echo "[backup] Starting backup..."

echo "[backup] Enabling Nextcloud maintenance mode..."
docker compose exec -T -u www-data app \
  php occ maintenance:mode --on
maintenance_enabled=1

echo "[backup] Backing up PostgreSQL..."
docker compose exec -T db \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  > "$DB_BACKUP"

echo "[backup] Backing up Nextcloud files..."
docker compose exec -T app \
  tar czf - -C /var/www/html . \
  > "$FILES_BACKUP"

chmod 600 "$DB_BACKUP" "$FILES_BACKUP"

echo "[backup] Backup completed successfully."
echo "[backup] Database: $DB_BACKUP"
echo "[backup] Files:    $FILES_BACKUP"

# Keep only backup files from the last 7 days
find "$BACKUP_DIR" -type f -mtime +7 -delete

disable_maintenance
maintenance_enabled=0
trap - EXIT
