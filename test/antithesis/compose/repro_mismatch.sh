#!/usr/bin/env bash
# repro_mismatch.sh — Reproduce the Tablet.Type vs Target.TabletType MISMATCH
#
# Mimics the real docker-compose dependency ordering:
#   1. Infrastructure (etcd, source_db, vtctld)
#   2. Tablets + vtgate (both depend on vtctld)
#   3. Wait for vtgate to discover all 6 tablets as REPLICA
#   4. THEN start vtorc (which promotes primaries)
#
# By the time vtorc promotes, vtgate has already cached every tablet as
# REPLICA via AddTablet. ReplaceTablet never fires (hostname/ports unchanged),
# so Tablet.Type stays stale at REPLICA (2) while Target.TabletType reports
# PRIMARY (1) from the streaming health check.
#
# Expected for primaries: Tablet.Type=2  Target.TabletType=1

set -euo pipefail
cd "$(dirname "$0")"

VTGATE_HTTP="http://localhost:15099"
CELL="test"

wait_for_promotions() {
  local max_wait=300
  local elapsed=0
  echo "Waiting for vtorc to promote primaries..."
  while true; do
    local out
    out=$(docker compose exec -T vtctld \
      /vt/bin/vtctldclient --server localhost:15999 GetTablets 2>/dev/null) || out=""
    local n
    n=$(echo "$out" | grep -ci "primary" || true)
    if [ "$n" -ge 3 ]; then
      echo "  $n primaries detected — promotions complete."
      return 0
    fi
    echo "  $n/3 primaries so far..."
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "ERROR: timed out after ${max_wait}s waiting for promotions" >&2
      exit 1
    fi
  done
}

wait_for_tablets_in_vtgate() {
  local expected=6
  local max_wait=120
  local elapsed=0
  echo "Waiting for vtgate to discover all $expected tablets..."
  while true; do
    local n
    n=$(curl -sf "$VTGATE_HTTP/api/health-check/cell/$CELL" 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(sum(len(cs.get('TabletsStats', [])) for cs in data))
" 2>/dev/null) || n=0
    if [ "$n" -ge "$expected" ]; then
      echo "  vtgate sees $n tablets."
      return 0
    fi
    echo "  vtgate sees $n/$expected tablets..."
    sleep 3
    elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "ERROR: timed out after ${max_wait}s waiting for vtgate to discover tablets" >&2
      exit 1
    fi
  done
}

wait_for_vtgate() {
  local max_wait=120
  local elapsed=0
  echo "Waiting for vtgate health..."
  while true; do
    if curl -sf "$VTGATE_HTTP/debug/health" >/dev/null 2>&1; then
      echo "  vtgate is healthy."
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "ERROR: timed out after ${max_wait}s waiting for vtgate" >&2
      exit 1
    fi
  done
}

show_tablet_types() {
  echo ""
  echo "=== Health-check API: /api/health-check/cell/$CELL ==="
  curl -sf "$VTGATE_HTTP/api/health-check/cell/$CELL" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for cs in data:
    for ts in cs.get('TabletsStats', []):
        t  = ts['Tablet']
        tg = ts['Target']
        tag = 'MATCH' if t['type'] == tg['tablet_type'] else 'MISMATCH'
        print(f\"  {t['keyspace']:>20}:{t['shard']:<4}  \"
              f\"Tablet.Type={t['type']}  Target.TabletType={tg['tablet_type']}  \"
              f\"Serving={ts['Serving']}  [{tag}]\")
"
  echo ""
  echo "  (Type 1 = PRIMARY, Type 2 = REPLICA)"
}

# ---------------------------------------------------------------
echo "=== repro_mismatch.sh ==="
echo ""

echo "Tearing down any existing containers..."
docker compose down --remove-orphans 2>/dev/null || true
echo ""

# Phase 1: infrastructure
echo "Phase 1: Starting infrastructure (etcd, source_db, vtctld)..."
docker compose up -d etcd source_db_host vtctld
echo ""

# Phase 2: tablets + vtgate (both depend on vtctld, mirroring compose graph)
echo "Phase 2: Starting tablets + vtgate..."
docker compose up -d \
  vttablet101 vttablet102 vttablet201 vttablet202 vttablet301 vttablet302 \
  vtgate
echo ""

wait_for_vtgate
echo ""

# Ensure vtgate has cached all 6 tablets as REPLICA before any promotions
wait_for_tablets_in_vtgate
echo ""

# Phase 3: durability policy + vtorc + schemaloads (vtorc triggers promotions)
echo "Phase 3: Starting vtorc (will promote primaries against vtgate's stale cache)..."
docker compose up -d \
  set_keyspace_durability_policy vtorc \
  schemaload_test_keyspace schemaload_lookup_keyspace \
  vreplication
echo ""

wait_for_promotions
echo ""

echo "Waiting for vtgate health-check cache to populate..."
sleep 15

show_tablet_types
