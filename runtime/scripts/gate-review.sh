#!/usr/bin/env bash
# ============================================================================
# gate-review.sh — Phase-gated Codex verification orchestrator
#
# Runs ONE review round per invocation. No polling.
# Reruns triggered explicitly via --rerun.
#
# Usage:
#   gate-review.sh plan [--rerun]    Gate A: review plan artifact
#   gate-review.sh impl [--rerun]    Gate C: review implementation diff
#
# State: .codex-validations/state.json
# Ledger: .codex-validations/findings.jsonl (append-only)
# Dispositions: .codex-validations/dispositions.json (written by Claude)
# ============================================================================

set -euo pipefail

# FIX 4: Hardcoded installed path — no sed patching needed
SCHEMA_PATH="${HOME}/.claude/schemas/verdict.json"

VAL_DIR=".codex-validations"
STATE_FILE="${VAL_DIR}/state.json"
LEDGER_FILE="${VAL_DIR}/findings.jsonl"
DISPOSITIONS_FILE="${VAL_DIR}/dispositions.json"

CODEX_MODEL="${CODEX_MODEL:-codex-mini-latest}"
TIMEOUT="${TIMEOUT_SECONDS:-90}"
MAX_ROUNDS="${MAX_ROUNDS:-2}"
SEQ_FILE="${VAL_DIR}/.ledger_seq"

# Cross-platform portability
_sha256() {
    if command -v sha256sum &>/dev/null; then sha256sum
    else shasum -a 256; fi
}
_timeout() {
    if command -v timeout &>/dev/null; then timeout "$@"
    elif command -v gtimeout &>/dev/null; then gtimeout "$@"
    else shift; "$@"; fi
}

# =====================================================================
# FIX 5: Removed dead findings_ledger field from state
# FIX 6: Phase-scoped round counters (plan_round / impl_round)
# =====================================================================
init_state() {
    local task_id
    task_id="task-$(date +%Y%m%d%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)"
    jq -n --arg tid "$task_id" --arg ts "$(date -Iseconds)" '{
        task_id: $tid,
        created_at: $ts,
        plan_round: 0,
        impl_round: 0,
        plan_approved: false,
        approved_plan_hash: "",
        latest_diff_hash: "",
        exit_reason: "",
        plan_history: [],
        impl_history: []
    }' > "$STATE_FILE"
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then init_state; fi
    local s; s=$(cat "$STATE_FILE")
    # Migrate: if old format (has current_round), re-init
    if ! echo "$s" | jq -e '.plan_round' >/dev/null 2>&1; then
        init_state; s=$(cat "$STATE_FILE")
    fi
    echo "$s"
}

save_state() { echo "$1" | jq '.' > "$STATE_FILE"; }

# Monotonic sequence for deterministic ledger ordering
next_seq() {
    local seq=0
    if [ -f "$SEQ_FILE" ]; then seq=$(cat "$SEQ_FILE"); fi
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    echo "$seq"
}

# =====================================================================
# Finding ledger
# =====================================================================
append_findings() {
    local verdict_file="$1" round="$2" phase="$3"
    jq -c --arg round "$round" --arg phase "$phase" --arg ts "$(date -Iseconds)" '
        [(.gaps[]?, .issues[]?)] | .[]
        | . + { ledger_phase: $phase, ledger_round: ($round|tonumber), ledger_ts: $ts, disposition: "open" }
    ' "$verdict_file" 2>/dev/null | while IFS= read -r entry; do
        local seq; seq=$(next_seq)
        echo "$entry" | jq -c --argjson s "$seq" '. + {ledger_seq: $s}' >> "$LEDGER_FILE"
    done
}

get_open_findings() {
    if [ ! -f "$LEDGER_FILE" ]; then echo "[]"; return; fi
    jq -s '
        group_by(.fingerprint // .id)
        | map(sort_by(.ledger_seq // .ledger_round) | last)
        | map(select(.disposition == "open"))
    ' "$LEDGER_FILE" 2>/dev/null || echo "[]"
}

get_closed_ids() {
    # NOTE: Retained for adjudication lookup and test verification only.
    # NOT used for Codex suppression (fingerprint-only since v3.2.3).
    if [ ! -f "$LEDGER_FILE" ]; then echo "[]"; return; fi
    # Scoped to current phase to prevent cross-phase ID collisions (G1 in plan != G1 in impl)
    jq -s --arg p "${PHASE:-impl}" '[.[] | select(.disposition != "open" and .ledger_phase == $p) | .id] | unique' "$LEDGER_FILE" 2>/dev/null || echo "[]"
}

get_closed_fingerprints() {
    if [ ! -f "$LEDGER_FILE" ]; then echo "[]"; return; fi
    jq -s '[.[] | select(.disposition != "open") | .fingerprint // empty] | unique' "$LEDGER_FILE" 2>/dev/null || echo "[]"
}

# =====================================================================
# Disposition ingestion
#
# Claude writes .codex-validations/dispositions.json after adjudicating.
# Each entry may include finding_id, fingerprint, or both:
#   {"finding_id":"I1","fingerprint":"impl:security:auth.js:abc","disposition":"fixed","rationale":"..."}
#
# Lookup priority: fingerprint first (durable identity), then finding_id (session-local).
# =====================================================================
ingest_dispositions() {
    if [ ! -f "$DISPOSITIONS_FILE" ]; then return; fi
    if ! jq empty "$DISPOSITIONS_FILE" 2>/dev/null; then
        echo "WARNING: dispositions.json is invalid JSON — skipping." >&2; return
    fi

    local count; count=$(jq 'length' "$DISPOSITIONS_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then return; fi

    echo "Ingesting ${count} disposition(s) into ledger..." >&2

    jq -c '.[]' "$DISPOSITIONS_FILE" | while IFS= read -r disp; do
        local fid fp dval rat
        fid=$(echo "$disp" | jq -r '.finding_id // ""')
        fp=$(echo "$disp" | jq -r '.fingerprint // ""')
        dval=$(echo "$disp" | jq -r '.disposition')
        rat=$(echo "$disp" | jq -r '.rationale // ""')

        # Validate disposition value
        case "$dval" in
            fixed|accepted_risk|deferred|not_applicable|disagree) ;;
            *)
                echo "  REJECTED: ${fp:-$fid} has invalid disposition '${dval}' (allowed: fixed|accepted_risk|deferred|not_applicable|disagree)" >&2
                continue
                ;;
        esac

        local orig=""

        # Prefer fingerprint lookup (durable identity)
        if [ -n "$fp" ] && [ "$fp" != "null" ]; then
            orig=$(jq -s --arg fp "$fp" '[.[] | select(.fingerprint == $fp)] | last // empty' "$LEDGER_FILE" 2>/dev/null)
        fi

        # Fall back to ID lookup (session-local)
        if { [ -z "$orig" ] || [ "$orig" = "null" ]; } && [ -n "$fid" ] && [ "$fid" != "null" ]; then
            orig=$(jq -s --arg fid "$fid" '[.[] | select(.id == $fid)] | last // empty' "$LEDGER_FILE" 2>/dev/null)
        fi

        if [ -n "$orig" ] && [ "$orig" != "null" ] && [ "$orig" != "" ]; then
            local seq; seq=$(next_seq)
            echo "$orig" | jq -c \
                --arg d "$dval" --arg r "$rat" --arg ts "$(date -Iseconds)" --argjson s "$seq" \
                '. + {disposition: $d, disposition_rationale: $r, disposition_ts: $ts, ledger_seq: $s}' \
                >> "$LEDGER_FILE"
            local label="${fp:-$fid}"
            echo "  ${label} -> ${dval}" >&2
        else
            echo "  WARNING: ${fp:-$fid} not in ledger — skipping" >&2
        fi
    done

    mv "$DISPOSITIONS_FILE" "${DISPOSITIONS_FILE}.ingested.$(date +%s)" 2>/dev/null || true
}

# =====================================================================
# FIX 3: Controller-side stall detection
#
# Runs independently of Codex's decision field.
# Returns "stall:reason" or "ok".
# =====================================================================
detect_stall() {
    local phase="$1" current_round="$2"
    local prev=$((current_round - 1))

    if [ "$prev" -lt 1 ]; then echo "ok"; return; fi
    if [ ! -f "$LEDGER_FILE" ]; then echo "ok"; return; fi

    local prev_open curr_open repeated
    prev_open=$(jq -s --arg p "$phase" --argjson r "$prev" \
        '[.[] | select(.ledger_phase==$p and .ledger_round==$r and .disposition=="open")] | length' \
        "$LEDGER_FILE" 2>/dev/null || echo 0)
    curr_open=$(jq -s --arg p "$phase" --argjson r "$current_round" \
        '[.[] | select(.ledger_phase==$p and .ledger_round==$r and .disposition=="open")] | length' \
        "$LEDGER_FILE" 2>/dev/null || echo 0)
    repeated=$(jq -s --arg p "$phase" --argjson pr "$prev" --argjson cr "$current_round" '
        [.[] | select(.ledger_phase==$p and .disposition=="open")]
        | group_by(.fingerprint // .id)
        | map(select( (map(.ledger_round)|unique|sort) as $r | ($r|index($pr))!=null and ($r|index($cr))!=null ))
        | length
    ' "$LEDGER_FILE" 2>/dev/null || echo 0)

    # Stall = same findings persist with no net reduction.
    # If count went down, that is progress even if some findings repeat.
    if [ "$repeated" -gt 0 ] && [ "$curr_open" -ge "$prev_open" ]; then
        echo "stall:repeated_fingerprints_no_reduction:repeated=${repeated}:prev=${prev_open}:curr=${curr_open}"
    else
        echo "ok"
    fi
}

# =====================================================================
# Build review context
# =====================================================================
build_plan_input() {
    local open_findings="$1" round="$2"
    local plan_file="${PLAN_FILE:-.claude/plan.md}"

    echo "## REVIEW PHASE: plan"
    echo "## ROUND: ${round}"
    echo ""
    echo "## PLAN ARTIFACT"
    if [ -f "$plan_file" ]; then cat "$plan_file"; else echo "(No plan at ${plan_file})"; fi
    echo ""
    echo "## PLAN CONTRACT — verify presence and completeness:"
    for s in "Objective" "Scope in / scope out" "Assumptions" "Files/modules to touch" \
             "Invariants" "Test strategy" "Rollback plan" "Acceptance criteria" "Known risks"; do
        echo "- [ ] $s"
    done
    if [ "$open_findings" != "[]" ]; then
        echo ""; echo "## UNRESOLVED FINDINGS FROM PRIOR ROUNDS"
        echo "$open_findings" | jq -r '.[] | "- \(.id) [\(.severity)] [\(.class)]: \(.evidence)"'
    fi
    local closed_fps; closed_fps=$(get_closed_fingerprints)
    if [ "$closed_fps" != "[]" ]; then
        echo ""; echo "## IGNORE THESE FINGERPRINTS (resolved/accepted/deferred)"
        echo "$closed_fps" | jq -r '.[]'
    fi
}

build_impl_input() {
    local open_findings="$1" round="$2"

    echo "## REVIEW PHASE: implementation"
    echo "## ROUND: ${round}"
    echo ""
    if [ -f "${VAL_DIR}/latest-plan/final.json" ]; then
        echo "## APPROVED PLAN SUMMARY"
        jq -r '.summary' "${VAL_DIR}/latest-plan/final.json" 2>/dev/null; echo ""
    fi
    echo "## CHANGED DIFF (review only these changes)"
    local dc sc
    dc=$(git diff 2>/dev/null || echo "")
    sc=$(git diff --cached 2>/dev/null || echo "")
    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|rb|sh|md|json|yaml|yml|toml|sql|c|cpp|h|hpp|proto|tf|hcl|lua|swift|kt|scala|ex|exs|css|scss|html|xml|graphql|prisma)$|(^|/)(Dockerfile|Makefile|Jenkinsfile|Taskfile|Justfile|Gemfile|Rakefile)$' || echo "")
    if [ -z "$dc" ] && [ -z "$sc" ] && [ -z "$untracked" ]; then
        echo "(No changes detected)"; echo ""; echo "## EXIT: No diff to review"; return
    fi
    [ -n "$dc" ] && echo "$dc"
    [ -n "$sc" ] && echo "$sc"
    if [ -n "$untracked" ]; then
        local ut_total; ut_total=$(echo "$untracked" | wc -l)
        local ut_shown=$((ut_total < 10 ? ut_total : 10))
        echo ""; echo "## NEW UNTRACKED FILES (${ut_shown} of ${ut_total} shown, not yet staged)"
        echo "$untracked" | head -10 | while IFS= read -r uf; do
            local uf_lines; uf_lines=$(wc -l < "$uf" 2>/dev/null || echo "0")
            if [ "$uf_lines" -gt 200 ]; then
                echo "--- $uf (first 200 of ${uf_lines} lines) ---"
            else
                echo "--- $uf ---"
            fi
            head -200 "$uf" 2>/dev/null || echo "(unreadable)"; echo ""
        done
        if [ "$ut_total" -gt 10 ]; then
            echo "(... ${ut_total} untracked source files total, $(( ut_total - 10 )) not shown)"
        fi
    fi
    echo ""; echo "## CHANGED PATHS (review ONLY these)"
    { git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; echo "$untracked"; } | sort -u | grep -v '^$'
    echo ""; echo "## TEST EVIDENCE"
    if [ -f "${VAL_DIR}/test-output.txt" ]; then tail -80 "${VAL_DIR}/test-output.txt"
    else echo "(No test evidence)"; fi
    if [ "$open_findings" != "[]" ]; then
        echo ""; echo "## UNRESOLVED FINDINGS"
        echo "$open_findings" | jq -r '.[] | "- \(.id) [\(.severity)] [\(.class)] \(.artifact // ""): \(.evidence)"'
    fi
    local closed_fps; closed_fps=$(get_closed_fingerprints)
    if [ "$closed_fps" != "[]" ]; then
        echo ""; echo "## IGNORE THESE FINGERPRINTS (resolved/accepted/deferred)"
        echo "$closed_fps" | jq -r '.[]'
    fi
}

# =====================================================================
# Prompts
# =====================================================================
PLAN_SYSTEM=$(cat <<'EOF'
You are an independent plan reviewer. You did NOT create this plan.
SCOPE: Review ONLY the plan artifact. Check the plan contract checklist.
ALLOWED classes: requirements, tests, security, correctness, maintainability.
DISALLOWED: implementation details, code style, naming.
RULES:
- Every gap/issue needs fingerprint (phase:class:artifact:short_evidence_hash).
- Every gap/issue needs concrete evidence, not opinion.
- blocking=true ONLY for failures or security issues if plan executes as-is.
- COMMENTS never reopen the loop.
- Do NOT re-raise findings whose fingerprint appears in the IGNORE FINGERPRINTS list.
- Set duplicate_of if re-raising a prior finding with different wording.
- exit_check.open_blocking_count = number of blocking findings.
- decision="pass" if zero blocking. "accept_with_risks" if non-blocking warnings only.
- decision="stall" if same class as prior round with no new evidence.
Respond ONLY with JSON matching the schema. No preamble.
EOF
)

IMPL_SYSTEM=$(cat <<'EOF'
You are an independent code reviewer. You did NOT write this code.
SCOPE: Review ONLY changed diff, test evidence, changed paths. NOT unchanged files.
ALLOWED classes: correctness, security, requirements, tests.
DISALLOWED: architecture (plan phase), style, naming.
RULES:
- Every issue cites a file from CHANGED PATHS.
- Every issue needs fingerprint (phase:class:artifact:short_evidence_hash).
- blocking=true ONLY for failures, security vulnerabilities, or data loss.
- COMMENTS never reopen the loop.
- Do NOT re-raise findings whose fingerprint appears in the IGNORE FINGERPRINTS list.
- Set duplicate_of if re-raising a prior finding with different wording.
- exit_check.open_blocking_count = number of blocking findings.
- decision="pass" if zero blocking. "accept_with_risks" if non-blocking warnings only.
- decision="stall" if same class as prior round with no new evidence.
Respond ONLY with JSON matching the schema. No preamble.
EOF
)

# =====================================================================
# Main execution — wrapped in function for sourceability
# =====================================================================
main() {
    PHASE="${1:-impl}"
    RERUN="${2:-}"

    # Bail conditions
    if [ "${VALIDATION_ENABLED:-true}" = "false" ]; then
        echo "Codex validation disabled." >&2; exit 0
    fi
    if ! command -v codex &>/dev/null; then
        echo "ERROR: codex not found. Install: npm i -g @openai/codex" >&2; exit 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq not found. Install: brew install jq / apt install jq" >&2; exit 1
    fi
    if [ ! -f "$SCHEMA_PATH" ]; then
        echo "ERROR: verdict schema not found at $SCHEMA_PATH — run the installer." >&2; exit 1
    fi

    mkdir -p "$VAL_DIR"

    STATE=$(load_state)

# FIX 6: Phase-scoped counters
ROUND_KEY="${PHASE}_round"
HIST_KEY="${PHASE}_history"

# FIX 1: On rerun, ingest dispositions BEFORE building input
if [ "$RERUN" = "--rerun" ]; then
    ingest_dispositions
fi

ROUND=$(echo "$STATE" | jq ".${ROUND_KEY} + 1")

if [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
    echo "Max rounds ($MAX_ROUNDS) reached for ${PHASE}. Use /acceptance-report." >&2
    STATE=$(echo "$STATE" | jq --arg r "max_rounds_${PHASE}" '.exit_reason = $r')
    save_state "$STATE"; exit 0
fi

if [ "$PHASE" = "impl" ]; then
    PA=$(echo "$STATE" | jq -r '.plan_approved')
    if [ "$PA" != "true" ] && [ ! -f "${VAL_DIR}/latest-plan/final.json" ]; then
        if [ "${SKIP_PLAN_CHECK:-}" = "true" ]; then
            echo "WARNING: No approved plan (SKIP_PLAN_CHECK=true, continuing)." >&2
        else
            echo "ERROR: No approved plan. Run /review-plan first." >&2
            echo "  (Set SKIP_PLAN_CHECK=true to bypass.)" >&2
            exit 1
        fi
    else
        # Verify plan hasn't changed since approval
        APPROVED_HASH=$(echo "$STATE" | jq -r '.approved_plan_hash // ""')
        if [ -n "$APPROVED_HASH" ] && [ "$APPROVED_HASH" != "" ]; then
            local plan_path="${PLAN_FILE:-.claude/plan.md}"
            if [ ! -f "$plan_path" ]; then
                echo "ERROR: Approved plan file missing at ${plan_path}." >&2
                echo "  Plan was approved with hash ${APPROVED_HASH:0:16}... but the file no longer exists." >&2
                if [ "${SKIP_PLAN_CHECK:-}" != "true" ]; then
                    exit 1
                fi
            fi
            CURRENT_HASH=$(_sha256 < "$plan_path" 2>/dev/null | cut -d' ' -f1)
            if [ -z "$CURRENT_HASH" ] || [ "$CURRENT_HASH" != "$APPROVED_HASH" ]; then
                echo "WARNING: Plan file changed since approval (hash mismatch)." >&2
                echo "  Approved: ${APPROVED_HASH:0:16}..." >&2
                echo "  Current:  ${CURRENT_HASH:0:16}..." >&2
                echo "  Run /review-plan to re-approve, or set SKIP_PLAN_CHECK=true." >&2
                if [ "${SKIP_PLAN_CHECK:-}" != "true" ]; then
                    exit 1
                fi
            fi
        fi
    fi
fi

STATE=$(echo "$STATE" | jq --argjson r "$ROUND" ".${ROUND_KEY} = \$r")
save_state "$STATE"

OPEN_FINDINGS=$(get_open_findings)

if [ "$PHASE" = "plan" ]; then
    CONTEXT=$(build_plan_input "$OPEN_FINDINGS" "$ROUND")
    SPROMPT="$PLAN_SYSTEM"
else
    CONTEXT=$(build_impl_input "$OPEN_FINDINGS" "$ROUND")
    SPROMPT="$IMPL_SYSTEM"
    if echo "$CONTEXT" | grep -q "No changes detected"; then
        # PATCH 3: Rollback round — this invocation did no work
        STATE=$(echo "$STATE" | jq --argjson r "$((ROUND - 1))" ".${ROUND_KEY} = \$r")
        save_state "$STATE"
        echo "No diff to review. Skipping (round not consumed)." >&2; exit 0
    fi
fi

if [ "$PHASE" = "impl" ]; then
    # Hash the exact review corpus: unstaged + staged + filtered untracked (with path markers)
    DH=$({
        git diff 2>/dev/null || true
        git diff --cached 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null \
            | { grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|rb|sh|md|json|yaml|yml|toml|sql|c|cpp|h|hpp|proto|tf|hcl|lua|swift|kt|scala|ex|exs|css|scss|html|xml|graphql|prisma)$|(^|/)(Dockerfile|Makefile|Jenkinsfile|Taskfile|Justfile|Gemfile|Rakefile)$' || true; } \
            | head -10 \
            | while read -r f; do echo "---FILE:${f}---"; head -200 "$f" 2>/dev/null; done
    } | _sha256 | cut -d' ' -f1)
    STATE=$(echo "$STATE" | jq --arg h "$DH" '.latest_diff_hash = $h')
    save_state "$STATE"
fi

VDIR="${VAL_DIR}/${PHASE}-round-${ROUND}"
mkdir -p "$VDIR"
VF="${VDIR}/verdict.json"
PF="${VDIR}/prompt.txt"

echo "${SPROMPT}

${CONTEXT}" > "$PF"

echo "Running Codex ${PHASE} review (round ${ROUND}/${MAX_ROUNDS})..." >&2

# Run Codex from an isolated temp directory so it cannot access the project repo.
# The prompt and schema are copied in; Codex has no filesystem path to the project.
CODEX_WORKDIR=$(mktemp -d)
CODEX_VF="${CODEX_WORKDIR}/verdict.json"
cp "$SCHEMA_PATH" "${CODEX_WORKDIR}/schema.json"
cp "$PF" "${CODEX_WORKDIR}/prompt.txt"

if ! (cd "$CODEX_WORKDIR" && _timeout "$TIMEOUT" codex exec - \
    --model "$CODEX_MODEL" \
    --sandbox read-only \
    --skip-git-repo-check \
    --output-schema "${CODEX_WORKDIR}/schema.json" \
    -o "$CODEX_VF" < "${CODEX_WORKDIR}/prompt.txt" 2>/dev/null); then
    rm -rf "$CODEX_WORKDIR"
    echo "Codex review timed out or failed." >&2
    STATE=$(echo "$STATE" | jq '.exit_reason = "codex_failure"'); save_state "$STATE"; exit 1
fi
if [ ! -f "$CODEX_VF" ] || [ ! -s "$CODEX_VF" ]; then
    rm -rf "$CODEX_WORKDIR"
    echo "Codex produced no output." >&2; exit 1
fi
cp "$CODEX_VF" "$VF"
rm -rf "$CODEX_WORKDIR"

# =====================================================================
# Process verdict
# =====================================================================
append_findings "$VF" "$ROUND" "$PHASE"

DECISION=$(jq -r '.decision' "$VF")
BLOCKING=$(jq -r '.exit_check.open_blocking_count // 0' "$VF")
CONFIDENCE=$(jq -r '.confidence // 0' "$VF")
SUMMARY=$(jq -r '.summary' "$VF")
GAPS=$(jq '.gaps | length' "$VF")
ISSUES=$(jq '.issues | length' "$VF")
COMMENTS=$(jq '.comments | length' "$VF")

# Controller override: reconcile decision with blocking count
if { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; } && [ "$BLOCKING" -gt 0 ] 2>/dev/null; then
    echo "Controller override: decision=${DECISION} but open_blocking_count=${BLOCKING}. Forcing revise." >&2
    ORIG_DECISION_FOR_LOG="$DECISION"
    DECISION="revise"
    SUMMARY="Controller override: ${BLOCKING} blocking finding(s) contradict ${ORIG_DECISION_FOR_LOG}. Original: ${SUMMARY}"
fi

# FIX 3: Controller override — detect stall independently
if [ "$ROUND" -gt 1 ] && [ "$DECISION" = "revise" ]; then
    SC=$(detect_stall "$PHASE" "$ROUND")
    if [[ "$SC" == stall:* ]]; then
        echo "Controller stall override: ${SC}" >&2
        DECISION="stall"
        SUMMARY="Controller override: ${SC}. Original: ${SUMMARY}"
    fi
fi

# Persist controller overrides into the verdict file so there is one source of truth
ORIG_DECISION=$(jq -r '.decision' "$VF")
if [ "$DECISION" != "$ORIG_DECISION" ]; then
    jq --arg d "$DECISION" --arg s "$SUMMARY" --arg od "$ORIG_DECISION" \
        '. + {controller_override: true, original_decision: $od, decision: $d, summary: $s}' \
        "$VF" > "${VF}.tmp" && mv "${VF}.tmp" "$VF"
fi

STATE=$(echo "$STATE" | jq \
    --arg d "$DECISION" --argjson r "$ROUND" --arg ts "$(date -Iseconds)" --arg vf "$VF" \
    ".${HIST_KEY} += [{round:\$r, decision:\$d, timestamp:\$ts, verdict_file:\$vf}]")

# FIX 2: Plan approval on pass OR accept_with_risks
if [ "$PHASE" = "plan" ] && { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; }; then
    PH=$(_sha256 < "${PLAN_FILE:-.claude/plan.md}" 2>/dev/null | cut -d' ' -f1 || echo "")
    STATE=$(echo "$STATE" | jq --arg h "$PH" '.plan_approved=true | .approved_plan_hash=$h')
    mkdir -p "${VAL_DIR}/latest-plan"; cp "$VF" "${VAL_DIR}/latest-plan/final.json"
fi
if [ "$PHASE" = "impl" ] && { [ "$DECISION" = "pass" ] || [ "$DECISION" = "accept_with_risks" ]; }; then
    mkdir -p "${VAL_DIR}/latest-impl"; cp "$VF" "${VAL_DIR}/latest-impl/final.json"
fi

case "$DECISION" in
    pass)              STATE=$(echo "$STATE" | jq '.exit_reason="pass"') ;;
    accept_with_risks) STATE=$(echo "$STATE" | jq '.exit_reason="accept_with_risks"') ;;
    stall)             STATE=$(echo "$STATE" | jq '.exit_reason="stall"') ;;
    revise)            STATE=$(echo "$STATE" | jq '.exit_reason="awaiting_adjudication"') ;;
esac
save_state "$STATE"

# =====================================================================
# Adjudication file + dispositions template
# =====================================================================
if [ "$DECISION" = "revise" ]; then
    AF="${VDIR}/adjudicate.md"
    {
        echo "# Codex ${PHASE} findings — round ${ROUND}"
        echo ""; echo "Decision: ${DECISION} | Confidence: ${CONFIDENCE} | Blocking: ${BLOCKING}"
        echo ""; echo "${SUMMARY}"; echo ""
        [ "$GAPS" -gt 0 ] && { echo "## GAPS"
            jq -r '.gaps[] | "### \(.id) [\(.severity)] [\(.class)] \(if .blocking then "BLOCKING" else "" end)\n- Artifact: \(.artifact // "—")\n- Evidence: \(.evidence)\n- Action: \(.action)\n"' "$VF"; }
        [ "$ISSUES" -gt 0 ] && { echo "## ISSUES"
            jq -r '.issues[] | "### \(.id) [\(.severity)] [\(.class)] \(if .blocking then "BLOCKING" else "" end)\n- Artifact: \(.artifact // "—")\n- Evidence: \(.evidence)\n- Action: \(.action)\n"' "$VF"; }
        [ "$COMMENTS" -gt 0 ] && { echo "## COMMENTS (advisory — no action required)"
            jq -r '.comments[] | "- \(.id) [\(.class)] \(.artifact // ""): \(.note)"' "$VF"; }
        echo ""
        echo "## RESPOND TO EACH GAP AND ISSUE"
        echo "For each finding ID, state one of:"
        echo "  fixed | accepted_risk | deferred | not_applicable | disagree"
        echo ""
        echo "Then write dispositions to ${DISPOSITIONS_FILE}:"
        echo '  [{"finding_id":"G1","fingerprint":"...","disposition":"fixed","rationale":"..."}]'
        echo ""
        echo "Then run: /review-${PHASE} --rerun"
    } > "$AF"

    # Dispositions template — includes fingerprint for durable identity
    jq '[(.gaps[]?, .issues[]?) | {finding_id:.id, fingerprint:.fingerprint, disposition:"open", rationale:""}]' \
        "$VF" > "${VDIR}/dispositions-template.json" 2>/dev/null || true
fi

# =====================================================================
# Summary
# =====================================================================
echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
PHASE_UPPER=$(echo "$PHASE" | tr '[:lower:]' '[:upper:]')
echo "  CODEX ${PHASE_UPPER} REVIEW — round ${ROUND}" >&2
echo "  Decision: ${DECISION} | Confidence: ${CONFIDENCE}" >&2
echo "  Gaps: ${GAPS} | Issues: ${ISSUES} | Comments: ${COMMENTS} | Blocking: ${BLOCKING}" >&2
echo "  ${SUMMARY}" >&2
if [ "$DECISION" = "revise" ]; then
    echo "  → Adjudicate: ${VDIR}/adjudicate.md" >&2
    echo "  → Template:   ${VDIR}/dispositions-template.json" >&2
    echo "  → Write to:   ${DISPOSITIONS_FILE}" >&2
    echo "  → Then run:   /review-${PHASE} --rerun" >&2
fi
echo "  Verdict: ${VF}" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

} # end main()

# =====================================================================
# Source guard: only run main when executed, not when sourced.
# Usage for tests:  source gate-review.sh --source-only
# =====================================================================
if [ "${1:-}" = "--source-only" ]; then
    # Sourced for testing — functions are now available, main does not run.
    # Caller must set VAL_DIR, LEDGER_FILE, DISPOSITIONS_FILE, SEQ_FILE etc.
    :
elif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
