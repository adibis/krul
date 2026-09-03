#!/usr/bin/env bash
# router_embed_test.sh — tier-3 embedding similarity test.
# Sends paraphrase queries that miss tiers 1 and 2 (no structural keywords,
# no literal trigger words) and verifies they route to the correct gear.
#
# Requirements:
#   - kruld running with gears loaded AND encode-server started
#   - KRUL_MODELS pointing to the models directory (or krul.toml present)
#   - The four built-in gears must be loaded (close_coverage, triage, simulate, debug)
#
# Usage: ./tests/router_embed_test.sh
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
    local want_extra="${4:-}"

    local resp
    resp=$(classify "$query")

    local ok=1
    if ! echo "$resp" | grep -q "\"route\":\"${want_route}\""; then ok=0; fi
    if [[ -n "$want_extra" ]] && ! echo "$resp" | grep -q "$want_extra"; then ok=0; fi

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

echo "=== router tier-3 — embedding similarity (5 paraphrase queries) ==="
echo
echo "Note: these queries contain no literal trigger words."
echo "A PASS means the encoder+cosine path matched the correct gear."
echo

# Each query is a natural-language paraphrase of a gear's purpose.
# Tier 1 will not match (no structural keywords).
# Tier 2 will not match (no literal trigger substrings).
# Tier 3 must match via embedding similarity ≥ 0.70.

check "coverage-gap paraphrase"  \
    "fill remaining coverage holes on the uart agent" \
    "gear" "close_coverage"

check "triage paraphrase"  \
    "figure out why the nightly run has so many assertion failures" \
    "gear" "triage"

check "simulate paraphrase"  \
    "kick off a quick sanity check for the new rtl changes" \
    "gear" "simulate"

check "debug paraphrase — buffer overflow"  \
    "investigate why the receive buffer keeps getting corrupted" \
    "gear" "debug"

check "debug paraphrase — assertion"  \
    "track down what is causing the scoreboard mismatch" \
    "gear" "debug"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Tip: tier-3 failures usually mean the encode-server is not running"
    echo "or the embedding model was not trained on similar phrasing."
    echo "Check 'kruld status' and that KRUL_MODELS is set correctly."
fi

[[ $FAIL -eq 0 ]]
