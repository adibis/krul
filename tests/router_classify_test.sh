#!/usr/bin/env bash
# router_classify_test.sh — integration test for router.classify IPC method.
# Requires kruld to be running with gears loaded.
# Usage: ./tests/router_classify_test.sh
set -euo pipefail

SOCK="${KRUL_SOCK:-/tmp/krul.sock}"
PASS=0
FAIL=0

classify() {
    local query="$1"
    printf '{"method":"router.classify","q":"%s"}' "$query" | nc -U "$SOCK" 2>/dev/null
}

check() {
    local desc="$1"
    local query="$2"
    local want_route="$3"
    local want_extra="${4:-}"          # optional: substring that must appear in response

    local resp
    resp=$(classify "$query")

    local ok=1
    if ! echo "$resp" | grep -q "\"route\":\"${want_route}\""; then
        ok=0
    fi
    if [[ -n "$want_extra" ]] && ! echo "$resp" | grep -q "$want_extra"; then
        ok=0
    fi

    if [[ $ok -eq 1 ]]; then
        printf "  PASS  %s\n" "$desc"
        PASS=$(( PASS + 1 ))
    else
        printf "  FAIL  %s\n" "$desc"
        printf "        query : %s\n" "$query"
        printf "        want  : route=%s%s\n" "$want_route" "${want_extra:+, contains=$want_extra}"
        printf "        got   : %s\n" "$resp"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== router.classify — 20-query test suite ==="
echo

# ── Tier 1: structural — entity list (5) ─────────────────────────────────────
echo "-- structural / entities --"
check "list all UVM agents"          "list all UVM agents"          "structural" "entities"
check "show all modules"             "show all modules"             "structural" "entities"
check "how many covergroups exist"   "how many covergroups exist"   "structural" "entities"
check "which agents have drivers"    "which agents have drivers"    "structural" "entities"
check "find all drivers in the env"  "find all drivers in the env"  "structural" "entities"

# ── Tier 1: structural — coverage gap (2) ────────────────────────────────────
echo
echo "-- structural / no_covergroup --"
check "which modules have no covergroup"   "which modules have no covergroup"   "structural" "no_covergroup"
check "list agents with missing covergroup" "list agents with missing covergroup" "structural" "no_covergroup"

# ── Tier 1: structural — relations (1) ───────────────────────────────────────
echo
echo "-- structural / relations --"
check "show relations for axi_agent"  "show relations for axi_agent"  "structural" "relations"

# ── Tier 2: gear trigger match (4 gears × 1 query each) ──────────────────────
echo
echo "-- gear trigger match --"
check "triage the nightly regression"          "triage the nightly regression"          "gear" "triage"
check "close coverage on the AXI agent"        "close coverage on the AXI agent"        "gear" "close_coverage"
check "simulate the uart smoke test"           "simulate the uart smoke test"           "gear" "simulate"
check "debug why the DMA driver is failing"    "debug why the DMA driver is failing"    "gear" "debug"

# ── Tier 3 fallback: embedding_needed (5) ────────────────────────────────────
echo
echo "-- embedding_needed fallback --"
check "what is the handshake protocol"         "what is the handshake protocol"         "embedding_needed"
check "explain the scoreboard architecture"    "explain the scoreboard architecture"    "embedding_needed"
check "why does the monitor lose data"         "why does the monitor lose data"         "embedding_needed"
check "suggest coverage metrics for uart"      "suggest coverage metrics for uart"      "embedding_needed"
check "how should I structure the env class"   "how should I structure the env class"   "embedding_needed"

# ── Edge cases (3) ───────────────────────────────────────────────────────────
echo
echo "-- edge cases --"
check "empty string"                           ""                                       "embedding_needed"
check "all-caps TRIAGE"                        "TRIAGE the failures"                    "gear" "triage"
check "mixed case List All Agents"             "List All Agents"                        "structural" "entities"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
