# Ticket: Prompt-vs-schema drift resolution

**Filed**: 2026-04-26 (evening — surfaced during Phase 5 prompt-pack realignment)
**Source**: Findings during `feat/prompt-pack-realignment` (see `tasks/ticket-2026-04-26-prompt-pack-realignment.md`)
**Severity**: Medium-high — includes one outright contradiction that may be silently failing in production
**Scope**: Reconcile `prompts/*.md` "Output contract" sections against the Pydantic schemas in `src/pipeline/graph/schemas.py`. The realignment PR fixed tool/cache-shape drift; this follow-up resolves output-shape drift.

---

## Summary

Phase 5's audit checklist included "Output-schema match: each prompt's 'your output must match this shape' section matches the current `PHASE_SCHEMAS[phase]` Pydantic model." Spot-checking surfaced drift that is **larger than a spot-check can resolve** and one **outright contradiction** that needs a product decision before any prompt edit can land safely. This ticket captures the findings so they are not lost; the realignment PR shipped only the fixes that were unambiguously correct.

## The contradiction (decide first)

`prompts/synthesis.md` instructs the model:

> `preliminary_conclusion` and `confidence_score` MUST be `null`. Setting them is a verdict recommendation — that is the Judge's role and is also explicitly audited by the next phase.

But `src/pipeline/graph/schemas.py:373-388` declares:

```python
class SynthesisOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    arguments: ArgumentSet
    preliminary_conclusion: str = Field(min_length=1)   # required, non-empty
    confidence: ConfidenceLevel                         # required enum
    reasoning_chain: conlist(ReasoningStep, min_length=1)
    uncertainty_flags: list[UncertaintyFlag] = Field(default_factory=list)
```

`PHASE_SCHEMAS["synthesis"]` (`agents/factory.py:92-96`) binds `schemas.SynthesisOutput` via `ToolStrategy(schema)`. If the model follows the prompt and emits `null`, `ToolStrategy` rejects on validation; if it follows the schema, it produces a verdict the audit phase will flag as CRITICAL (G1).

There is also a separate `case_state.HearingAnalysis` (`src/shared/case_state.py:40-46`) where `preliminary_conclusion: str | None = None` and `confidence_score: int | None = None` — the legacy SAM persistence shape. That model is NOT the one bound at the synthesis node.

### Decision required

- **Option A**: Update `schemas.SynthesisOutput` to make `preliminary_conclusion` `Optional[str]` and `confidence` `Optional[ConfidenceLevel]`. Aligns with the prompt's neutrality stance and the audit's G1 check (which already expects null).
- **Option B**: Update `prompts/synthesis.md` to remove the null instruction and rename `confidence_score` → `confidence` to match the schema. Breaks the architectural decision that synthesis must not recommend a verdict.

Recommend Option A on architecture grounds. Audit G1 (audit.md:57) already expects `synthesis_output.preliminary_conclusion = null` and `synthesis_output.confidence_score = null` — the schema is the outlier.

### Open question

Are synthesis runs currently failing validation in staging? Worth one trace inspection before scoping the fix. If yes, this is a correctness bug and priority climbs.

## Broader output-contract drift (non-blocking)

The prompt "Authoritative fields:" sections were drafted against an aspirational schema; the live Pydantic models are minimal. Aspirational fields the model is told to emit but the schema rejects via `extra="forbid"`:

| Prompt | Field listed in prompt | Status in actual schema |
|---|---|---|
| `intake.md` | `case_metadata.complexity`, `complexity_score`, `route`, `routing_factors`, `vulnerability_assessment`, `red_flags`, `jurisdiction_valid`, `jurisdiction_issues`, `intake_completeness_score`, `completeness_gaps`, `hearing_urgency`, `self_represented_parties` | None of these on `CaseMetadata` (which has 4 fields: `jurisdiction`, `claim_amount`, `filed_at`, `offence_code`). Most actually live on `RoutingDecision` or do not exist anywhere. |
| `intake.md` | `domain` listed as `case_metadata.domain` | `domain` is on `IntakeOutput` top-level, not on `case_metadata` |
| `research-facts.md` | `ExtractedFactItem.statement, location, parties_involved, source, submitted_by, corroborating_sources, contradicting_sources, confidence_level, confidence_score, confidence_basis, materiality` | Actual schema has only `fact_id, description, event_date, confidence, status, source_refs, corroboration` |
| `research-witnesses.md` | `Witness.category, formal_statement_exists, party_alignment, motive_to_fabricate, expert_qualification` | Actual schema has only `witness_id, name, role, statements, credibility` |
| `research-law.md` | `LegalRule.statute_name, section, verbatim_text, tier, relevance_score, application_to_facts, temporal_validity` | Actual schema has only `rule_id, jurisdiction, citation, text, applicability, supporting_sources` |
| `research-law.md` | `Precedent.court, year, outcome, reasoning_summary, similarity_score, source, application_to_case, distinguishing_factors, supports_which_party` | Actual schema has only `case_name, citation, jurisdiction, holding, relevance_rationale, supporting_sources` |
| `synthesis.md` | `contested_issues, agreed_facts, strength_comparison, burden_and_standard, judicial_questions, established_facts_ledger, element_by_element_application, witness_element_dependency_map, precedent_alignment_matrix, key_issues_for_hearing, quantum_or_sentencing_analysis, pre_hearing_brief` | None on `SynthesisOutput` (which has 5 fields) |

Resolution direction is a product decision: either trim the prompts to the minimal schema (loses analytical detail in the model output) or expand the schemas to match the prompts (large, touches persistence + diff engine + audit checks).

## Acceptance criteria

- [ ] Decide and apply Option A or B for the synthesis null contradiction.
- [ ] Verify whether synthesis runs currently fail validation in staging (trace inspection or test reproduction).
- [ ] For each row in the broader-drift table, decide: trim prompt or expand schema. Apply the decisions.
- [ ] Strengthen the parity contract test (`tests/unit/test_prompt_tool_parity.py`) to also assert prompt-mentioned fields exist on the bound schema.
- [ ] Push reconciled prompts back to LangSmith.

## Out of scope

- Tool/parsed_text/intake_extraction drift — fixed in the realignment PR.
- LangSmith pipeline changes.
- Conversational-mode placeholder pattern (separately deferred per realignment ticket).

## Branch

`feat/prompt-vs-schema-reconcile` off `development` in `VerdictCouncil_Backend`. Likely needs at least one schema migration if Option A or table-row "expand schema" choices are taken.

## Files likely touched

- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (core)
- `VerdictCouncil_Backend/prompts/*.md` (the 6 with drift; `audit.md` is OK)
- `VerdictCouncil_Backend/tests/unit/test_prompt_tool_parity.py` (extend with field-parity assertions)
- Possibly `src/db/persist_case_results.py`, `src/services/whatif/diff.py` (downstream consumers of the synthesis fields)

## Estimated scope

M-L. The synthesis-null decision alone is small; the broader drift table is the time-eater because each row is a product decision plus possibly a schema migration.
