Trigger Gate C: send the implementation diff to Codex for independent review.

Before running:
- Plan should be approved (`.codex-validations/state.json` → `plan_approved: true`)
- Run tests and save output: `{test command} > .codex-validations/test-output.txt 2>&1`

## First run (no --rerun)

1. Run project tests and save: `{test command} > .codex-validations/test-output.txt 2>&1`
2. Run `bash ~/.claude/hooks/gate-review.sh impl`
3. Read the verdict from the path printed in output
4. Present findings as GAPS / ISSUES / COMMENTS
5. For each gap and issue, state your disposition:
   - **fixed** — address in code, list changed files
   - **accepted_risk** — explain bounded risk
   - **deferred** — explain timeline
   - **not_applicable** — explain why
   - **disagree** — explain rationale
6. Do NOT act on COMMENTS
7. Do NOT change code beyond the specific findings
8. Do NOT raise architecture concerns — that was the plan phase
9. **Write dispositions to `.codex-validations/dispositions.json`**:
   ```json
   [
     {"finding_id": "I1", "fingerprint": "impl:security:auth.ts:abc12", "disposition": "fixed", "rationale": "added try-catch"},
     {"finding_id": "I2", "fingerprint": "impl:correctness:api.ts:def34", "disposition": "accepted_risk", "rationale": "rate limiter bounds exposure"}
   ]
   ```
   Use the template at the verdict directory's `dispositions-template.json` as a starting point.
   Include both `finding_id` and `fingerprint` — fingerprint is the durable identity used for suppression.
10. Tell me to run `/review-impl --rerun` if findings were addressed

## Rerun (with --rerun in $ARGUMENTS)

1. Run `bash ~/.claude/hooks/gate-review.sh impl --rerun`
   (This automatically ingests dispositions.json into the ledger before reviewing)
2. Follow steps 3-10 above

IMPORTANT: The dispositions.json file is how findings get suppressed across rounds.
If you skip writing it, resolved findings will be re-raised on rerun.

$ARGUMENTS
