Trigger Gate A: send the plan to Codex for independent review.

Before running, produce a plan at `.claude/plan.md` with required sections:
Objective, Scope in / scope out, Assumptions, Files/modules to touch, Invariants,
Test strategy, Rollback plan, Acceptance criteria, Known risks.

## First run (no --rerun)

1. Save the plan to `.claude/plan.md`
2. Run `bash ~/.claude/hooks/gate-review.sh plan`
3. Read the verdict from the path printed in output
4. Present findings as GAPS / ISSUES / COMMENTS
5. For each gap and issue, state your disposition:
   - **fixed** — update the plan
   - **accepted_risk** — explain why risk is bounded
   - **deferred** — explain when
   - **not_applicable** — explain why
   - **disagree** — explain rationale
6. Do NOT act on COMMENTS
7. **Write dispositions to `.codex-validations/dispositions.json`**:
   ```json
   [
     {"finding_id": "G1", "fingerprint": "plan:requirements:plan.md:abc12", "disposition": "fixed", "rationale": "added test strategy section"},
     {"finding_id": "G2", "fingerprint": "plan:tests:plan.md:def34", "disposition": "accepted_risk", "rationale": "rollback is implicit in feature flag"}
   ]
   ```
   Use the template at the verdict directory's `dispositions-template.json` as a starting point.
   Include both `finding_id` and `fingerprint` — fingerprint is the durable identity used for suppression.
8. Tell me to run `/review-plan --rerun` if findings were addressed

## Rerun (with --rerun in $ARGUMENTS)

1. Run `bash ~/.claude/hooks/gate-review.sh plan --rerun`
   (This automatically ingests dispositions.json into the ledger before reviewing)
2. Follow steps 3-8 above

IMPORTANT: The dispositions.json file is how findings get suppressed across rounds.
If you skip writing it, resolved findings will be re-raised on rerun.

$ARGUMENTS
