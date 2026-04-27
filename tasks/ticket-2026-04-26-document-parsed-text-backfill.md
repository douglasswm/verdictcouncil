# Ticket: Backfill `Document.parsed_text` for already-uploaded files

**Filed**: 2026-04-26
**Source**: Q-G in streaming/ingestion plan (`tasks/plan-2026-04-26-streaming-and-ingestion.md`)
**Severity**: Low (no correctness impact — runner-side fallback covers it)
**Scope**: `VerdictCouncil_Backend` only
**Out of scope of**: streaming + ingestion plan, gate-2 rerun ticket, prompt-pack realignment ticket

---

## Summary

Once Q2.1 ships (`Document.parsed_text` JSONB column populated at upload time via the outbox/arq pattern), all newly-uploaded documents get cached parsed text. **Existing documents** uploaded before Q2.1 land have NULL `parsed_text`. The runner-side fallback (Q2.2) covers them at first-pipeline-run cost: one inline `parse_document` call per missing file before the agent loop starts. That's a permanent latency tax on legacy cases.

This ticket eliminates that tax with a one-shot backfill.

## Why this is a separate ticket

- Q2 already restores broken behavior; backfill is a perf/cleanup pass, not a fix.
- Backfill incurs OpenAI Files API spend proportional to legacy document count — needs explicit go-ahead, not a stealth-budget item bundled in Q2.
- Backfill can land any time after Q2.1's column ships. No urgency, no plan dependency.

## Acceptance criteria

- [ ] One-shot script `scripts/backfill_document_parsed_text.py` (or an arq-compatible job under `src/workers/`) iterating over `documents WHERE parsed_text IS NULL AND openai_file_id IS NOT NULL`.
- [ ] Per row: call `parse_document(openai_file_id)`, persist result to `Document.parsed_text`. Use the same code path Q2.1's worker uses — share, don't duplicate.
- [ ] **Idempotent**: re-running picks up rows still NULL; rows already populated are skipped. Safe to interrupt/resume.
- [ ] **Rate-limited**: configurable concurrency (default 4) to avoid hammering OpenAI. Tunable via env or CLI flag.
- [ ] **Cost report**: log total documents processed, parse_document call count, estimated cost. Operator runs the script with `--dry-run` first to see how many rows + estimated spend before committing.
- [ ] **Failure handling**: per-row failures logged with `document_id`, `openai_file_id`, `error_class`. Failed rows stay NULL — runner fallback still works for them. Script exits 0 even with per-row failures (operator inspects the log).
- [ ] Documented runbook in `docs/runbooks/backfill-document-parsed-text.md`: how to estimate scope, how to run dry, how to run for real, how to verify post-run.

## Verification

- [ ] Dry-run on a staging snapshot: report N documents to backfill + estimated cost.
- [ ] Actual run on staging: assert post-run `SELECT COUNT(*) FROM documents WHERE parsed_text IS NULL` ≤ pre-run count by N − failures.
- [ ] Spot-check 5 random backfilled rows: `parsed_text->>'text'` non-empty, matches what the file contains.
- [ ] Idempotency: re-run after success → script reports 0 rows to process.

## Dependencies

- **Hard**: Q2.1 must be merged (column exists, worker code path exists, share it).
- **Soft**: easiest after Q2 fully ships (Checkpoint A) so legacy fallback semantics are stable.
- **Not blocked by**: Q1, gate-2 rerun, prompt-pack realignment.

## Branch

`feat/backfill-document-parsed-text` off `development` in `VerdictCouncil_Backend`.

## Files likely touched

- `VerdictCouncil_Backend/scripts/backfill_document_parsed_text.py` (new) — OR `src/workers/backfill_documents.py` if structured as an arq job
- `VerdictCouncil_Backend/docs/runbooks/backfill-document-parsed-text.md` (new)
- Reuse the parse-and-persist helper introduced in Q2.1 (no duplication)

## Estimated scope

S — single script + a runbook. ~half a day if Q2.1's worker code is well-factored (which it should be — that's part of Q2.1's quality bar).

## Risk + mitigation

| Risk | Mitigation |
|---|---|
| OpenAI Files API spend spike on a large legacy corpus | Dry-run first; require explicit operator go-ahead with cost number in PR description before running for real. |
| Long-running script gets killed mid-run | Idempotent design: re-run picks up where it left off. Per-row commit (don't batch the whole table). |
| `openai_file_id` no longer valid (file expired/deleted on OpenAI side) | Log + skip; runner fallback already handles this case. Failed rows don't block successful rows. |

## Why this isn't bundled

Q2.1 ships the column + the new-uploads happy path. The legacy fix is a separate operational decision (cost). Bundling would force reviewers to approve both at once and would couple a code ship to an ops decision.
