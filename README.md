# Cold Validation Architecture

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.3-green.svg)](QUICK-START.md#changelog)
[![Shell](https://img.shields.io/badge/shell-bash_3.2%2B-orange.svg)](runtime/scripts/gate-review.sh)
[![Tests](https://img.shields.io/badge/tests-35_passing-brightgreen.svg)](tests/test-validator.sh)
[![RAXE AI Labs](https://img.shields.io/badge/RAXE_AI-Labs-purple.svg)](https://raxe.ai/labs/cold-validation)

> **[Read the full overview at raxe.ai/labs/cold-validation](https://raxe.ai/labs/cold-validation)**

One agent builds. Another audits — with zero shared context.

## The Problem

When an AI agent reviews its own work, it has access to its full reasoning
chain. The reviewer already "knows" why each decision was made. This creates
confirmation bias, sunk-cost loyalty, and silent confidence in its own output.

## The Solution

**Cold validation** separates the builder from the reviewer. A second agent
receives ONLY the artifacts — the plan document, the code diff, the test
output — never the conversation, reasoning, or intent.

The cold reviewer has:
- No memory of the design discussion
- No loyalty to the code
- No sunk cost in the implementation
- Only the artifacts and a structured schema

This is the same principle behind double-blind peer review, independent audits,
and separation of duties — applied to AI agents.

## Architecture

```
┌─────────────┐                        ┌─────────────┐
│ Claude Code  │ ── artifacts only ──> │  Codex CLI   │
│  (builder)   │                        │  (reviewer)  │
│              │ <── structured verdict │              │
└──────┬───────┘                        └──────────────┘
       │           ┌───────────────┐
       └──────────>│  Orchestrator  │
                   │ gate-review.sh │
                   └───────────────┘
```

- **Claude Code** writes plans and code (the builder)
- **Codex CLI** reviews artifacts without context (the cold reviewer)
- **Orchestrator** manages state, finding ledger, convergence rules

The orchestrator enforces phase gates: implementation review is blocked
until the plan is approved, and the plan hash is verified at Gate C entry
to prevent post-approval drift. The controller reconciles model decisions —
if a verdict says "pass" but has blocking findings, the orchestrator
overrides to "revise". Codex runs from an isolated temp directory — it
cannot access the project repo, only the constructed prompt via stdin.

## Workflow

```
1. Write a plan        →  /review-plan         (Gate A: Codex reviews plan)
2. Adjudicate findings →  /review-plan --rerun  (re-review after fixes)
3. Implement the approved plan
4. Run tests           →  /review-impl          (Gate C: Codex reviews diff)
5. Adjudicate findings →  /review-impl --rerun  (re-review after fixes)
6. Ship                →  /acceptance-report     (Gate D: model-free final report)
```

## Quick Start

```bash
git clone https://github.com/raxe-ai/cold-validation-architecture.git
cd cold-validation-architecture
bash install/install.sh
bash ~/.claude/hooks/test-validator.sh --mechanical  # verify (no Codex needed)
```

## What's in the Box

| Path | Purpose |
|------|---------|
| `install/install.sh` | Installer with pre-flight checks |
| `runtime/scripts/gate-review.sh` | Orchestrator — one round per invocation |
| `runtime/scripts/acceptance-report.sh` | Gate D report generator (model-free) |
| `runtime/schemas/verdict.json` | Codex output schema v2 |
| `commands/*.md` | Slash commands for Claude Code |
| `tests/test-validator.sh` | Test suite (smoke + mechanical) |

## Key Design Decisions

- **No automatic hook** — validation is explicit via slash commands
- **One round per invocation** — no polling, reruns are explicit
- **Findings have durable identity** — fingerprint-based dedup across rounds
- **Claude can disagree** — with rationale, not blind code churn
- **Controller-side stall detection** — orchestrator overrides reviewer
- **Phase-scoped counters** — plan and impl rounds are independent
- **Convergence guarantees** — max 2 rounds per phase, stall detection, final report wins

## How Findings Work

Each finding has a **fingerprint** (`phase:class:artifact:evidence_hash`) that
persists across rounds. When the builder adjudicates a finding, the disposition
is recorded in an append-only ledger. On re-review, resolved findings are
suppressed by fingerprint — the reviewer only sees what's still open.

Dispositions: `fixed`, `accepted_risk`, `deferred`, `not_applicable`, `disagree`

## Documentation

- [Operating Spec](OPERATING-SPEC.md) — complete system specification
- [Quick Start](QUICK-START.md) — usage commands and changelog
- [Where This Goes](WHERE-THIS-GOES.md) — installation layout explained

## License

[Apache 2.0](LICENSE)
