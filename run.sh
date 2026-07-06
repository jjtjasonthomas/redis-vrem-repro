#!/usr/bin/env bash
# One-command reproducer for the Redis 8.4.0 vector-sets VREM crash.
# See README.md for details.
#
# Usage:
#   ./run.sh          # crash the official, unmodified redis:8.4.0 image
#   ./run.sh asan     # deterministic: AddressSanitizer build reports the
#                     #   out-of-bounds read (requires ./src, see README)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-stock}"

if ! docker info >/dev/null 2>&1; then
    echo "docker not running (on macOS: colima start)" >&2; exit 1
fi

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip install -q redis
fi

NAME=vrem-repro
PORT=6399
if [ "$MODE" = "asan" ]; then
    if ! docker image inspect redis-asan:8.4.0 >/dev/null 2>&1; then
        [ -d src ] || { echo "ASAN build needs ./src (redis 8.4.0 source)." \
            "See README.md 'Deterministic variant'." >&2; exit 1; }
        docker build -f Dockerfile.asan -t redis-asan:8.4.0 .
    fi
    IMAGE=redis-asan:8.4.0
else
    IMAGE=redis:8.4.0
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT":6379 "$IMAGE" \
    redis-server --appendonly no --save '' --protected-mode no >/dev/null
sleep 2

echo "churning vector sets against $IMAGE on port $PORT (Ctrl-C to stop) ..."
./.venv/bin/python -u repro.py 127.0.0.1 "$PORT" || true

echo
echo "===== crash evidence (docker logs $NAME) ====="
if [ "$MODE" = "asan" ]; then
    docker logs "$NAME" 2>&1 | grep -A30 "AddressSanitizer" | head -50
else
    docker logs "$NAME" 2>&1 | grep -A25 "REDIS BUG REPORT START" | head -40
fi
