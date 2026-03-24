#!/usr/bin/env bash
# ============================================================================
# install.sh — Install the phase-gated validator
#
# Run once:  bash install.sh
# Upgrade:   bash install.sh --force
#
# Installs to ~/.claude/{hooks,schemas,commands}
# Does NOT touch project-level settings or create hooks automatically.
# ============================================================================

set -euo pipefail

FORCE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Installer lives in install/ — package root is one level up
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${PACKAGE_ROOT}/runtime"
COMMANDS_DIR="${PACKAGE_ROOT}/commands"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "Pre-flight checks..."

ERRORS=0

if ! command -v codex &>/dev/null; then
    echo "  ✗ codex not found — install: npm i -g @openai/codex"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ codex $(codex --version 2>/dev/null | head -1)"
fi

if ! codex login status &>/dev/null; then
    echo "  ✗ codex not authenticated — run: codex login"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ codex authenticated"
fi

if ! command -v jq &>/dev/null; then
    echo "  ✗ jq not found — install: brew install jq / apt install jq"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ jq $(jq --version 2>/dev/null)"
fi

if ! command -v git &>/dev/null; then
    echo "  ✗ git not found"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ git $(git --version 2>/dev/null | head -1)"
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Fix $ERRORS issue(s) above, then re-run."
    exit 1
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
echo ""
echo "Installing..."

mkdir -p ~/.claude/{hooks,schemas,commands}

# Schema
cp "${RUNTIME_DIR}/schemas/verdict.json" ~/.claude/schemas/verdict.json
echo "  ✓ ~/.claude/schemas/verdict.json"

# Orchestrator
cp "${RUNTIME_DIR}/scripts/gate-review.sh" ~/.claude/hooks/gate-review.sh
chmod +x ~/.claude/hooks/gate-review.sh
echo "  ✓ ~/.claude/hooks/gate-review.sh"

# Acceptance report generator
cp "${RUNTIME_DIR}/scripts/acceptance-report.sh" ~/.claude/hooks/acceptance-report.sh
chmod +x ~/.claude/hooks/acceptance-report.sh
echo "  ✓ ~/.claude/hooks/acceptance-report.sh"

# Slash commands
for cmd in review-plan review-impl acceptance-report; do
    if [ -f "$HOME/.claude/commands/${cmd}.md" ] && [ "$FORCE" != "--force" ]; then
        echo "  - ~/.claude/commands/${cmd}.md (exists, use --force to overwrite)"
    else
        cp "${COMMANDS_DIR}/${cmd}.md" "$HOME/.claude/commands/${cmd}.md"
        echo "  ✓ ~/.claude/commands/${cmd}.md"
    fi
done

# Test script
if [ -f "${PACKAGE_ROOT}/tests/test-validator.sh" ]; then
    cp "${PACKAGE_ROOT}/tests/test-validator.sh" ~/.claude/hooks/test-validator.sh
    chmod +x ~/.claude/hooks/test-validator.sh
    echo "  ✓ ~/.claude/hooks/test-validator.sh"
fi

# ---------------------------------------------------------------------------
# Hook policy — advisory, not automatic
# ---------------------------------------------------------------------------
echo ""
echo "Hook policy:"
echo "  The Stop hook is NOT enabled by default."
echo "  Use /review-plan and /review-impl to trigger validation explicitly."
echo ""
echo "  To enable advisory Stop hook (prints reminder, no full review):"
echo "  Add to ~/.claude/settings.json or .claude/settings.json:"
echo ""
echo '  {
    "hooks": {
      "Stop": [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "echo \"Reminder: run /review-impl to validate\" >&2"
        }]
      }]
    }
  }'
echo ""
echo "  To enable automatic impl review on Stop (use with caution):"
echo '  "command": "bash ~/.claude/hooks/gate-review.sh impl"'

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "Verification..."

ALL_OK=true
for f in \
    ~/.claude/hooks/gate-review.sh \
    ~/.claude/hooks/acceptance-report.sh \
    ~/.claude/schemas/verdict.json \
    ~/.claude/commands/review-plan.md \
    ~/.claude/commands/review-impl.md \
    ~/.claude/commands/acceptance-report.md; do
    if [ -f "$f" ]; then
        echo "  ✓ $(basename $f)"
    else
        echo "  ✗ MISSING: $f"
        ALL_OK=false
    fi
done

[ -x ~/.claude/hooks/gate-review.sh ] && echo "  ✓ gate-review.sh executable" || echo "  ✗ gate-review.sh not executable"
jq empty ~/.claude/schemas/verdict.json 2>/dev/null && echo "  ✓ verdict.json valid JSON" || echo "  ✗ verdict.json invalid"

echo ""
if [ "$ALL_OK" = true ]; then
    echo "Installation complete."
    echo ""
    echo "Usage:"
    echo "  /review-plan              Gate A: validate plan"
    echo "  /review-plan --rerun      Re-review after adjudication"
    echo "  /review-impl              Gate C: validate implementation"
    echo "  /review-impl --rerun      Re-review after fixes"
    echo "  /acceptance-report        Gate D: final report"
    echo ""
    echo "Test: bash ~/.claude/hooks/test-validator.sh --mechanical"
else
    echo "Installation has issues. Check output above."
    exit 1
fi
