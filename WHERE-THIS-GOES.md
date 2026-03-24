# Where This Goes and Why

## The Short Version

```bash
bash install/install.sh    # from the repo root
```

Done. The installer checks prerequisites, copies files, and verifies the result.

## The Structure

```
your-repo/
├── .claude/
│   ├── plan.md                        ← Created per task (your plan artifact)
│   └── settings.json                  ← Optional hook config (not default)
├── .codex-validations/                ← Created automatically (gitignored)
│   ├── state.json                     ← Session state machine
│   ├── findings.jsonl                 ← Append-only finding ledger
│   ├── .ledger_seq                    ← Monotonic counter
│   ├── dispositions.json              ← Written by Claude after adjudication
│   ├── test-output.txt                ← Your test results
│   ├── plan-round-1/verdict.json      ← Gate A verdict
│   ├── impl-round-1/verdict.json      ← Gate C verdict
│   └── acceptance-report.md           ← Gate D output
└── .gitignore                         ← Add .codex-validations/

~/.claude/                             ← User-wide (installed once, works everywhere)
├── hooks/
│   ├── gate-review.sh                 ← The orchestrator
│   ├── acceptance-report.sh           ← Gate D report generator
│   └── test-validator.sh              ← Test suite
├── schemas/
│   └── verdict.json                   ← Codex output schema
└── commands/
    ├── review-plan.md                 ← /review-plan slash command
    ├── review-impl.md                 ← /review-impl slash command
    └── acceptance-report.md           ← /acceptance-report slash command
```

## Why It Is Structured This Way

**The runtime files live in ~/.claude/ (user-wide)** because the validator works
across all your repos. Install once, use in every project. The orchestrator,
schema, test suite, and slash commands are the same everywhere. Only the
per-project state (`.codex-validations/`) is repo-local.

**The .codex-validations/ directory is gitignored** because it contains
ephemeral session state, finding ledgers, and verdict files that are specific
to your local validation runs. Each developer has their own.

## How Your Team Uses It

1. Clone the repo
2. `bash install/install.sh` (installs the system)
3. Plan a task, write `.claude/plan.md`
4. `/review-plan` (Gate A: Codex reviews the plan)
5. Adjudicate findings, write dispositions
6. `/review-plan --rerun` if needed
7. Execute the approved plan
8. Run tests, save to `.codex-validations/test-output.txt`
9. `/review-impl` (Gate C: Codex reviews the diff)
10. Adjudicate, `/review-impl --rerun` if needed
11. `/acceptance-report` (Gate D: final auditable report)

## Prerequisites

Each team member needs:
- Claude Code (Anthropic subscription or API)
- Codex CLI: `npm i -g @openai/codex`
- Codex authenticated: `codex login`
- jq: `brew install jq` or `apt install jq`
