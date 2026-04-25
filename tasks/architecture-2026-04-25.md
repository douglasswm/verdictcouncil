# Architecture Proposal — VerdictCouncil 6-Agent Pipeline (Sprint 1 Spec)

**Date:** 2026-04-25
**Author:** Sprint 0 Task 0.4
**Status:** Draft for 0.12 user approval gate
**Feeds:** Sprint 1 tasks 1.A1.0 through 1.A1.11 + 1.A1.SEC1-3 + 1.C3a.1-5 + 1.DEP1.1-3
**Source audits cited inline:** 0.1 = schema audit, 0.2 = output-model audit, 0.3 = tool audit, SA = source-driven audit (Sprint 0/1).

---

## 1. Target topology diagram

```
                       ┌─────────────┐
START ──────────────▶ │   intake    │ (lightweight; phase node)
                       └──────┬──────┘
                              ▼
                       ┌─────────────┐    ┌─────────────┐
                       │ gate1_pause │──▶ │ gate1_apply │   (HITL: advance / rerun / halt)
                       └─────────────┘    └──────┬──────┘
                                                  ▼
                                         ┌──────────────────┐
                                         │ research_dispatch│  (plain node — resets parts)
                                         └────────┬─────────┘
                                                  │ list[Send] via add_conditional_edges (SA V-4)
                ┌─────────────────┬───────────────┼───────────────┬──────────────────┐
                ▼                 ▼               ▼               ▼                  ▼
        ┌──────────────┐  ┌──────────────┐ ┌───────────────┐ ┌────────────┐
        │research_     │  │research_     │ │research_      │ │research_   │
        │evidence      │  │facts         │ │witnesses      │ │law         │
        └──────┬───────┘  └──────┬───────┘ └──────┬────────┘ └─────┬──────┘
               │                 │                │                │
               └────────┬────────┴────────┬───────┴────────────────┘
                        ▼                 ▼
                              ┌────────────────┐
                              │ research_join  │ (merges dict[str, ResearchPart])
                              └───────┬────────┘
                                      ▼
                       ┌─────────────┐    ┌─────────────┐
                       │ gate2_pause │──▶ │ gate2_apply │   (HITL gate 2)
                       └─────────────┘    └──────┬──────┘
                                                  ▼
                                          ┌─────────────┐
                                          │  synthesis  │ (frontier model)
                                          └──────┬──────┘
                                                  ▼
                       ┌─────────────┐    ┌─────────────┐
                       │ gate3_pause │──▶ │ gate3_apply │   (HITL gate 3)
                       └─────────────┘    └──────┬──────┘
                                                  ▼
                                          ┌─────────────┐
                                          │   auditor   │ (frontier; ZERO tools)
                                          └──────┬──────┘
                                                  ▼
                       ┌─────────────┐    ┌─────────────┐
                       │ gate4_pause │──▶ │ gate4_apply │ ──▶ END
                       └─────────────┘    └─────────────┘
```

**HITL points:** every gate uses `interrupt({...})` with idempotent UPSERT of `case.status` *before* the call (SA V-7). Resume is `Command(resume={...})`-only (SA V-6). Gate decisions: `advance | rerun | halt`.

---

## 2. Per-agent roster (6 agents)

### 2.1 `intake`

- **Role (one line):** Triage a freshly submitted case — extract canonical fields, classify domain, score complexity, decide route.
- **Prior-topology equivalents:** Merges `case-processing` + `complexity-routing` (see 0.2 §3 mapping table).
- **Tool set:** `[parse_document]` only (per breakdown 1.A1.4 `PHASE_TOOLS["intake"]`; 0.3 §1).
- **Model tier:** **lightweight** (`gpt-5.4-nano`) — triage + structured-extraction workload, no deep reasoning. Cost-sensitive; ~70% of cases never reach research if `route=halt`.
- **Input fields (CaseState reads):** `case.case_id`, `case.run_id`, `case.raw_documents` (judge upload), `case.parties` (admin pre-fill), `case.case_metadata` (filed_date, jurisdiction, claim_amount, offence_code).
- **Output Pydantic model:** `IntakeOutput` (see 0.2 §4).
  - `domain: CaseDomainEnum` — typed (resolves 0.2 F#1 `domain: str` mismatch).
  - `parties: list[Party]` — typed sub-model.
  - `case_metadata: CaseMetadata` — typed sub-model (jurisdiction, claim_amount, filed_at).
  - `raw_documents: list[RawDocument]` — typed sub-model.
  - `routing_decision: RoutingDecision` — nested model containing `complexity: ComplexityEnum`, `complexity_score: int (ge=0, le=100)`, `route: RouteEnum`, `routing_factors: list[RoutingFactor]`, `vulnerability_assessment: VulnerabilityAssessment`, `escalation_reason: str | None`, `pipeline_halt: bool`. Eliminates the `normalize_agent_output()` auto-repair (0.2 §2 finding 5).
  - `model_config = ConfigDict(extra="forbid")`.
- **Rationale:** The two old agents (`case-processing`, `complexity-routing`) shared `case_metadata` as a write target — 0.2 §1.2 documents the `_COMPLEXITY_ROUTING_METADATA_FIELDS` workaround that hoists 7 stray top-level keys back into `case_metadata`. Merging into one phase eliminates the workaround, removes the 3-way `status` write contention (0.2 §1.1, §1.2, §1.9 all owned `status`), and lets a single lightweight model do all the front-door triage in one LLM call. The cost/latency hit of two cascaded calls disappears. `parse_document` is the only tool needed at this stage — citation/RAG retrieval is deferred to the research phase.

### 2.2 `research-evidence` (research subagent)

- **Role:** Classify evidence items, weight admissibility, score credibility per evidence piece.
- **Prior-topology equivalents:** `evidence-analysis` (Gate 2 peer in old graph).
- **Tool set:** `[parse_document]` (re-reads case docs as needed; per breakdown 1.A1.4 `RESEARCH_TOOLS["evidence"]`).
- **Model tier:** **frontier** (`gpt-5.4`) — admissibility judgment is reasoning-heavy.
- **Input fields:** `case.case_metadata`, `case.raw_documents`, `case.intake.routing_decision` (read-only — for context).
- **Output Pydantic model:** `EvidenceResearch` (0.2 §4).
  - `evidence_items: list[EvidenceItem]` — wires up the orphan model at `agent_schemas.py:55-62` (0.2 §2 finding 2). Tighten `strength: Literal["weak","moderate","strong"]`, `evidence_type: Literal[...]`.
  - `credibility_scores: dict[str, CredibilityScore]` — typed values (shared sub-model).
  - `model_config = ConfigDict(extra="forbid")`.
- **Rationale:** Kept as a separate research subagent (rather than merged with facts/witnesses) because the reasoning model and prompt are evidence-specific (admissibility flags, exhibit chains-of-custody) and run in parallel with the other three under the same dispatch (see §4). Drops the `cross_reference` LLM-wrapper tool (0.3 §2 — DROP) since strong-reasoning models can produce the same contradictions/corroborations natively in structured output.

### 2.3 `research-facts` (research subagent)

- **Role:** Build the fact ledger — extracted facts, agreed/disputed status, timeline.
- **Prior-topology equivalents:** `fact-reconstruction`.
- **Tool set:** `[parse_document]`.
- **Model tier:** **frontier** (`gpt-5.4`).
- **Input fields:** `case.raw_documents`, `case.case_metadata`, `case.intake.routing_decision`.
- **Output Pydantic model:** `FactsResearch`.
  - `facts: list[ExtractedFactItem]` — wires up orphan model at `agent_schemas.py:68-74` (0.2 §2 finding 2). Tighten `confidence: Confidence` (enum) — resolves the 3-way confidence mismatch (0.2 §2 finding 3 — `str` vs `int | None` vs free dict).
  - `timeline: list[TimelineEvent]` — typed sub-model with ISO-8601-validated dates.
  - `model_config = ConfigDict(extra="forbid")`.
- **Rationale:** Kept separate. Facts vs evidence is a real distinction in tribunal practice — facts are propositions, evidence is proof. The old `timeline_construct` tool (0.3 §3 — DROP) was a `strptime + sort` over <50 events; the frontier model can emit a chronologically ordered timeline directly. If date-parsing drift appears in eval, re-introduce a small non-tool `parse_dates` utility (0.3 §3 / open question 3).

### 2.4 `research-witnesses` (research subagent)

- **Role:** Score witness credibility (PEAR-like rubric), flag contradictions across statements, draft a question bank.
- **Prior-topology equivalents:** `witness-analysis`.
- **Tool set:** `[parse_document]`.
- **Model tier:** **frontier** (`gpt-5.4`).
- **Input fields:** `case.raw_documents`, `case.parties`, `case.intake.routing_decision`.
- **Output Pydantic model:** `WitnessesResearch`.
  - `witnesses: list[Witness]` — typed sub-model with nested `statements: list[Statement]` and `credibility: CredibilityScore`.
  - `credibility: dict[str, CredibilityScore]` — keyed by witness id.
  - `model_config = ConfigDict(extra="forbid")`.
  - Drops SAM-legacy `Witnesses.statements` peer field (0.2 F#10).
- **Rationale:** Kept separate because witness credibility is the most legally-sensitive of the four research workloads (PEAR factors, demeanour, prior inconsistent statements). Drops the `generate_questions` LLM-wrapper (0.3 §4 — DROP); the agent is itself an LLM whose job is to interrogate credibility, so a sibling LLM tool call is round-trip waste with zero capability lift.

### 2.5 `research-law` (research subagent)

- **Role:** Retrieve statutes, practice directions, and precedents relevant to the case; supply citation provenance.
- **Prior-topology equivalents:** `legal-knowledge`.
- **Tool set:** `[search_legal_rules, search_precedents]` (0.3 §6, §7; rename of `search_domain_guidance` per 0.3).
- **Model tier:** **frontier** (`gpt-5.4`).
- **Input fields:** `case.case_metadata`, `case.intake.routing_decision`, `case.intake.domain` (drives vector_store_id selection).
- **Output Pydantic model:** `LawResearch`.
  - `legal_rules: list[LegalRule]` — typed sub-model (replaces bare `list[dict[str, Any]]`).
  - `precedents: list[Precedent]` — typed sub-model.
  - `precedent_source_metadata: PrecedentProvenance` — moved out of the `common.py:355-357` side-channel into the schema (closes 0.2 finding 4 / F8).
  - `legal_elements_checklist: list[LegalElement]` — closes the 3-field schema gap (0.2 §1.6: ownership lists 5, schema declared 2).
  - `suppressed_citations: list[SuppressedCitation]` — same.
  - `model_config = ConfigDict(extra="forbid")`.
- **Rationale:** Only research subagent that retrieves new content from outside the case file. Tool scope is least-privilege (SA breakdown 1.A1.4 P2 finding) — search tools live nowhere else in the graph. Folds the 0.2 leak (`precedent_source_metadata` set post-validation in `common.py`) into a first-class field; `make_tools()` side-channel goes away in Sprint 1 by setting the field inside the node post-tool-call.

### 2.6 `synthesis`

- **Role:** Build IRAC arguments, write pre-hearing brief, draft judicial questions, give a preliminary conclusion + confidence.
- **Prior-topology equivalents:** Merges `argument-construction` + `hearing-analysis`.
- **Tool set:** `[search_precedents]` only (per breakdown 1.A1.4) — for targeted follow-up if the research phase missed a citation. No `parse_document` (the documents are read; we operate on extracted facts/evidence/witnesses/law).
- **Model tier:** **frontier** (`gpt-5.4`).
- **Input fields:** `case.intake`, `case.research_output` (the merged `ResearchOutput` from §4 join).
- **Output Pydantic model:** `SynthesisOutput`.
  - `arguments: ArgumentSet` — typed sub-model (claimant_position, respondent_position, contested_points, supporting_refs, counter_arguments). Replaces bare `arguments: dict[str, Any]` (0.2 §1.7).
  - `preliminary_conclusion: str`.
  - `confidence: Confidence` — unified enum (0.2 §6 q3) OR `int (ge=0, le=100)` if user picks numeric (open question §10).
  - `reasoning_chain: list[ReasoningStep]` — typed.
  - `uncertainty_flags: list[UncertaintyFlag]` — typed.
  - `model_config = ConfigDict(extra="forbid")` — flips the inherited `extra="allow"` on `HearingAnalysis` (0.2 F#7).
- **Rationale:** The two old agents (`argument-construction`, `hearing-analysis`) wrote disjoint fields (`arguments` vs `hearing_analysis.*`) but both fed the same downstream auditor and judge. Sequencing them as separate LLM calls added latency without gating value. One frontier-tier call with a typed `SynthesisOutput` produces both the IRAC argument structure and the preliminary conclusion in a single round-trip. `confidence_calc` is *not* an agent tool here — per 0.3 §5 it's demoted to an internal utility called from the node (or removed entirely); LLMs are unreliable at fixed-weight numeric scoring.

### 2.7 `auditor`

- **Role:** Independent fairness audit of the synthesised verdict — no retrieval, judges only what's in state.
- **Prior-topology equivalents:** `hearing-governance` (kept verbatim, lightly tightened).
- **Tool set:** `[]` — **zero tools** (breakdown 1.A1.4 P2 finding; auditor independence requires it cannot retrieve new evidence).
- **Model tier:** **frontier** (`gpt-5.4`).
- **Input fields:** entire `case` (intake + research_output + synthesis). Read-only.
- **Output Pydantic model:** `AuditOutput`.
  - `fairness_check: FairnessCheck` — kept as-is (already strict, `extra="forbid"` per 0.2 §1.9).
  - `status: CaseStatusEnum` — promote `str` to enum (the only weakness in the existing schema).
  - `model_config = ConfigDict(extra="forbid")`.
- **Rationale:** `hearing-governance` is the only agent already in OpenAI strict JSON-schema mode (0.2 §1.9). Kept as the single audit agent because: (a) independence is structural — auditor mustn't be able to fetch new precedents that could rationalise an unfair verdict; (b) existing IMDA-pillar evidence references it as the independent fairness control. Tightening to `extra="forbid"` and `CaseStatusEnum` finalises the strict-mode rollout.

---

## 3. LangSmith prompt roster (7 prompts)

| Prompt name                              | Agent              | Role one-liner                                                                          |
|------------------------------------------|--------------------|----------------------------------------------------------------------------------------|
| `verdict-council/intake`                 | `intake`           | Triage, classify domain, score complexity, decide route. Lightweight model.             |
| `verdict-council/research-evidence`      | `research-evidence`| Classify evidence items; weight admissibility; flag contradictions natively.            |
| `verdict-council/research-facts`         | `research-facts`   | Build the fact ledger and timeline; mark agreed/disputed/contradicted.                  |
| `verdict-council/research-witnesses`     | `research-witnesses`| PEAR-style credibility scoring + question bank.                                         |
| `verdict-council/research-law`           | `research-law`     | Retrieve statutes + precedents; record citation provenance + suppressed citations.      |
| `verdict-council/synthesis`              | `synthesis`        | IRAC arguments, pre-hearing brief, judicial questions, preliminary conclusion.          |
| `verdict-council/audit`                  | `auditor`          | Independent fairness audit — no retrieval, fairness_check + status only.                |

Each prompt explicitly references its phase Pydantic schema (per breakdown 1.C3a.2). Prompts are pulled via `get_prompt(name) -> tuple[str, str]` (template, commit_hash) and the commit hash flows to LangSmith run metadata via `RunnableConfig(metadata={"prompt_commit": prompt_commit})` (SA F-5).

---

## 4. Send fan-out + join signatures

### 4.1 Dispatch (router-style; SA V-4 mandatory)

```python
# pipeline/graph/research.py

from typing import Annotated
from langgraph.types import Send

# Reset node — plain state update, no LLM. Idempotent re-entry safe.
async def research_dispatch_node(state: GraphState) -> dict:
    """Reset the research_parts dict so re-entry from gate2 starts clean."""
    return {"research_parts": {}}    # dict-keyed; under merge_dict reducer this REPLACES

# Conditional-edge router — returns list[Send].
# NOTE (SA V-4 / F-2): MUST be wired via add_conditional_edges(node, router, [destinations]),
# NOT a node returning list[Send]. The router fn is the second arg to add_conditional_edges.
def route_to_research_subagents(state: GraphState) -> list[Send]:
    payload = {
        "case": state["case"],
        "extra_instructions": state.get("extra_instructions", {}),
    }
    return [
        Send("research_evidence",  payload),
        Send("research_facts",     payload),
        Send("research_witnesses", payload),
        Send("research_law",       payload),
    ]
```

Wiring (in `builder.py`):

```python
g.add_node("research_dispatch", research_dispatch_node)
g.add_conditional_edges(
    "research_dispatch",
    route_to_research_subagents,
    ["research_evidence", "research_facts", "research_witnesses", "research_law"],
)
```

### 4.2 Subagent return shape (dict-keyed accumulator — SA F-2)

```python
# pipeline/graph/state.py

from typing import Annotated, TypedDict

def merge_dict(left: dict, right: dict) -> dict:
    """Reducer: right-side overrides left for matching keys; missing keys preserved."""
    return {**left, **right}

class GraphState(TypedDict, total=False):
    case: CaseEnvelope
    research_parts: Annotated[dict[str, ResearchPart], merge_dict]
    extra_instructions: dict[str, str]
    _pending_action: dict | None
    # ... other fields ...
```

Each research subagent returns a dict update keyed by its scope:

```python
# pipeline/graph/agents/factory.py — make_research_subagent("evidence") body
return {"research_parts": {"evidence": evidence_research_output}}
```

### 4.3 Join signature

```python
# pipeline/graph/research.py

async def research_join_node(state: GraphState) -> dict:
    parts = state["research_parts"]   # dict[str, ResearchPart]
    merged = ResearchOutput.from_parts(parts)   # classmethod handles missing keys
    return {"case": {"research_output": merged}}
```

`ResearchOutput.from_parts(parts: dict[str, ResearchPart]) -> ResearchOutput` is a classmethod on the Pydantic model; missing keys produce a `ResearchOutput.partial=True` flag that the gate2 UI surfaces to the judge.

### 4.4 Re-entry / phase-rerun semantics

- **First entry:** `research_parts` does not exist in state → reducer treats as `{}`; subagents populate.
- **Re-entry from gate2 rerun:** `research_dispatch_node` returns `{"research_parts": {}}`. Under `merge_dict`, this replaces the full dict because the merge of `{...} | {}` keeps existing keys — **but** the dispatch is followed by 4 new `Send`s that each return `{"research_parts": {scope: new_output}}`, and `merge_dict` overwrites per-scope on key collision. Net effect: dict is fully refreshed.
- **External rerun (out-of-band, e.g. judge calls `/cases/{id}/rerun?phase=research`):** the rerun handler in `cases.py` calls `graph.update_state(config, {"research_parts": Overwrite({})})` (SA V-3 / F-2 option 3) before re-entering the dispatch node. `Overwrite` is the only way to reset state-from-outside (SA F-2).

---

## 5. Tool roster (final)

Per 0.3 §"Proposed final roster (Sprint 1)":

| Tool                     | Purpose                                                            | Used by                                  |
|--------------------------|--------------------------------------------------------------------|------------------------------------------|
| `parse_document`         | Deterministic file ingest → pages/tables/text/sanitization.        | `intake`, `research-evidence`, `research-facts`, `research-witnesses` |
| `search_precedents`      | PAIR API — case-law retrieval with rate-limit/cache/circuit-breaker. | `research-law`, `synthesis`             |
| `search_legal_rules`     | OpenAI vector-store RAG over per-domain statutes + bench books. (Renamed from `search_domain_guidance` — 0.3 §7.) | `research-law` |

**Demoted (still in repo as utilities, not registered as agent tools):** `confidence_calc` (0.3 §5 — invoke directly from synthesis node if used at all).

**Dropped entirely (LLM-wrapper or trivial):** `cross_reference`, `timeline_construct`, `generate_questions` (0.3 drop list).

`parse_document` internals: 0.3 §1 recommends replacing the OpenAI Responses-API extraction with a deterministic loader (PyMuPDF/pdfplumber + `RecursiveCharacterTextSplitter`) per `langchain-rag` skill. The `@tool` surface stays unchanged. Open question §10 — Sprint 1 or later.

---

## 6. Per-phase response_format decision

Per SA F-8: **explicit `ToolStrategy(Schema)`** for every phase using `extra="forbid"`. This gives deterministic retry on validation failure (`handle_errors=True` is the default in Form B; SA V-11). Form A (`response_format=Schema`) auto-picks `ProviderStrategy` for native-structured-output models, which has different retry semantics.

| Phase                 | Schema                | response_format form                            | Why |
|-----------------------|-----------------------|------------------------------------------------|-----|
| `intake`              | `IntakeOutput`        | `ToolStrategy(IntakeOutput)`                    | `extra="forbid"` is load-bearing (1.A1.SEC3 regression test). |
| `research-evidence`   | `EvidenceResearch`    | `ToolStrategy(EvidenceResearch)`                | Same — strict typed output. |
| `research-facts`      | `FactsResearch`       | `ToolStrategy(FactsResearch)`                   | Same. |
| `research-witnesses`  | `WitnessesResearch`   | `ToolStrategy(WitnessesResearch)`               | Same. |
| `research-law`        | `LawResearch`         | `ToolStrategy(LawResearch)`                     | Same; tool calls (search_*) interleave with structured output. |
| `synthesis`           | `SynthesisOutput`     | `ToolStrategy(SynthesisOutput)`                 | Same. |
| `auditor`             | `AuditOutput`         | `ToolStrategy(AuditOutput)`                     | Already strict (0.2 §1.9); explicit form for retry parity. |

`handle_errors=True` (default) gives one corrective retry on Pydantic ValidationError. 1.A1.SEC3's regression test asserts a ValidationError on undeclared field — explicit `ToolStrategy` ensures the retry path fires deterministically (SA F-8).

---

## 7. State schema deltas

Cross-references 0.2 §3 mapping table; this section finalises it.

### 7.1 Added

| Field                       | Type                                            | Owner       | Notes |
|-----------------------------|-------------------------------------------------|-------------|-------|
| `research_parts`            | `Annotated[dict[str, ResearchPart], merge_dict]`| 4 subagents | Replaces what would have been `Annotated[list, operator.add]` per SA F-2. |
| `case.research_output`      | `ResearchOutput`                                | `research_join` | Merged result of the 4 parts. |
| `case.intake`               | `IntakeOutput`                                  | `intake`    | New typed home for fields previously scattered across `case.domain`, `case.case_metadata`, `case.parties`, `case.raw_documents`. |
| `case.synthesis`            | `SynthesisOutput`                               | `synthesis` | New typed home for `arguments`, `hearing_analysis`. |
| `case.audit`                | `AuditOutput`                                   | `auditor`   | New typed home for `fairness_check` + final `status`. |
| `_pending_action`           | `dict \| None`                                  | gate nodes  | Carries `interrupt()` decision between pause and apply nodes (per breakdown 1.A1.7 stub). |

### 7.2 Removed

Per 0.2 F#10 — drop SAM-legacy duplicates that no agent in the new topology writes:

| Field                                        | Reason |
|---------------------------------------------|--------|
| `EvidenceAnalysis.exhibits`                 | Duplicates `evidence_items`; never written by current agents. |
| `Witnesses.statements`                      | Duplicates `witnesses[*].statements`; never written. |
| `FIELD_OWNERSHIP` (logical, not a CaseState field) | Replaced by Pydantic `extra="forbid"` (1.A1.SEC3). |

### 7.3 Kept but re-owned (single writer per phase)

| Field         | Old writers (per 0.2 §1)                                            | New writer            |
|---------------|---------------------------------------------------------------------|----------------------|
| `case.status` | `case-processing`, `complexity-routing`, `hearing-governance` (3-way write) | `auditor` only, post-audit. Gate apply nodes use `upsert_case_status()` for HITL state (`awaiting_review_gate*`); not an agent write. |
| `case.case_metadata` | `case-processing`, `complexity-routing` (overlap)              | `intake` only.       |

The old 3-writer status pattern (0.2 finding 1) collapses into a single `auditor` writer + the gate apply UPSERT path (which uses a different lifecycle — `awaiting_review_gate*` is HITL queueing state, not agent output).

### 7.4 Re-typed

| Field                       | Old type                               | New type                          |
|-----------------------------|----------------------------------------|-----------------------------------|
| `domain`                    | `str` (in output schema; enum in CaseState) | `CaseDomainEnum` everywhere   |
| `status`                    | `str` (in 3 schemas)                   | `CaseStatusEnum`                  |
| `confidence` (facts)        | `str`                                  | `Confidence` enum (or `int 0-100` — open Q §10) |
| `confidence_score` (synth)  | `int \| None` (no bound)               | Same as above — unified scale     |
| `evidence_items`            | `list[Any]` / `list[dict[str, Any]]`   | `list[EvidenceItem]`              |
| `facts`                     | `list[dict[str, Any]]`                 | `list[ExtractedFactItem]`         |
| `legal_rules`, `precedents` | `list[dict[str, Any]]`                 | `list[LegalRule]`, `list[Precedent]` |

### 7.5 Schema version bump

`CaseState.schema_version: int = 2 → 3` (per 0.1 §2 + 0.2 §3). 0.1 §summary7 notes the version is enforced inside the JSON `case_state` payload, not as a column — `pipeline_state.py:42` `CURRENT_SCHEMA_VERSION` lift to 3, accepting fail-loud rejection of any in-flight v2 rows at deployment cutover.

---

## 8. Phase-level rerun semantics

**Today** (per breakdown rev 3 scope summary): rerun keyed by **agent name**, e.g. `{"agent": "argument-construction"}`, handled in `cases.py:1640-1758`.

**Target:** rerun keyed by **phase**, e.g. `{"phase": "synthesis"}` or `{"phase": "research"}`. Phases are the 6 agents + the research bundle (`intake | research | synthesis | audit`).

### 8.1 Rerun handler shape

```python
# api/routes/cases.py — rerun_case (rewritten)

async def rerun_case(case_id: UUID, body: RerunRequest) -> ...:
    phase = body.phase  # Literal["intake","research","synthesis","audit"]
    config = {"configurable": {"thread_id": str(case_id)}}

    # 1. Locate the historical state at the entry of the requested phase.
    history = list(graph.get_state_history(config))          # SA V-9
    target = next(s for s in history if s.next == (entry_node_for(phase),))

    # 2. If rerunning research, also reset the dict-keyed accumulator.
    if phase == "research":
        graph.update_state(
            target.config,
            {"research_parts": Overwrite({})},               # SA V-3 / F-2 option 3
        )

    # 3. Optionally inject judge corrections.
    if body.extra_instructions:
        graph.update_state(target.config, {"extra_instructions": body.extra_instructions})

    # 4. Re-enter from the historical config — LangGraph fork.
    await graph.ainvoke(None, target.config)                 # SA V-9
```

### 8.2 Entry-node mapping

| Phase       | Entry node          |
|-------------|---------------------|
| `intake`    | `intake`            |
| `research`  | `research_dispatch` |
| `synthesis` | `synthesis`         |
| `audit`     | `auditor`           |

### 8.3 Downstream re-run cascade

When phase X is rerun, all phases after X must also re-run. The graph's existing edges handle this naturally — the fork enters at X and proceeds through to END, hitting each gate `interrupt()` along the way (judges can fast-forward by replaying their prior decisions via Command resume).

| Rerun target | Phases that re-run                                  | Notes |
|--------------|-----------------------------------------------------|-------|
| `intake`     | intake → research → synthesis → audit               | Full re-run; `research_parts` must be cleared. |
| `research`   | research → synthesis → audit                        | `research_parts` cleared via `Overwrite({})`. |
| `synthesis`  | synthesis → audit                                   | Reads existing `research_output`. |
| `audit`      | audit only                                          | Auditor reads full prior state. |

---

## 9. Migration boundaries (input to Task 0.5)

DDL changes are listed below for 0.5 to formalise. Migration numbering starts at **0025** per 0.1 drift finding (HEAD = `0024_pipeline_events_replay.py`).

| # | Change                                                                                     | Sprint | Notes |
|---|--------------------------------------------------------------------------------------------|--------|-------|
| 0025 | Bump `case_state.schema_version` payload constant from 2 to 3 (no DDL — code change in `pipeline_state.py`) | 1      | Lands with 1.A1.5 / 1.A1.7 schema rollout. Fail-loud on stored v2 rows at deploy. |
| 0026 | `pipeline_events.schema_version` bump path — accept v1 (legacy) and v2 (new event kinds: `phase_started`, `subagent_dispatched`, `subagent_complete`, `phase_complete`) | 1     | 0.1 §3 / summary 2: today hardcoded to 1 with no bump path. New SSE events from 1.A1.1/1.A1.9 need v2. |
| 0027 | Index `audit_logs(agent_name)` and `audit_logs(created_at)`                                 | 2      | 0.1 §1 cruft + summary 5 — filter columns are unindexed. |
| 0028 | Index `cases(domain_id)`                                                                    | 2      | 0.1 §5 + summary 5 — FK has no index, every domain-scoped read is a seqscan. |
| 0029 | Index `domain_documents(domain_id, status)`                                                 | 2      | 0.1 §8 cruft — admin UI lists per-domain by status. |
| 0030 | Drop `cases.domain` enum column (after readers migrated to `domain_id`)                     | 2      | 0.1 summary 1 — every reader (cases.py:169, 212, 622, 638, 905, 1329; dashboard.py:37; hearing_pack.py:220; workers/tasks.py:164) must be moved first. Single migration, multi-PR readers cutover. |
| 0031 | Drop `calibration_records` table                                                            | 2      | 0.1 §6 — fully dead. Decision: drop (no backfill plan in scope). |
| 0032 | Drop `domains.provisioning_started_at` and `domains.provisioning_attempts`                  | 2      | 0.1 §7 — dead columns. |
| 0033 | Add `schema_version: int` JSON-key requirement to `cases.intake_extraction`, `cases.gate_state`, `cases.judicial_decision` payloads (writers updated; backfill `1` for existing rows) | 2 | 0.1 summary 6 — unversioned JSONB blobs. |
| 0034 | `pipeline_jobs.payload` — same versioning treatment                                          | 2      | Same. |
| 0035 | New `judge_corrections` table (shape decided in 0.5)                                        | 2      | Mentioned in 0.1 drift findings as missing; needed by C3a workflow if judge corrections are persisted. |
| 0036 | `pipeline_checkpoints` — change PK to `(case_id, run_id, agent_name)` OR add append-only event log table | 4 | 0.1 §2 cruft — current PK overwrites per-step state, blocking step-by-step replay. Sprint 4 owns finer-grained replay (4.A3.x). |
| 0037 | `audit_logs` — UUID PK + FK to a new `agent_runs` table (per breakdown 4.C4.1 P1-6 finding) | 4      | Audit table FK integrity rewrite. |

DDL bodies are 0.5's job. This list is the input enumeration.

---

## 10. Open questions

These cannot be resolved from the audits alone — flagged for user decision before/at the 0.12 approval gate.

1. **Confidence scale (Confidence enum vs 0-100 int vs 0-1 float).** 0.2 §6 q3 raises this. Recommend **`Confidence` enum (`low | medium | high`)** for human-readable judge UX, but the architecture works with any of the three. Decision unblocks `FactsResearch.facts[*].confidence`, `WitnessesResearch.credibility`, and `SynthesisOutput.confidence`.

2. **Strict-mode rollout depth.** 0.2 §6 q1 — once `dict[str, Any]` is gone, do we move *every* phase to OpenAI strict JSON-schema mode (today only `auditor` is strict)? Recommend yes; cost is one-time prompt revision per phase. Decision affects 1.A1.SEC3 scope.

3. **CaseStatusEnum shrink.** 0.2 §6 q4 — with phase-level gates, do we drop the `awaiting_review_gate1..4` variants? Recommend keeping them (gate apply nodes still need them for case-list filtering), but the variants should be re-derived from a `(gate_index, status)` pair rather than 4 distinct enum values.

4. **`confidence_calc` final disposition.** 0.3 open question 1. Recommend **delete**: synthesis emits `confidence` as a direct field of `SynthesisOutput`, scored by the LLM. The fixed-weight calculator was never used by the agent reliably anyway. Alternative: keep as a non-tool Python utility called inside the synthesis node post-LLM, with the calculator's score *replacing* the LLM's emitted `confidence` field. User to choose.

5. **`parse_document` internals replacement timing.** 0.3 open question 2 — keep OpenAI Responses-API extraction during transition, or land deterministic loader (PyMuPDF/pdfplumber + RecursiveCharacterTextSplitter) inside Sprint 1? Recommend **defer to Sprint 2** so Sprint 1 is purely topology + factory + middleware; the `@tool` contract is unchanged either way.

6. **`HumanInTheLoopMiddleware` for future tool-call gates.** SA F-7 — informational only; not a Sprint 1 blocker but should be noted in 0.11a agent-design doc so a future tool-call gate doesn't reinvent the pattern.

7. **`judge_corrections` table shape (migration 0035).** Mentioned in 0.1 drift findings as missing. 0.5 will write the DDL; this proposal needs the user to confirm the column set: `(id, case_id, gate_index, agent_name, correction_text, applied_at, judge_id)`?

8. **Dual-domain cutover sequencing (migration 0030).** Sprint 2 task to drop `cases.domain` enum after every reader migrates to `domain_id`. The reader-migration PRs are not currently enumerated as tasks — recommend adding them to Sprint 2 task list at 0.5 time.

---

**End of architecture proposal.** Approval gate: 0.12.
