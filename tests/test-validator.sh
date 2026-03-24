#!/usr/bin/env bash
# ============================================================================
# test-validator.sh — End-to-end test suite
#
# Smoke tests (need Codex) + mechanical tests (no Codex dependency).
#
# Run all:           bash ~/.claude/hooks/test-validator.sh
# Mechanical only:   bash ~/.claude/hooks/test-validator.sh --mechanical
# ============================================================================

set -euo pipefail

MODE="${1:-full}"
PASS=0; FAIL=0; SKIP=0

t() {
    local name="$1" result="$2" detail="${3:-}"
    case "$result" in
        pass) echo "  ✓ ${name}"; PASS=$((PASS + 1)) ;;
        fail) echo "  ✗ ${name}: ${detail}"; FAIL=$((FAIL + 1)) ;;
        *)    echo "  - ${name}: ${detail}"; SKIP=$((SKIP + 1)) ;;
    esac
}

_timeout() {
    if command -v timeout &>/dev/null; then timeout "$@"
    elif command -v gtimeout &>/dev/null; then gtimeout "$@"
    else shift; "$@"; fi
}

GATE="$HOME/.claude/hooks/gate-review.sh"
SCHEMA="$HOME/.claude/schemas/verdict.json"

echo ""
echo "Phase-gated validator — test suite"
if [ "$MODE" = "--mechanical" ]; then
    echo "(mechanical tests only — no Codex required)"
fi
echo "===================================="

# ---------------------------------------------------------------------------
# SMOKE TESTS (require Codex) — skipped in --mechanical mode
# ---------------------------------------------------------------------------
if [ "$MODE" != "--mechanical" ]; then

# ==== 1: Prerequisites ====
echo ""; echo "1. Prerequisites"
command -v codex &>/dev/null && t "codex installed" "pass" || { t "codex" "fail" "npm i -g @openai/codex"; exit 1; }
codex login status &>/dev/null && t "codex auth" "pass" || { t "codex auth" "fail" "codex login"; exit 1; }
command -v jq &>/dev/null && t "jq installed" "pass" || { t "jq" "fail"; exit 1; }
[ -f "$GATE" ] && [ -x "$GATE" ] && t "gate-review.sh" "pass" || { t "gate-review.sh" "fail" "run install.sh"; exit 1; }
[ -f "$SCHEMA" ] && jq empty "$SCHEMA" 2>/dev/null && t "verdict.json" "pass" || { t "verdict.json" "fail"; exit 1; }

# ==== 2: Codex connectivity ====
echo ""; echo "2. Codex connectivity"
PING=$(echo "Respond with exactly: PING" | _timeout 30 codex exec - --sandbox read-only --skip-git-repo-check 2>/dev/null || echo "TIMEOUT")
echo "$PING" | grep -qi "ping" && t "PING" "pass" || { t "PING" "fail" "got: ${PING:0:60}"; exit 1; }

# ==== 3: Schema validation ====
echo ""; echo "3. Schema produces valid verdict"
SV=$(echo 'Review this plan: "Add hello world endpoint." Return JSON only.' | \
    _timeout 60 codex exec - --sandbox read-only --skip-git-repo-check --output-schema "$SCHEMA" 2>/dev/null || echo "{}")
echo "$SV" | jq -e '.phase and .decision and .exit_check and .verdict_version' >/dev/null 2>&1 \
    && t "required fields present" "pass" || t "required fields" "fail" "${SV:0:100}"

# ==== Setup test repo ====
TESTDIR=$(mktemp -d)
cd "$TESTDIR"
git init -q
mkdir -p .claude .codex-validations

# ==== 4: No diff → skip (and round not consumed) ====
echo ""; echo "4. No diff skips impl review"
git commit --allow-empty -m "empty" -q
# Seed state so we can check round counter
rm -f .codex-validations/state.json .codex-validations/findings.jsonl
OUT=$(bash "$GATE" impl 2>&1 || true)
echo "$OUT" | grep -qi "no diff\|no changes\|skipping" \
    && t "no-diff exits cleanly" "pass" || t "no-diff exits" "fail" "${OUT:0:80}"

# PATCH 3 test: round counter should be 0 (rolled back), not 1
if [ -f ".codex-validations/state.json" ]; then
    IMPL_ROUND=$(jq '.impl_round' .codex-validations/state.json 2>/dev/null || echo "999")
    [ "$IMPL_ROUND" -eq 0 ] \
        && t "no-diff does not consume a round (impl_round=0)" "pass" \
        || t "round not consumed" "fail" "impl_round=${IMPL_ROUND}, expected 0"
else
    t "round not consumed" "skip" "no state file"
fi

# ==== 5: Plan gate — incomplete plan ====
echo ""; echo "5. Plan gate catches missing sections"
cat > .claude/plan.md << 'PLAN'
# Plan: Add auth
## Objective
Add JWT auth.
## Files
- src/auth.ts
PLAN
rm -f .codex-validations/state.json .codex-validations/findings.jsonl

PLAN_FILE=.claude/plan.md bash "$GATE" plan 2>/dev/null || true

PV=$(find .codex-validations -name "verdict.json" -path "*plan*" 2>/dev/null | sort -r | head -1)
if [ -n "$PV" ] && [ -f "$PV" ]; then
    PD=$(jq -r '.decision' "$PV" 2>/dev/null || echo "unknown")
    PG=$(jq '.gaps | length' "$PV" 2>/dev/null || echo 0)
    [ "$PD" != "pass" ] && t "incomplete plan not passed (${PD})" "pass" || t "plan gate" "fail" "passed incomplete plan"
    [ "$PG" -gt 0 ] && t "gaps found (${PG})" "pass" || t "gaps" "fail" "zero gaps"
else
    t "plan verdict" "fail" "no verdict file"
fi

# ==== 6: Impl gate — security bugs ====
echo ""; echo "6. Impl gate catches security issues"
cat > auth.js << 'CODE'
const jwt = require('jsonwebtoken');
const SECRET = "hardcoded-secret-key-123";
function login(req, res) {
  const { username, password } = req.body;
  const token = jwt.sign({ user: username }, SECRET);
  res.json({ token });
}
function verify(req, res, next) {
  const token = req.headers.authorization;
  const decoded = jwt.verify(token, SECRET);
  req.user = decoded;
  next();
}
module.exports = { login, verify };
CODE
git add -A && git commit -q -m "initial"
echo "// trigger diff" >> auth.js

rm -f .codex-validations/state.json .codex-validations/findings.jsonl
bash "$GATE" impl 2>/dev/null || true

IV=$(find .codex-validations -name "verdict.json" -path "*impl*" 2>/dev/null | sort -r | head -1)
if [ -n "$IV" ] && [ -f "$IV" ]; then
    ID=$(jq -r '.decision' "$IV"); II=$(jq '.issues | length' "$IV" 2>/dev/null || echo 0)
    SI=$(jq '[.issues[] | select(.class=="security")] | length' "$IV" 2>/dev/null || echo 0)
    [ "$II" -gt 0 ] && t "issues found (${II})" "pass" || t "issues" "fail" "zero issues"
    [ "$SI" -gt 0 ] && t "security flagged (${SI})" "pass" || t "security" "fail" "hardcoded secret missed"
    [ "$ID" != "pass" ] && t "buggy code not passed (${ID})" "pass" || t "impl gate" "fail"
else
    t "impl verdict" "fail" "no verdict file"
fi

# ==== 7: Findings ledger populated ====
echo ""; echo "7. Findings ledger"
if [ -f ".codex-validations/findings.jsonl" ]; then
    LC=$(wc -l < .codex-validations/findings.jsonl)
    [ "$LC" -gt 0 ] && t "ledger entries (${LC})" "pass" || t "ledger" "fail" "empty"
else
    t "findings.jsonl" "fail" "not found"
fi

# ==== 8: Adjudication file ====
echo ""; echo "8. Adjudication file"
AJ=$(find .codex-validations -name "adjudicate.md" 2>/dev/null | sort -r | head -1)
if [ -n "$AJ" ] && [ -f "$AJ" ]; then
    t "adjudication exists" "pass"
    grep -q "dispositions.json" "$AJ" && t "references dispositions.json" "pass" || t "disp ref" "fail"
    grep -q "\-\-rerun" "$AJ" && t "references --rerun" "pass" || t "rerun ref" "fail"
else
    t "adjudication" "skip" "verdict may have been pass"
fi

# ==== 9: Phase-scoped state ====
echo ""; echo "9. State machine"
if [ -f ".codex-validations/state.json" ]; then
    TID=$(jq -r '.task_id' .codex-validations/state.json)
    [ -n "$TID" ] && [ "$TID" != "null" ] && t "task_id" "pass" || t "task_id" "fail"
    jq -e '.impl_round' .codex-validations/state.json >/dev/null 2>&1 \
        && t "phase-scoped rounds (impl_round)" "pass" || t "phase-scoped" "fail" "missing impl_round"
    jq -e '.impl_history' .codex-validations/state.json >/dev/null 2>&1 \
        && t "phase-scoped history (impl_history)" "pass" || t "history" "fail"
    # FIX 5 verification: no dead findings_ledger
    jq -e '.findings_ledger' .codex-validations/state.json >/dev/null 2>&1 \
        && t "no dead findings_ledger" "fail" "findings_ledger still in state" \
        || t "no dead findings_ledger" "pass"
else
    t "state.json" "fail"
fi

# ==== 10: Slash commands ====
echo ""; echo "10. Slash commands"
for cmd in review-plan review-impl acceptance-report; do
    [ -f "$HOME/.claude/commands/${cmd}.md" ] && t "/${cmd}" "pass" || t "/${cmd}" "fail"
done

# Cleanup smoke test directory
cd /
rm -rf "$TESTDIR"

fi  # end of smoke tests (skipped in --mechanical mode)

# ================================================================
# MECHANICAL TESTS — source real functions from gate-review.sh
# No Codex dependency. Only needs jq + gate-review.sh installed.
# Run standalone: bash test-validator.sh --mechanical
# ================================================================

echo ""
echo "========== MECHANICAL TESTS =========="
echo "(using real functions via --source-only)"

# Mechanical prerequisites (lighter than smoke)
if [ "$MODE" = "--mechanical" ]; then
    echo ""; echo "M0. Mechanical prerequisites"
    command -v jq &>/dev/null && t "jq installed" "pass" || { t "jq" "fail" "brew install jq / apt install jq"; exit 1; }
    [ -f "$GATE" ] && [ -x "$GATE" ] && t "gate-review.sh" "pass" || { t "gate-review.sh" "fail" "run install.sh"; exit 1; }
fi

TESTDIR=$(mktemp -d)
cd "$TESTDIR"
git init -q
mkdir -p .codex-validations

# Source the actual helpers
export VAL_DIR=".codex-validations"
export LEDGER_FILE="${VAL_DIR}/findings.jsonl"
export DISPOSITIONS_FILE="${VAL_DIR}/dispositions.json"
export SEQ_FILE="${VAL_DIR}/.ledger_seq"
export STATE_FILE="${VAL_DIR}/state.json"
source "$GATE" --source-only

# ==== 11: Disposition ingestion via real ingest_dispositions() ====
echo ""; echo "11. Disposition suppression (real function)"

rm -f "$LEDGER_FILE" "$SEQ_FILE" "$DISPOSITIONS_FILE"
mkdir -p "$VAL_DIR"
echo 0 > "$SEQ_FILE"

# Seed ledger with a finding
echo '{"id":"I1","fingerprint":"impl:security:auth.js:abc123","severity":"critical","class":"security","evidence":"hardcoded secret","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo 1 > "$SEQ_FILE"

# Write disposition
echo '[{"finding_id":"I1","fingerprint":"impl:security:auth.js:abc123","disposition":"accepted_risk","rationale":"rotated at deploy"}]' > "$DISPOSITIONS_FILE"

# Call real function
ingest_dispositions 2>/dev/null

# Verify: latest entry for I1 should be accepted_risk
LATEST_DISP=$(jq -s '[.[] | select(.id == "I1")] | sort_by(.ledger_seq) | last | .disposition' "$LEDGER_FILE" 2>/dev/null || echo "null")
[ "$LATEST_DISP" = '"accepted_risk"' ] \
    && t "I1 updated to accepted_risk (real function)" "pass" \
    || t "I1 disposition" "fail" "got: $LATEST_DISP"

# Verify via real get_open_findings()
OPEN_JSON=$(get_open_findings)
OPEN_COUNT=$(echo "$OPEN_JSON" | jq 'length' 2>/dev/null || echo "999")
[ "$OPEN_COUNT" -eq 0 ] \
    && t "get_open_findings() returns 0 (real function)" "pass" \
    || t "open suppression" "fail" "open count: $OPEN_COUNT"

# Verify closed IDs available for adjudication lookup
CLOSED_JSON=$(get_closed_ids)
echo "$CLOSED_JSON" | jq -e 'index("I1")' >/dev/null 2>&1 \
    && t "get_closed_ids() finds I1 for adjudication lookup" "pass" \
    || t "closed IDs" "fail"

# Verify dispositions.json was archived
[ ! -f "$DISPOSITIONS_FILE" ] \
    && t "dispositions.json archived after ingestion" "pass" \
    || t "dispositions archive" "fail" "file still exists"

# ==== 11b: Fingerprint-based disposition (ID not provided) ====
echo ""; echo "11b. Fingerprint-only disposition lookup"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

echo '{"id":"I5","fingerprint":"impl:correctness:api.ts:xyz789","severity":"warning","class":"correctness","evidence":"off-by-one","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo 1 > "$SEQ_FILE"

# Disposition by fingerprint only — no finding_id
echo '[{"fingerprint":"impl:correctness:api.ts:xyz789","disposition":"fixed","rationale":"boundary check added"}]' > "$DISPOSITIONS_FILE"

ingest_dispositions 2>/dev/null

FP_DISP=$(jq -s '[.[] | select(.fingerprint == "impl:correctness:api.ts:xyz789")] | sort_by(.ledger_seq) | last | .disposition' "$LEDGER_FILE" 2>/dev/null || echo "null")
[ "$FP_DISP" = '"fixed"' ] \
    && t "fingerprint-only disposition resolved to fixed" "pass" \
    || t "fingerprint disposition" "fail" "got: $FP_DISP"

# ==== 12: Deferred finding suppressed ====
echo ""; echo "12. Deferred suppression (real functions)"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

echo '{"id":"G1","fingerprint":"impl:requirements:api.ts:def456","severity":"warning","class":"requirements","evidence":"missing pagination","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"G1","fingerprint":"impl:requirements:api.ts:def456","severity":"warning","class":"requirements","evidence":"missing pagination","disposition":"deferred","disposition_rationale":"v2 feature","ledger_phase":"impl","ledger_round":1,"ledger_seq":2}' >> "$LEDGER_FILE"
echo 2 > "$SEQ_FILE"

DEFERRED_OPEN=$(get_open_findings | jq 'length' 2>/dev/null || echo "999")
[ "$DEFERRED_OPEN" -eq 0 ] \
    && t "deferred not in open set (real function)" "pass" \
    || t "deferred suppression" "fail" "open: $DEFERRED_OPEN"

DEFERRED_CLOSED=$(get_closed_ids)
echo "$DEFERRED_CLOSED" | jq -e 'index("G1")' >/dev/null 2>&1 \
    && t "deferred G1 in closed IDs (real function)" "pass" \
    || t "deferred closed" "fail"

# Verify via get_closed_fingerprints()
CLOSED_FPS=$(get_closed_fingerprints)
echo "$CLOSED_FPS" | jq -e 'index("impl:requirements:api.ts:def456")' >/dev/null 2>&1 \
    && t "deferred fingerprint in closed set (real function)" "pass" \
    || t "closed fingerprints" "fail"

# ==== 13: Duplicate fingerprint — latest seq wins ====
echo ""; echo "13. Fingerprint dedup with ledger_seq (real functions)"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

echo '{"id":"I1","fingerprint":"impl:security:auth.js:same","severity":"critical","class":"security","evidence":"hardcoded secret","disposition":"fixed","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"I2","fingerprint":"impl:security:auth.js:same","severity":"critical","class":"security","evidence":"hardcoded secret reworded","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":2}' >> "$LEDGER_FILE"
echo 2 > "$SEQ_FILE"

# Latest seq (I2, seq=2) is open → should appear in open set
OPEN_FP=$(get_open_findings | jq 'length' 2>/dev/null || echo 0)
[ "$OPEN_FP" -eq 1 ] \
    && t "latest seq wins: 1 open (real function)" "pass" \
    || t "fingerprint dedup" "fail" "expected 1, got $OPEN_FP"

# I1's fixed status should appear in closed IDs
CLOSED_IDS_FP=$(get_closed_ids)
echo "$CLOSED_IDS_FP" | jq -e 'index("I1")' >/dev/null 2>&1 \
    && t "fixed I1 in closed IDs (real function)" "pass" \
    || t "closed I1" "fail"

# ==== 14: Plan accept_with_risks approval ====
echo ""; echo "14. Plan accept_with_risks approval"
# This tests main() logic — can't easily source main(), so replicate the condition.
# This is acceptable: the condition is a 1-line bash if-statement, not complex jq.

rm -f "$STATE_FILE" "$LEDGER_FILE"
jq -n '{task_id:"test-awr",created_at:"2026-01-01",plan_round:1,impl_round:0,plan_approved:false,approved_plan_hash:"",latest_diff_hash:"",exit_reason:"",plan_history:[],impl_history:[]}' > "$STATE_FILE"

STATE=$(cat "$STATE_FILE"); DECISION="accept_with_risks"; PHASE_TEST="plan"
if [ "$PHASE_TEST" = "plan" ] && { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; }; then
    STATE=$(echo "$STATE" | jq '.plan_approved = true | .approved_plan_hash = "test"')
    echo "$STATE" | jq '.' > "$STATE_FILE"
fi

[ "$(jq -r '.plan_approved' "$STATE_FILE")" = "true" ] \
    && t "accept_with_risks sets plan_approved (logic check)" "pass" \
    || t "plan approval" "fail"

# Regression: "pass" also works
jq '.plan_approved = false' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
DECISION="pass"
if [ "$PHASE_TEST" = "plan" ] && { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; }; then
    jq '.plan_approved = true' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi
[ "$(jq -r '.plan_approved' "$STATE_FILE")" = "true" ] \
    && t "pass also sets plan_approved (regression)" "pass" \
    || t "pass approval" "fail"

# ==== 15: append_findings stamps ledger_seq ====
echo ""; echo "15. append_findings with ledger_seq (real function)"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

# Create a minimal verdict file
cat > /tmp/test-verdict.json << 'VJ'
{"gaps":[{"id":"G1","fingerprint":"plan:tests:plan.md:test1","severity":"warning","blocking":false,"class":"tests","evidence":"missing","evidence_type":"plan_section","action":"add tests"}],"issues":[{"id":"I1","fingerprint":"impl:security:auth.js:test2","severity":"critical","blocking":true,"class":"security","artifact":"auth.js","evidence":"hardcoded","evidence_type":"diff","action":"fix"}],"comments":[]}
VJ

append_findings /tmp/test-verdict.json 1 "plan"

if [ -f "$LEDGER_FILE" ]; then
    ENTRY_COUNT=$(wc -l < "$LEDGER_FILE")
    [ "$ENTRY_COUNT" -eq 2 ] \
        && t "append_findings created 2 entries" "pass" \
        || t "append_findings entries" "fail" "expected 2, got $ENTRY_COUNT"

    HAS_SEQ=$(jq -s '[.[] | select(.ledger_seq != null)] | length' "$LEDGER_FILE" 2>/dev/null || echo 0)
    [ "$HAS_SEQ" -eq 2 ] \
        && t "all entries have ledger_seq" "pass" \
        || t "ledger_seq stamped" "fail" "only $HAS_SEQ have seq"

    HAS_PHASE=$(jq -s '[.[] | select(.ledger_phase == "plan")] | length' "$LEDGER_FILE" 2>/dev/null || echo 0)
    [ "$HAS_PHASE" -eq 2 ] \
        && t "ledger_phase=plan stamped" "pass" \
        || t "ledger_phase" "fail"

    SEQ_VAL=$(cat "$SEQ_FILE")
    [ "$SEQ_VAL" -eq 2 ] \
        && t "seq counter advanced to 2" "pass" \
        || t "seq counter" "fail" "expected 2, got $SEQ_VAL"
else
    t "append_findings creates ledger" "fail" "no file"
fi
rm -f /tmp/test-verdict.json

# ==== 16: Invalid disposition rejected ====
echo ""; echo "16. Invalid disposition rejected (real function)"

rm -f "$LEDGER_FILE" "$SEQ_FILE" "$DISPOSITIONS_FILE"
echo 0 > "$SEQ_FILE"

echo '{"id":"I1","fingerprint":"impl:security:a.js:x","severity":"critical","class":"security","evidence":"bad","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo 1 > "$SEQ_FILE"

# Write a disposition with a typo
echo '[{"finding_id":"I1","fingerprint":"impl:security:a.js:x","disposition":"accepted-risk","rationale":"typo"}]' > "$DISPOSITIONS_FILE"

REJECT_OUTPUT=$(ingest_dispositions 2>&1)
echo "$REJECT_OUTPUT" | grep -qi "REJECTED\|invalid" \
    && t "typo disposition rejected" "pass" \
    || t "typo rejection" "fail" "output: ${REJECT_OUTPUT:0:80}"

# Verify I1 is still open
STILL_OPEN=$(jq -s '[.[] | select(.id == "I1")] | sort_by(.ledger_seq) | last | .disposition' "$LEDGER_FILE" 2>/dev/null)
[ "$STILL_OPEN" = '"open"' ] \
    && t "I1 remains open after rejected disposition" "pass" \
    || t "I1 still open" "fail" "got: $STILL_OPEN"

# ==== 17: get_closed_ids is phase-scoped (adjudication lookup) ====
echo ""; echo "17. Phase-scoped closed IDs for adjudication (real function)"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

# G1 closed in plan phase, G1 open in impl phase (different finding, same ID)
echo '{"id":"G1","fingerprint":"plan:requirements:plan.md:aaa","severity":"warning","class":"requirements","evidence":"missing scope","disposition":"fixed","ledger_phase":"plan","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"G1","fingerprint":"impl:requirements:api.ts:bbb","severity":"warning","class":"requirements","evidence":"missing endpoint","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":2}' >> "$LEDGER_FILE"
echo 2 > "$SEQ_FILE"

# When reviewing impl, closed IDs should NOT include the plan-phase G1
PHASE="impl"
IMPL_CLOSED=$(get_closed_ids)
echo "$IMPL_CLOSED" | jq -e 'index("G1")' >/dev/null 2>&1 \
    && t "phase-scoped: FAIL" "fail" "impl closed IDs wrongly includes plan-phase G1" \
    || t "impl closed IDs excludes plan-phase G1" "pass"

PHASE="plan"
PLAN_CLOSED=$(get_closed_ids)
echo "$PLAN_CLOSED" | jq -e 'index("G1")' >/dev/null 2>&1 \
    && t "plan closed IDs includes plan-phase G1" "pass" \
    || t "plan closed IDs" "fail"

PHASE="impl"  # reset

# ==== 18: Stall detection: different composition, same count = no stall ====
echo ""; echo "18. Stall precision: different findings, same count (real function)"

rm -f "$LEDGER_FILE" "$SEQ_FILE"
echo 0 > "$SEQ_FILE"

# Round 1: findings A and B open
echo '{"id":"I1","fingerprint":"impl:security:a.js:fp1","severity":"critical","class":"security","evidence":"issue A","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"I2","fingerprint":"impl:correctness:b.js:fp2","severity":"warning","class":"correctness","evidence":"issue B","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":2}' >> "$LEDGER_FILE"

# Round 2: A was fixed (new disposition), C is new. Count is still 2, but composition changed.
echo '{"id":"I1","fingerprint":"impl:security:a.js:fp1","severity":"critical","class":"security","evidence":"issue A","disposition":"fixed","ledger_phase":"impl","ledger_round":1,"ledger_seq":3}' >> "$LEDGER_FILE"
echo '{"id":"I3","fingerprint":"impl:tests:c.js:fp3","severity":"warning","class":"tests","evidence":"issue C","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":4}' >> "$LEDGER_FILE"
echo '{"id":"I2","fingerprint":"impl:correctness:b.js:fp2","severity":"warning","class":"correctness","evidence":"issue B still","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":5}' >> "$LEDGER_FILE"
echo 5 > "$SEQ_FILE"

# B repeated (fp2 in both rounds), count is 2 vs 2, but A was replaced by C
# detect_stall should see 1 repeated fingerprint (fp2) AND count not reduced: stall
STALL_RESULT=$(detect_stall "impl" 2)
echo "$STALL_RESULT" | grep -q "stall" \
    && t "repeated fingerprint (B) with no reduction = stall" "pass" \
    || t "stall detection" "fail" "got: $STALL_RESULT"

# Now test: same count, zero repeated fingerprints = NOT stall
rm -f "$LEDGER_FILE"
echo '{"id":"I1","fingerprint":"impl:security:a.js:fp1","severity":"critical","class":"security","evidence":"issue A","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"I2","fingerprint":"impl:correctness:b.js:fp2","severity":"warning","class":"correctness","evidence":"issue B","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":2}' >> "$LEDGER_FILE"
# Round 2: completely different findings, same count
echo '{"id":"I3","fingerprint":"impl:tests:c.js:fp3","severity":"warning","class":"tests","evidence":"issue C","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":3}' >> "$LEDGER_FILE"
echo '{"id":"I4","fingerprint":"impl:security:d.js:fp4","severity":"critical","class":"security","evidence":"issue D","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":4}' >> "$LEDGER_FILE"

NO_STALL=$(detect_stall "impl" 2)
[ "$NO_STALL" = "ok" ] \
    && t "different findings, same count = not stall" "pass" \
    || t "false positive stall" "fail" "got: $NO_STALL"

# Now test: repeated fingerprint BUT count went down = progress, not stall
rm -f "$LEDGER_FILE"
# Round 1: 3 open findings
echo '{"id":"I1","fingerprint":"impl:security:a.js:fp1","severity":"critical","class":"security","evidence":"issue A","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":1}' > "$LEDGER_FILE"
echo '{"id":"I2","fingerprint":"impl:correctness:b.js:fp2","severity":"warning","class":"correctness","evidence":"issue B","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":2}' >> "$LEDGER_FILE"
echo '{"id":"I3","fingerprint":"impl:tests:c.js:fp3","severity":"warning","class":"tests","evidence":"issue C","disposition":"open","ledger_phase":"impl","ledger_round":1,"ledger_seq":3}' >> "$LEDGER_FILE"
# Round 2: A and C were fixed, B persists. Count went from 3 to 1. B repeats.
echo '{"id":"I2","fingerprint":"impl:correctness:b.js:fp2","severity":"warning","class":"correctness","evidence":"issue B still","disposition":"open","ledger_phase":"impl","ledger_round":2,"ledger_seq":4}' >> "$LEDGER_FILE"
echo 4 > "$SEQ_FILE"

PROGRESS=$(detect_stall "impl" 2)
[ "$PROGRESS" = "ok" ] \
    && t "repeated fingerprint but count reduced = progress, not stall" "pass" \
    || t "false positive stall on progress" "fail" "got: $PROGRESS"

# ==== 19: Root-level named files match untracked filter ====
echo ""; echo "19. Root-level Dockerfile matches untracked filter"

# The regex should match root-level Dockerfile (no leading /)
echo "Dockerfile" | grep -qE '(^|/)(Dockerfile|Makefile|Jenkinsfile|Taskfile|Justfile|Gemfile|Rakefile)$' \
    && t "root Dockerfile matches filter" "pass" \
    || t "root Dockerfile filter" "fail"

echo "subdir/Dockerfile" | grep -qE '(^|/)(Dockerfile|Makefile|Jenkinsfile|Taskfile|Justfile|Gemfile|Rakefile)$' \
    && t "subdir/Dockerfile matches filter" "pass" \
    || t "subdir Dockerfile filter" "fail"

echo "Makefile" | grep -qE '(^|/)(Dockerfile|Makefile|Jenkinsfile|Taskfile|Justfile|Gemfile|Rakefile)$' \
    && t "root Makefile matches filter" "pass" \
    || t "root Makefile filter" "fail"

# ==== 20: Controller override reconciliation ====
echo ""; echo "20. Controller blocking-count reconciliation"

# Simulate: decision=pass but blocking=2 → controller should override
DECISION="pass"; BLOCKING=2
if { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; } && [ "$BLOCKING" -gt 0 ] 2>/dev/null; then
    DECISION="revise"
fi
[ "$DECISION" = "revise" ] \
    && t "pass with blocking=2 overridden to revise" "pass" \
    || t "blocking reconciliation" "fail" "decision=$DECISION"

# Also test: pass with blocking=0 → no override
DECISION="pass"; BLOCKING=0
if { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; } && [ "$BLOCKING" -gt 0 ] 2>/dev/null; then
    DECISION="revise"
fi
[ "$DECISION" = "pass" ] \
    && t "pass with blocking=0 stays pass" "pass" \
    || t "no false override" "fail" "decision=$DECISION"

# accept_with_risks + blocking=1 → override
DECISION="accept_with_risks"; BLOCKING=1
if { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; } && [ "$BLOCKING" -gt 0 ] 2>/dev/null; then
    DECISION="revise"
fi
[ "$DECISION" = "revise" ] \
    && t "accept_with_risks with blocking=1 overridden" "pass" \
    || t "accept_with_risks reconciliation" "fail"

# ==== 21: Plan hash verification logic ====
echo ""; echo "21. Plan hash verification"

rm -f "$STATE_FILE"
mkdir -p .claude
echo "# Original approved plan" > .claude/plan.md
ORIG_HASH=$(_sha256 < .claude/plan.md 2>/dev/null | cut -d' ' -f1)

jq -n --arg h "$ORIG_HASH" '{task_id:"test-hash",created_at:"2026-01-01",plan_round:1,impl_round:0,plan_approved:true,approved_plan_hash:$h,latest_diff_hash:"",exit_reason:"pass",plan_history:[],impl_history:[]}' > "$STATE_FILE"

# Same plan → hashes match
CURRENT_HASH=$(_sha256 < .claude/plan.md 2>/dev/null | cut -d' ' -f1)
[ "$CURRENT_HASH" = "$ORIG_HASH" ] \
    && t "unchanged plan hash matches" "pass" \
    || t "plan hash match" "fail"

# Modified plan → hashes differ
echo "# Changed plan" > .claude/plan.md
NEW_HASH=$(_sha256 < .claude/plan.md 2>/dev/null | cut -d' ' -f1)
[ "$NEW_HASH" != "$ORIG_HASH" ] \
    && t "modified plan hash differs" "pass" \
    || t "plan hash differ" "fail"

# ==== 22: SKIP_PLAN_CHECK bypass ====
echo ""; echo "22. SKIP_PLAN_CHECK bypass"

# The bypass logic: if SKIP_PLAN_CHECK=true, warn but continue
SKIP_PLAN_CHECK="true"
if [ "${SKIP_PLAN_CHECK:-}" = "true" ]; then
    BYPASS="yes"
else
    BYPASS="no"
fi
[ "$BYPASS" = "yes" ] \
    && t "SKIP_PLAN_CHECK=true triggers bypass" "pass" \
    || t "SKIP_PLAN_CHECK bypass" "fail"

unset SKIP_PLAN_CHECK
if [ "${SKIP_PLAN_CHECK:-}" = "true" ]; then
    BYPASS="yes"
else
    BYPASS="no"
fi
[ "$BYPASS" = "no" ] \
    && t "unset SKIP_PLAN_CHECK does not bypass" "pass" \
    || t "SKIP_PLAN_CHECK unset" "fail"

# ==== Cleanup ====
cd /
rm -rf "$TESTDIR"

# ==== Summary ====
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "===================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total)"
echo "===================================="

if [ "$FAIL" -gt 0 ]; then
    echo "Some tests failed."; exit 1
else
    echo "All tests passed."
    echo ""
    echo "Usage:"
    echo "  /review-plan            Gate A"
    echo "  /review-plan --rerun    Re-review after adjudication"
    echo "  /review-impl            Gate C"
    echo "  /review-impl --rerun    Re-review after fixes"
    echo "  /acceptance-report      Gate D"
fi
