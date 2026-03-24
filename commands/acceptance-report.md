Generate the Gate D acceptance report using the model-free report generator.

Steps:
1. Run `bash ~/.claude/hooks/acceptance-report.sh`
2. Read the generated report from `.codex-validations/acceptance-report.md`
3. Present the ship decision and finding breakdown to me
4. If open blocking findings exist, flag them prominently

The report is model-free — generated from state.json and findings.jsonl
without calling any AI model. No tokens consumed, no interpretation.

$ARGUMENTS
