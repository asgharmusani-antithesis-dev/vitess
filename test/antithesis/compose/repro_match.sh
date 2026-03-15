#!/usr/bin/env bash
# repro_match.sh — Reproduce the Tablet.Type / Target.TabletType MATCH
#
# Starts all services except vtgate and antithesis-client, waits for vtorc
# to promote primaries, then stops and removes any vtgate container to ensure
# a completely clean slate. Starting vtgate fresh means the topo watcher's
# first loadTablets() calls AddTablet with the already-promoted types from
# topo, so Tablet.Type correctly reflects PRIMARY.
#
# Expected for primaries: Tablet.Type=1  Target.TabletType=1

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
echo "=== repro_match.sh ==="
echo ""

echo "Tearing down any existing containers..."
docker compose down --remove-orphans 2>/dev/null || true
echo ""

echo "Starting infrastructure + tablets + vtorc (no vtgate, no antithesis-client)..."
docker compose up -d \
  etcd source_db_host vtctld \
  vttablet101 vttablet102 vttablet201 vttablet202 vttablet301 vttablet302 \
  set_keyspace_durability_policy vtorc \
  schemaload_test_keyspace schemaload_lookup_keyspace \
  vreplication
echo ""

wait_for_promotions
echo ""

echo "Stopping and removing vtgate container (ensure clean slate)..."
docker compose rm -sf vtgate 2>/dev/null || true
echo ""

echo "Starting vtgate fresh (after promotions)..."
docker compose up -d vtgate
echo ""

wait_for_vtgate
echo ""

echo "Waiting for vtgate health-check cache to populate..."
sleep 15

show_tablet_types
