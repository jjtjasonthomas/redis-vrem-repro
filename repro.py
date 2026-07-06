#!/usr/bin/env python3
"""
Reproducer for the Redis 8.4.0 vector-sets VREM crash (SIGSEGV).

Workload: build many SMALL vector sets (one per "tenant", like a
per-seller key) and fully drain each one in insertion order -- i.e. the
"delete oldest first" pattern of a rolling-window / TTL cleanup job.

Why this triggers the bug: in a small HNSW graph the upper layers hold
only 1-2 nodes. Deleting the graph's entry-point node while its upper
layers have lost their links makes Redis record max_level too low
(hnsw_unlink_node). A later VREM of a still-taller node then makes the
delete-repair search (hnsw_reconnect_nodes) read past the end of the
entry-point node's allocation -> crash in select_neighbors /
hnsw_reconnect_nodes. See README.md for the full root-cause chain.

Usage: python3 repro.py [host] [port]      (default 127.0.0.1 6399)
"""
import random
import sys

import redis

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 6399
DIM = 8              # vector dim; the graph's level structure is what matters
M = 4                # low fanout -> sparse upper layers erode faster
SET_SIZE = 80        # small graph: only a handful of nodes per upper layer
NUM_KEYS = 1000000   # keep making fresh keys until the server crashes


def rand_vec():
    return [random.uniform(-1, 1) for _ in range(DIM)]


def main():
    r = redis.Redis(host=HOST, port=PORT, socket_timeout=30)
    r.ping()
    print(f"connected {HOST}:{PORT}, redis {r.info('server')['redis_version']}")

    total = 0
    last_key = None
    deleted = []
    try:
        for k in range(NUM_KEYS):
            key = f"s{k}"
            names = []
            for i in range(SET_SIZE):
                name = f"e{i}"
                r.execute_command("VADD", key, "VALUES", str(DIM),
                    *[f"{x:.6f}" for x in rand_vec()], name, "M", str(M))
                names.append(name)
            # Fully drain in insertion order = "delete oldest first".
            last_key = key
            deleted = []
            for name in names:
                r.execute_command("VREM", key, name)
                deleted.append(name)
                total += 1
            if k % 100 == 0:
                print(f"drained {k+1} keys, {total} VREMs -- alive")
        print("completed without a crash (unlucky run); re-run repro.py")
    except (redis.exceptions.ConnectionError,
            redis.exceptions.TimeoutError) as e:
        print()
        print("=" * 70)
        print(f"SERVER CRASHED draining key '{last_key}' on VREM "
              f"#{len(deleted)} ({deleted[-1] if deleted else '?'})")
        print(f"total VREMs before crash: {total}")
        print(f"driver error: {type(e).__name__}: {e}")
        print("=" * 70)
        print("get the crash report with:")
        print("  docker logs vrem-repro 2>&1 | grep -A25 'REDIS BUG REPORT START'")
        sys.exit(1)


if __name__ == "__main__":
    main()
