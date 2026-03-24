#!/usr/bin/env bash
# ============================================================================
# acceptance-report.sh — Gate D: model-free acceptance report generator
#
# Reads state.json and findings.jsonl to produce a model-free report.
# No AI model needed — pure computation from validation state.
#
# Usage: bash ~/.claude/hooks/acceptance-report.sh
# Output: .codex-validations/acceptance-report.md
# ============================================================================

set -euo pipefail

VAL_DIR=".codex-validations"
STATE_FILE="${VAL_DIR}/state.json"
LEDGER_FILE="${VAL_DIR}/findings.jsonl"
TEST_FILE="${VAL_DIR}/test-output.txt"
REPORT_FILE="${VAL_DIR}/acceptance-report.md"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: No state file at ${STATE_FILE}. Run /review-plan or /review-impl first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read state
# ---------------------------------------------------------------------------
TASK_ID=$(jq -r '.task_id' "$STATE_FILE")
CREATED=$(jq -r '.created_at' "$STATE_FILE")
PLAN_APPROVED=$(jq -r '.plan_approved' "$STATE_FILE")
PLAN_ROUND=$(jq -r '.plan_round' "$STATE_FILE")
IMPL_ROUND=$(jq -r '.impl_round' "$STATE_FILE")
EXIT_REASON=$(jq -r '.exit_reason' "$STATE_FILE")

# Latest verdicts
PLAN_DECISION="none"
PLAN_CONFIDENCE="n/a"
IMPL_DECISION="none"
IMPL_CONFIDENCE="n/a"

if [ -f "${VAL_DIR}/latest-plan/final.json" ]; then
    PLAN_DECISION=$(jq -r '.decision' "${VAL_DIR}/latest-plan/final.json")
    PLAN_CONFIDENCE=$(jq -r '.confidence // "n/a"' "${VAL_DIR}/latest-plan/final.json")
fi
if [ -f "${VAL_DIR}/latest-impl/final.json" ]; then
    IMPL_DECISION=$(jq -r '.decision' "${VAL_DIR}/latest-impl/final.json")
    IMPL_CONFIDENCE=$(jq -r '.confidence // "n/a"' "${VAL_DIR}/latest-impl/final.json")
fi

# ---------------------------------------------------------------------------
# Compute finding counts from ledger (effective state = latest per fingerprint)
# ---------------------------------------------------------------------------
OPEN_BLOCKING=0
OPEN_WARNINGS=0
FIXED=0
ACCEPTED=0
DEFERRED=0
DISAGREED=0
NOT_APPLICABLE=0

if [ -f "$LEDGER_FILE" ]; then
    # Effective state: group by fingerprint, sort by ledger_seq, take last
    EFFECTIVE=$(jq -s '
        group_by(.fingerprint // .id)
        | map(sort_by(.ledger_seq // .ledger_round) | last)
    ' "$LEDGER_FILE" 2>/dev/null || echo "[]")

    OPEN_BLOCKING=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "open" and .blocking == true)] | length')
    OPEN_WARNINGS=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "open" and (.blocking == false or .blocking == null))] | length')
    FIXED=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "fixed")] | length')
    ACCEPTED=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "accepted_risk")] | length')
    DEFERRED=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "deferred")] | length')
    DISAGREED=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "disagree")] | length')
    NOT_APPLICABLE=$(echo "$EFFECTIVE" | jq '[.[] | select(.disposition == "not_applicable")] | length')
fi

# ---------------------------------------------------------------------------
# Test evidence summary
# ---------------------------------------------------------------------------
TEST_STATUS="No test evidence found"
if [ -f "$TEST_FILE" ]; then
    TEST_LINES=$(wc -l < "$TEST_FILE")
    if grep -qi "fail\|error\|FAIL\|ERROR" "$TEST_FILE" 2>/dev/null; then
        TEST_STATUS="Tests ran (${TEST_LINES} lines). Failures detected."
    else
        TEST_STATUS="Tests ran (${TEST_LINES} lines). No failures detected."
    fi
fi

# ---------------------------------------------------------------------------
# Generate report
# ---------------------------------------------------------------------------
{
    echo "# Acceptance Report"
    echo ""
    echo "Generated: $(date -Iseconds)"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Field | Value |"
    echo "|-------|-------|"
    echo "| Task ID | ${TASK_ID} |"
    echo "| Created | ${CREATED} |"
    echo "| Plan approved | ${PLAN_APPROVED} |"
    echo "| Plan verdict | ${PLAN_DECISION} (confidence: ${PLAN_CONFIDENCE}) |"
    echo "| Plan rounds | ${PLAN_ROUND} |"
    echo "| Impl verdict | ${IMPL_DECISION} (confidence: ${IMPL_CONFIDENCE}) |"
    echo "| Impl rounds | ${IMPL_ROUND} |"
    echo "| Exit reason | ${EXIT_REASON} |"
    echo "| Test evidence | ${TEST_STATUS} |"
    echo ""

    # Ship decision
    if [ "$OPEN_BLOCKING" -gt 0 ]; then
        echo "## SHIP DECISION: NOT RECOMMENDED"
        echo ""
        echo "There are ${OPEN_BLOCKING} open blocking finding(s). These must be resolved before shipping."
    elif [ "$OPEN_WARNINGS" -gt 0 ]; then
        echo "## SHIP DECISION: CONDITIONAL"
        echo ""
        echo "No open blocking findings. ${OPEN_WARNINGS} non-blocking warning(s) remain open."
    else
        echo "## SHIP DECISION: CLEAR"
        echo ""
        echo "No open findings. All blocking items resolved."
    fi
    echo ""

    echo "## Finding breakdown"
    echo ""
    echo "| Status | Count |"
    echo "|--------|-------|"
    echo "| Open blocking | ${OPEN_BLOCKING} |"
    echo "| Open warnings | ${OPEN_WARNINGS} |"
    echo "| Fixed | ${FIXED} |"
    echo "| Accepted risk | ${ACCEPTED} |"
    echo "| Deferred | ${DEFERRED} |"
    echo "| Disagree | ${DISAGREED} |"
    echo "| Not applicable | ${NOT_APPLICABLE} |"
    echo ""

    # Detail sections from effective ledger state
    if [ -f "$LEDGER_FILE" ]; then

        # Open blocking
        if [ "$OPEN_BLOCKING" -gt 0 ]; then
            echo "## Open blocking findings"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "open" and .blocking == true)
                | "- **\(.id)** [\(.severity)] [\(.class)] \(.artifact // "")\n  Evidence: \(.evidence)\n  Action: \(.action // "—")\n"
            '
        fi

        # Open warnings
        if [ "$OPEN_WARNINGS" -gt 0 ]; then
            echo "## Open warnings"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "open" and (.blocking == false or .blocking == null))
                | "- **\(.id)** [\(.severity)] [\(.class)] \(.artifact // "")\n  Evidence: \(.evidence)\n"
            '
        fi

        # Fixed
        if [ "$FIXED" -gt 0 ]; then
            echo "## Resolved (fixed)"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "fixed")
                | "- **\(.id)** [\(.class)] \(.artifact // ""): \(.evidence)"
            '
            echo ""
        fi

        # Accepted risks
        if [ "$ACCEPTED" -gt 0 ]; then
            echo "## Accepted risks"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "accepted_risk")
                | "- **\(.id)** [\(.severity)] [\(.class)] \(.artifact // "")\n  Evidence: \(.evidence)\n  Rationale: \(.disposition_rationale // "—")\n"
            '
        fi

        # Deferred
        if [ "$DEFERRED" -gt 0 ]; then
            echo "## Deferred items"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "deferred")
                | "- **\(.id)** [\(.severity)] [\(.class)] \(.artifact // "")\n  Evidence: \(.evidence)\n  Rationale: \(.disposition_rationale // "—")\n"
            '
        fi

        # Disagreements
        if [ "$DISAGREED" -gt 0 ]; then
            echo "## Disagreements"
            echo ""
            echo "$EFFECTIVE" | jq -r '
                .[] | select(.disposition == "disagree")
                | "- **\(.id)** [\(.severity)] [\(.class)] \(.artifact // "")\n  Validator said: \(.evidence)\n  Builder rationale: \(.disposition_rationale // "—")\n"
            '
        fi
    fi

    # Round history
    echo "## Round history"
    echo ""
    echo "### Plan reviews"
    echo ""
    PLAN_HIST=$(jq -r '.plan_history[] | "| \(.round) | \(.decision) | \(.timestamp) |"' "$STATE_FILE" 2>/dev/null || echo "")
    if [ -n "$PLAN_HIST" ]; then
        echo "| Round | Decision | Timestamp |"
        echo "|-------|----------|-----------|"
        echo "$PLAN_HIST"
    else
        echo "No plan reviews recorded."
    fi
    echo ""
    echo "### Implementation reviews"
    echo ""
    IMPL_HIST=$(jq -r '.impl_history[] | "| \(.round) | \(.decision) | \(.timestamp) |"' "$STATE_FILE" 2>/dev/null || echo "")
    if [ -n "$IMPL_HIST" ]; then
        echo "| Round | Decision | Timestamp |"
        echo "|-------|----------|-----------|"
        echo "$IMPL_HIST"
    else
        echo "No implementation reviews recorded."
    fi
    echo ""

    # Why the system stopped
    echo "## Why the system stopped"
    echo ""
    case "$EXIT_REASON" in
        pass) echo "All gates passed with zero blocking findings." ;;
        accept_with_risks) echo "Gates passed with documented non-blocking warnings." ;;
        stall) echo "Controller detected stall: findings not decreasing between rounds." ;;
        max_rounds_plan) echo "Maximum plan review rounds (${PLAN_ROUND}) reached." ;;
        max_rounds_impl) echo "Maximum implementation review rounds (${IMPL_ROUND}) reached." ;;
        awaiting_adjudication) echo "Awaiting adjudication of latest findings. Run /review-plan --rerun or /review-impl --rerun." ;;
        codex_failure) echo "Codex review timed out or failed." ;;
        *) echo "Exit reason: ${EXIT_REASON:-unknown}" ;;
    esac

} > "$REPORT_FILE"

echo "Acceptance report written to ${REPORT_FILE}" >&2
echo "" >&2

# Print summary to stderr
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "  GATE D: ACCEPTANCE REPORT" >&2
echo "  Task: ${TASK_ID}" >&2
echo "  Plan: ${PLAN_DECISION} | Impl: ${IMPL_DECISION}" >&2
echo "  Open blocking: ${OPEN_BLOCKING} | Warnings: ${OPEN_WARNINGS}" >&2
echo "  Fixed: ${FIXED} | Accepted risk: ${ACCEPTED} | Deferred: ${DEFERRED}" >&2
if [ "$OPEN_BLOCKING" -gt 0 ]; then
    echo "  RECOMMENDATION: DO NOT SHIP" >&2
elif [ "$OPEN_WARNINGS" -gt 0 ]; then
    echo "  RECOMMENDATION: CONDITIONAL (review warnings)" >&2
else
    echo "  RECOMMENDATION: CLEAR TO SHIP" >&2
fi
echo "  Report: ${REPORT_FILE}" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
