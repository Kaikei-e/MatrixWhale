#!/usr/bin/env bash
# Spins up a throwaway Postgres container, applies the Atlas migrations to it,
# then runs the Gleam integration tests against it. Always tears the container
# down, even on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DB_NAME="matrixwhale_test"
DB_USER="test"
DB_PASSWORD="test"
CONTAINER_NAME="matrixwhale_test_core_$$"
IMAGE_TAG="matrixwhale_test_core_db_$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rmi "$IMAGE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Build the same db/Dockerfile image compose uses: the stock postgis/postgis
# image runs its own initdb hook that creates topology/tiger schemas Atlas
# has never heard of, so the hook-stripped image is what stays "clean".
docker build -t "$IMAGE_TAG" "$REPO_ROOT/db" >/dev/null

docker run --rm -d --name "$CONTAINER_NAME" \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -e POSTGRES_DB="$DB_NAME" \
  -p "127.0.0.1::5432" \
  "$IMAGE_TAG" -c max_connections=400 >/dev/null

HOST_PORT="$(docker port "$CONTAINER_NAME" 5432/tcp | head -n 1 | cut -d: -f2)"

# The image's entrypoint runs a socket-only bootstrap server before the real
# one, so only a TCP readiness check proves the final server is up.
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

DATABASE_URL="postgres://$DB_USER:$DB_PASSWORD@localhost:$HOST_PORT/$DB_NAME?sslmode=disable"

atlas migrate apply --url "$DATABASE_URL" --dir "file://$REPO_ROOT/db/migrations"

cd "$REPO_ROOT/matrix_whale/matrix_whale"
MATRIX_WHALE_TEST_DATABASE_URL="$DATABASE_URL" gleam test
