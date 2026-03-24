# Dual-Agent Validator v3.3

Claude Code as primary agent. Codex CLI as independent phase-gate reviewer.

## Quick start

```bash
bash install/install.sh                                      # Install
bash ~/.claude/hooks/test-validator.sh --mechanical          # Verify (no Codex needed)
```

## Happy path walkthrough

Here's what a full validation cycle looks like in practice.

### 1. Write a plan

Create `.claude/plan.md` with the required sections:

```markdown
## Objective
Add JWT authentication to the API.

## Scope in / scope out
In: login endpoint, token verification middleware, test coverage.
Out: OAuth, password reset, admin roles.

## Assumptions
- Express.js backend already exists
- No existing auth middleware

## Files/modules to touch
- src/auth.ts (new)
- src/middleware.ts (modify)
- tests/auth.test.ts (new)

## Invariants
- Existing endpoints must still work without auth headers
- Token expiry must be configurable

## Test strategy
Unit tests for token generation/verification. Integration test for login flow.

## Rollback plan
Revert the PR. No database migrations involved.

## Acceptance criteria
- POST /login returns a signed JWT
- Protected routes reject missing/invalid tokens
- Tests pass with >80% coverage on new code

## Known risks
- Secret rotation not included in this scope
```

### 2. Gate A: Review the plan

```
/review-plan
```

Codex reviews your plan against the contract checklist. You'll see output like:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CODEX PLAN REVIEW — round 1
  Decision: revise | Confidence: 0.85
  Gaps: 2 | Issues: 0 | Comments: 1 | Blocking: 1
  Plan missing test strategy for error cases...
  → Adjudicate: .codex-validations/plan-round-1/adjudicate.md
  → Template:   .codex-validations/plan-round-1/dispositions-template.json
  → Write to:   .codex-validations/dispositions.json
  → Then run:   /review-plan --rerun
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 3. Adjudicate findings

Read the adjudication file, decide on each finding, write dispositions:

```json
[
  {"finding_id": "G1", "fingerprint": "plan:tests:plan.md:abc12", "disposition": "fixed", "rationale": "added error case testing to test strategy"},
  {"finding_id": "G2", "fingerprint": "plan:security:plan.md:def34", "disposition": "accepted_risk", "rationale": "secret rotation is documented as out of scope"}
]
```

Save to `.codex-validations/dispositions.json`, then:

```
/review-plan --rerun
```

### 4. Plan approved

On pass, you'll see:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CODEX PLAN REVIEW — round 2
  Decision: pass | Confidence: 0.92
  Gaps: 0 | Issues: 0 | Comments: 0 | Blocking: 0
  Plan meets all contract requirements.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 5. Implement and test

Write the code. Run your tests and capture output:

```bash
npm test > .codex-validations/test-output.txt 2>&1
```

### 6. Gate C: Review the implementation

```
/review-impl
```

Codex reviews your diff, test evidence, and any new untracked files — without seeing the full codebase or your reasoning.

### 7. Gate D: Ship

```
/acceptance-report
```

Generates a model-free final report with ship/no-ship recommendation, finding breakdown, and full round history.

## Commands reference

```
/review-plan              Gate A: validate plan
/review-plan --rerun      Re-review after adjudication
/review-impl              Gate C: validate implementation
/review-impl --rerun      Re-review after fixes
/acceptance-report        Gate D: final report
```

## What's in the box

| File | Purpose |
|------|---------|
| `install/install.sh` | Installer with pre-flight checks |
| `runtime/scripts/gate-review.sh` | Orchestrator — sourceable, main-guarded, one round per run |
| `runtime/scripts/acceptance-report.sh` | Gate D report generator (model-free) |
| `runtime/schemas/verdict.json` | Codex output schema v2 |
| `commands/*.md` | Slash commands for Claude Code |
| `tests/test-validator.sh` | Full test suite — sources real functions |
| `OPERATING-SPEC.md` | Complete system specification |

## Key design decisions

- **No automatic Stop hook** — validation is explicit via slash commands
- **One round per invocation** — no polling, reruns via `--rerun`
- **Filesystem-isolated reviewer** — Codex runs from a temp directory, not the project repo
- **Hard plan gate** — implementation review blocked without approved plan
- **Plan integrity** — plan hash verified at Gate C to prevent post-approval drift
- **Blocking count reconciliation** — controller overrides "pass" if blocking findings exist
- **Monotonic ledger_seq** — deterministic latest-wins, no round-based tie ambiguity
- **Fingerprint-first disposition lookup** — durable identity preferred over session-local IDs
- **Controller-side stall detection** — orchestrator overrides Codex, not prompt-only
- **Adjudication with disagreement** — Claude can `disagree` with rationale, not just fix

## Environment variables

```bash
MAX_ROUNDS=1 claude                    # Quick single-round
CODEX_MODEL=gpt-5 claude              # Deep review for releases
VALIDATION_ENABLED=false claude        # Disable temporarily
TIMEOUT_SECONDS=180 claude             # Large diffs
PLAN_FILE=docs/arch.md claude          # Custom plan location
SKIP_PLAN_CHECK=true claude            # Bypass plan approval gate
```

## Changelog

| Version | Changes |
|---------|---------|
| v1 | Continuous loop, Stop hook default, polling, no state model |
| v2 | Phase gates, verdict schema, adjudication dispositions |
| v3 | Ledger, explicit reruns, controller stall detection, no default hook |
| v3.1 | Disposition wiring, plan approval fix, phase-scoped rounds, mechanical tests |
| v3.2 | `ledger_seq`, untracked files, no-diff rollback, fingerprint ignore lists, fingerprint-first dispositions, source guard, real-function integration tests |
| v3.3 | Filesystem-isolated Codex, hard plan gate, plan hash verification, blocking count reconciliation, verdict override persistence, Bash 3.2 compat, broader file extension support, macOS portability |
