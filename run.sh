#!/usr/bin/env bash
# One-command reproducer for the Redis 8.4.0 vector-sets VREM crash.
# Runs the official, unmodified redis:8.4.0 image and drives the workload
# until the server segfaults. See README.md for details.
set -euo pipefail
cd "$(dirname "$0")"

if ! docker info >/dev/null 2>&1; then
    echo "docker not running (on macOS: colima start)" >&2; exit 1
fi

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip install -q redis
fi

NAME=vrem-repro
PORT=6399

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT":6379 redis:8.4.0 \
    redis-server --appendonly no --save '' --protected-mode no >/dev/null
sleep 2

echo "churning vector sets against redis:8.4.0 on port $PORT (Ctrl-C to stop) ..."
./.venv/bin/python -u repro.py 127.0.0.1 "$PORT" || true

echo
echo "===== crash report (docker logs $NAME) ====="
docker logs "$NAME" 2>&1 | grep -A25 "REDIS BUG REPORT START" | head -40
