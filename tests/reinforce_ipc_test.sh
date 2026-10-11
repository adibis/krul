#!/usr/bin/env bash
# reinforce_ipc_test.sh — integration test for the reinforce IPC method and
# the decay-aware query path end to end (daemon + Postgres, not just db.c).
# Requires kruld to be running, started from a directory whose krul.toml
# points [db] conninfo at the same database KRUL_TEST_PSQL_DB names below
# (see tests/test_evaporation.c's header for creating a disposable db).
# Usage: ./tests/reinforce_ipc_test.sh
set -euo pipefail

SOCK="${KRUL_SOCK:-/tmp/krul.sock}"
PSQL_DB="${KRUL_TEST_PSQL_DB:-krul_test}"
PROJECT="reinforce_ipc_test"
PASS=0
FAIL=0

send() { printf '%s\n' "$1" | nc -U "$SOCK" 2>/dev/null; }

check() {
    local desc="$1" resp="$2" want_substr="$3"
    if [[ "$resp" == *"$want_substr"* ]]; then
        printf "  PASS  %s\n" "$desc"
        PASS=$(( PASS + 1 ))
    else
        printf "  FAIL  %s\n" "$desc"
        printf "        want substring : %s\n" "$want_substr"
        printf "        got            : %s\n" "$resp"
        FAIL=$(( FAIL + 1 ))
    fi
}

cleanup() {
    psql "$PSQL_DB" -q -c "DELETE FROM krul_projects WHERE name = '${PROJECT}';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== reinforce + decay-aware query — integration test ==="
echo

cleanup
psql "$PSQL_DB" -q -c "INSERT INTO krul_projects(name, root_path) VALUES ('${PROJECT}', '/tmp/${PROJECT}');" >/dev/null
EID=$(psql "$PSQL_DB" -q -t -A -c "
  INSERT INTO entities(project_id, kind, name, file_path, line_start, line_end)
  SELECT id, 'MODULE', 'reinforce_ipc_entity', 'ipc.sv', 1, 1
  FROM krul_projects WHERE name = '${PROJECT}'
  RETURNING id;" | head -1 | tr -d '[:space:]')
echo "test entity id: $EID"
echo

resp=$(send "{\"method\":\"ping\"}")
check "daemon is reachable" "$resp" '"pong"'

resp=$(send "{\"method\":\"query\",\"type\":\"entities\",\"project\":\"${PROJECT}\"}")
check "fresh entity appears in default query_entities results" "$resp" "reinforce_ipc_entity"

psql "$PSQL_DB" -q -c "UPDATE entities SET last_reinforced_at = NOW() - INTERVAL '10000 hours' WHERE id = ${EID};" >/dev/null

resp=$(send "{\"method\":\"query\",\"type\":\"entities\",\"project\":\"${PROJECT}\"}")
check "decayed entity is excluded from default query_entities results" "$resp" '"result":[]'

resp=$(send "{\"method\":\"reinforce\",\"kind\":\"entity\",\"id\":${EID}}")
check "reinforce reports success" "$resp" '"reinforced":true'

resp=$(send "{\"method\":\"query\",\"type\":\"entities\",\"project\":\"${PROJECT}\"}")
check "reinforced entity reappears in default query_entities results" "$resp" "reinforce_ipc_entity"

resp=$(send "{\"method\":\"reinforce\",\"kind\":\"bogus\",\"id\":${EID}}")
check "unknown kind is rejected" "$resp" '"error"'

resp=$(send "{\"method\":\"reinforce\",\"kind\":\"entity\",\"id\":999999999}")
check "nonexistent id is reported as an error" "$resp" '"error"'

resp=$(send "{\"method\":\"reinforce\",\"kind\":\"entity\"}")
check "missing id is reported as an error" "$resp" '"error"'

resp=$(send "{\"method\":\"reinforce\",\"id\":${EID}}")
check "missing kind is reported as an error" "$resp" '"error"'

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
