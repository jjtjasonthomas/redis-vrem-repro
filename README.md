# Redis 8.4.0 vector-sets: `VREM` crashes the server (SIGSEGV)

`VREM` on a vector set can crash Redis with a NULL / out-of-bounds pointer
dereference in the HNSW delete-repair path. It is triggered by workloads
that maintain many small vector sets and delete elements from them over
time (e.g. a per-tenant key with a rolling time window / TTL cleanup job).

Observed in production on Redis 8.4.0 (cluster, aarch64): a replica crashed
applying a replicated `VREM`, and after failover the promoted master
crashed the same way. Both crashes:

```
Redis 8.4.0 crashed by signal: 11, si_code: 1
Accessing address: (nil)
Stack: VREM_RedisCommand -> hnsw_reconnect_nodes -> select_neighbors
```

## Root cause

All line numbers are Redis 8.4.0, `modules/vector-sets/hnsw.c`.

1. **`hnsw_unlink_node()` can record `max_level` too low.** When the deleted
   node is the graph's entry point, the replacement is chosen from the
   deleted node's own neighbor links -- the first neighbor at its highest
   layer that still has links (`hnsw.c:1637`) -- and `index->max_level` is
   set to that replacement's level (`hnsw.c:1662`). If the old entry point's
   upper layers had lost their links (neighbor deletions whose repair
   quietly failed, or link eviction during inserts), the replacement can be
   a lower-level node while taller nodes still exist in the graph.
   `max_level` is now smaller than the true tallest node.

2. **`hnsw_reconnect_nodes()` then searches above the entry point's level.**
   A later `VREM` of one of those still-taller nodes runs the repair for
   every layer the node lived on, including `layer > max_level`. The
   broader-graph search (`hnsw.c:1519-1535`) descends from `max_level`
   (a no-op when `max_level < layer`) and calls
   `search_layer(..., layer, ...)` with `curr_ep = index->enter_point`,
   whose `level < layer`. Nothing validates the entry point's level against
   the requested layer.

3. **Out-of-bounds read.** `search_layer()` unconditionally dereferences
   `entry_point->layers[layer]` (`hnsw.c:789`). `layers[]` is a flexible
   array sized by the node's level, so this reads past the end of the node's
   allocation, and the entry point is unconditionally pushed as a candidate.

4. **Crash.** `select_neighbors()` (called with `aggressive>=1` from the
   repair path) inspects the garbage layer struct. If the out-of-bounds
   bytes are zero: `num_links (0) >= max_links (0)` makes the node look
   "full", the aggressive path skips the `worst_distance` guard, and
   `links[worst_idx]` dereferences `NULL[0]` -> SIGSEGV at `hnsw.c:1140`.
   If the bytes are non-zero garbage, the same read faults one frame up in
   `hnsw_reconnect_nodes` on a bad pointer. Same defect, two faces (see
   "Crash frames" below).

The on-disk format is not involved: `hnsw_deserialize_index()` rejects any
link to a node whose level is below the layer (`hnsw.c:2530`) and enforces
link reciprocity. The invariant is broken only at runtime.

## Why small, churned sets trigger it

The chain needs, within one graph: (1) delete the entry point while its
upper layers are bare, then (2) delete a still-taller node. In a large
graph the upper layers hold hundreds of well-linked nodes, so deleting the
entry point almost always finds a same-height replacement and `max_level`
stays correct. In a small graph an upper layer holds only 1-2 nodes and
easily fragments, so the bad replacement is routine. A rolling-window
cleanup that deletes every element eventually -- including whichever one is
the entry point -- runs this sequence constantly across many small keys.

Rate is irrelevant: the crash depends on the *structure* of the deletions,
not their volume. A slow trickle of `VREM`s hits it just as surely as a
flood; it only takes longer in wall-clock time.

## Requirements

- Docker (on macOS: `colima start` first)
- Python 3.8+

## Run (unmodified official redis:8.4.0)

```sh
./run.sh
```

Or manually:

```sh
# 1. official, unmodified redis:8.4.0 from Docker Hub
docker run -d --name vrem-repro -p 6399:6379 redis:8.4.0 \
    redis-server --appendonly no --save '' --protected-mode no

# 2. drive the workload (many small sets, drained oldest-first)
python3 -m venv .venv && ./.venv/bin/pip install redis   # first time only
./.venv/bin/python -u repro.py 127.0.0.1 6399

# 3. when it reports SERVER CRASHED, read the crash report
docker logs vrem-repro 2>&1 | grep -A25 "REDIS BUG REPORT START"
```

The workload prints `drained N keys ... alive` while churning, then dies
with `SERVER CRASHED`. Timing is probabilistic (the chain is a low-
probability coincidence per key) -- usually 1-10 minutes. If a run drains
past ~5000 keys without crashing, restart it; a fresh graph shape usually
triggers sooner.

## Deterministic variant: AddressSanitizer build

On the stock binary the innermost crash frame depends on the out-of-bounds
bytes (see below). An ASAN build reports the out-of-bounds *read* itself, at
its first occurrence, regardless of memory contents. `Dockerfile.asan`
builds Redis from source with `SANITIZER=address MALLOC=libc`.

```sh
# populate ./src with the redis 8.4.0 source tree, e.g. from a checkout:
#   git -C /path/to/redis archive 8.4.0 | (mkdir -p src && tar -x -C src)
./run.sh asan
```

Expected: `heap-buffer-overflow READ` in `search_layer` /
`select_neighbors`, with the allocation stack showing the entry-point node
from `hnsw_node_new` -- i.e. reading `node->layers[layer]` for a layer the
node does not have. Captured reports for 8.4.0 and for `unstable`
(`aa5409f1c`, still affected) are in `asan-report-8.4.0.txt` and
`asan-report-unstable.txt`.

## Crash frames (same bug, two faces)

The out-of-bounds read of the missing upper-layer struct surfaces
differently depending on what bytes follow the node in the heap:

- **zeroed bytes** -> the search survives (reads "0 links, NULL array"),
  returns the node, and `select_neighbors` dereferences the NULL ->
  `select_neighbors` + `Accessing address: (nil)` (the production frame).
- **non-zero garbage** -> the search itself faults on a bad pointer ->
  `hnsw_reconnect_nodes` frame.

Both are the same out-of-bounds read; the ASAN build catches it before it
degrades into either frame.

## Files

- `repro.py`  -- the workload (small sets, drained oldest-first)
- `run.sh`    -- one-command runner (`./run.sh`, or `./run.sh asan`)
- `Dockerfile.asan` -- ASAN build of Redis 8.4.0 from `./src`
- `crash-report-stock-8.4.0.txt` -- crash on the official redis:8.4.0 image
- `asan-report-8.4.0.txt`         -- ASAN out-of-bounds read on 8.4.0
- `asan-report-unstable.txt`      -- same, on latest `unstable` (aa5409f1c)

## Suggested fix

Either (or both):

- In `hnsw_unlink_node()`, when the deleted node was the entry point, keep
  `enter_point` / `max_level` equal to the true graph maximum (the existing
  full-scan fallback at `hnsw.c:1647-1657` already finds it; use it instead
  of trusting the deleted node's remaining links).
- In `hnsw_reconnect_nodes()` / `search_layer()`, skip / guard the search
  when the entry point's `level < layer` (never read `layers[layer]` for a
  node that does not have that layer).
