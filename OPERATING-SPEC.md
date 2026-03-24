# Phase-Gated Dual-Agent Verification — Operating Spec v3.2

## Roles

| Agent | Role | Owns |
|-------|------|------|
| Claude Code | Author + operator | Planning, execution, repair, synthesis, adjudication |
| Codex CLI | Reviewer + sceptic | Reviews bounded artifacts: plan, diff, evidence |
| Orchestrator | Traffic cop | State machine, convergence rules, finding ledger |

## Core rules

1. Codex reviews **artifacts**, not conversation. Never sees Claude's reasoning. Enforced via filesystem isolation: Codex runs from a temp directory containing only the schema, with the prompt piped via stdin. The project repo is not accessible.
2. One review round per invocation. No polling. Reruns are explicit (`--rerun`).
3. Findings are persisted with stable fingerprints. Duplicates are suppressed.
4. Dispositions are resolved by fingerprint first, then ID. Fingerprint is the durable identity.
5. Claude can disagree. Disagreements are reviewed, not code churn.
6. The system stops when shippable, not when happy.
7. Plan must be approved before implementation review. Plan hash is verified at Gate C entry.
8. Controller reconciles model decisions: if blocking findings contradict a "pass" verdict, the orchestrator overrides to "revise".

---

## State model

### Session state (`state.json`)
```json
{
  "task_id": "task-20260323-a1b2c3d4",
  "created_at": "2026-03-23T14:00:00Z",
  "plan_round": 0,
  "impl_round": 0,
  "plan_approved": false,
  "approved_plan_hash": "sha256...",
  "latest_diff_hash": "sha256...",
  "exit_reason": "pass|stall|max_rounds|awaiting_adjudication|accept_with_risks|codex_failure",
  "plan_history": [
    { "round": 1, "decision": "revise", "timestamp": "...", "verdict_file": "..." }
  ],
  "impl_history": []
}
```

Phase-scoped counters: `plan_round` and `impl_round` are independent.
No `findings_ledger` in state — the real ledger is `findings.jsonl`.

### Findings ledger (`findings.jsonl`)
Append-only. Every finding from every round and every disposition update is a new line.

Each entry carries:
- `id`, `fingerprint`, `severity`, `class`, `evidence`, `evidence_type`
- `blocking` (boolean — whether it blocks shipping)
- `ledger_phase`, `ledger_round`, `ledger_ts`
- `ledger_seq` — monotonic sequence number from `.ledger_seq` counter file
- `disposition`: open → fixed | accepted_risk | deferred | not_applicable | disagree

**Effective state**: group by `fingerprint`, sort by `ledger_seq`, take last. This is deterministic regardless of timing or round ties.

**Dedup**: `get_open_findings()` groups by fingerprint, sorts by `ledger_seq`, returns only entries where `disposition == "open"`.

### Finding fingerprint
Format: `{phase}:{class}:{artifact}:{hash(evidence)}`

Stable across rounds. Used as the primary identity for suppression, dedup, and disposition lookup.

### Disposition ingestion
Claude writes `.codex-validations/dispositions.json` after adjudicating.

Each entry may include `finding_id`, `fingerprint`, or both:
```json
[
  {"finding_id": "I1", "fingerprint": "impl:security:auth.js:abc123", "disposition": "fixed", "rationale": "..."}
]
```

Lookup priority: **fingerprint first** (durable identity), then `finding_id` (session-local fallback).

On `--rerun`, the orchestrator calls `ingest_dispositions()` before building the review context. Ingested dispositions are archived to prevent double-ingestion.

---

## Workflow

### Phase 1 — Plan

Claude produces a plan with required sections:

| Section | Required |
|---------|----------|
| Objective | Yes |
| Scope in / scope out | Yes |
| Assumptions | Yes |
| Files/modules to touch | Yes |
| Invariants | Yes |
| Test strategy | Yes |
| Rollback plan | Yes |
| Acceptance criteria | Yes |
| Known risks | Yes |

### Gate A — Plan review

Trigger: `/review-plan`

Codex receives ONLY: the plan artifact, the plan contract checklist, open findings from prior rounds, and a fingerprint ignore list of closed findings.

### Adjudication → Rerun

Claude adjudicates each finding, writes `dispositions.json` (with both `finding_id` and `fingerprint`), then user runs `/review-plan --rerun`.

### Gate B — Plan approval

Plan is approved when verdict is `pass` **or** `accept_with_risks`.
State records `plan_approved: true` and `approved_plan_hash`.

### Phase 3 — Execution

Claude implements. **Codex is NOT called during execution.**

### Gate C — Implementation review

Trigger: `/review-impl`

Codex receives ONLY:
- Approved plan summary
- Changed diff (`git diff` + `git diff --cached`)
- **New untracked source files** (contents included, capped at 200 lines × 10 files)
- Changed paths list (includes untracked)
- Test evidence
- Open findings from prior rounds
- Fingerprint ignore list of closed/accepted/deferred findings

Does NOT receive: the full codebase, unchanged files, Claude's reasoning.

### Gate D — Acceptance report

Trigger: `/acceptance-report`

Generates a final report from `state.json` and `findings.jsonl`.

---

## Anti-loop rules

| Rule | Mechanism |
|------|-----------|
| Codex reviews artifacts only | Runs from isolated temp dir; project repo not on filesystem path |
| Max 2 rounds per phase | Phase-scoped counters: `plan_round`, `impl_round` |
| Only blocking findings reopen | `blocking: true` field on each finding |
| Deterministic latest-wins | `ledger_seq` monotonic counter, not round-based sorting |
| Findings have durable identity | Fingerprint: `phase:class:artifact:evidence_hash` |
| Resolved findings suppressed | Fingerprint ignore list (IDs retained for adjudication lookup only) |
| Disposition by fingerprint | Fingerprint lookup preferred over ID in ingestion |
| Controller-side stall detection | Orchestrator computes stall independently, overrides Codex |
| Blocking count reconciliation | Orchestrator overrides "pass" if open_blocking_count > 0 |
| Plan gate enforced | Impl review blocked without approved plan (bypass: SKIP_PLAN_CHECK=true) |
| Plan integrity verified | Plan hash checked at Gate C entry; mismatch blocks review |
| Claude can disagree | Disposition field with rationale, reviewed not churned |
| No-diff skips don't burn rounds | Round counter rolled back on no-diff exit |
| No polling | One round per invocation, explicit `--rerun` |
| Untracked files visible | New source files included in impl review context |
| Final report wins | System can stop with open items documented |

---

## Script architecture

`gate-review.sh` is structured as:
- **Function definitions** (lines 1–325): `init_state`, `load_state`, `save_state`, `next_seq`, `append_findings`, `get_open_findings`, `get_closed_ids`, `get_closed_fingerprints`, `ingest_dispositions`, `detect_stall`, `build_plan_input`, `build_impl_input`, plus prompt constants.
- **`main()`** (lines 326–513): bail checks, round management, Codex invocation, verdict processing, adjudication file generation.
- **Source guard** (lines 515–525): `--source-only` loads functions without running main. `BASH_SOURCE` check runs main on direct execution.

This enables tests to `source gate-review.sh --source-only` and call production functions directly.

---

## Hook policy

**Default: no automatic Stop hook.**

Validation is triggered explicitly via `/review-plan` and `/review-impl`.

Optional advisory hook (prints reminder only):
```json
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo 'Run /review-impl to validate' >&2"}]}]}}
```

---

## File layout

```
~/.claude/
├── hooks/
│   ├── gate-review.sh          # Orchestrator (sourceable, main-guarded)
│   ├── acceptance-report.sh    # Gate D report generator
│   └── test-validator.sh       # Test suite
├── schemas/
│   └── verdict.json            # Codex output schema v2
└── commands/
    ├── review-plan.md          # Gate A
    ├── review-impl.md          # Gate C
    └── acceptance-report.md    # Gate D

.codex-validations/             # Per-project, gitignored
├── state.json                  # Session state (phase-scoped rounds)
├── findings.jsonl              # Append-only finding ledger (with ledger_seq)
├── .ledger_seq                 # Monotonic counter file
├── dispositions.json           # Written by Claude, ingested on --rerun
├── test-output.txt             # Test evidence (user-generated)
├── plan-round-1/
│   ├── verdict.json
│   ├── prompt.txt
│   ├── adjudicate.md
│   └── dispositions-template.json
├── impl-round-1/
│   └── ...
├── latest-plan/final.json
├── latest-impl/final.json
└── acceptance-report.md
```

---

## Installation

```bash
bash install/install.sh          # From the repo
bash ~/.claude/hooks/test-validator.sh  # Verify
```

## Usage

```bash
/review-plan              # Gate A
/review-plan --rerun      # Re-review after adjudication
/review-impl              # Gate C
/review-impl --rerun      # Re-review after fixes
/acceptance-report        # Gate D
```

## Environment

```bash
MAX_ROUNDS=1 claude                    # Quick single-round
CODEX_MODEL=gpt-5 claude              # Deep review for releases
VALIDATION_ENABLED=false claude        # Disable temporarily
TIMEOUT_SECONDS=180 claude             # Large diffs
PLAN_FILE=docs/arch.md claude          # Custom plan location
```
