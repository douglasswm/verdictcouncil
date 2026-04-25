# Output-Model Audit — Sprint 0 Task 0.2

**Date:** 2026-04-25
**Scope:** Inventory every Pydantic output model written by the current 9-agent pipeline, flag retry-inducing patterns, and propose the field-to-phase mapping for the target 6-phase architecture.
**Feeds:** Sprint 0.4 (architecture proposal), Sprint 0.5 (target schema doc).

> All paths below are relative to `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/`. The orchestration root re-exposes them under `VerdictCouncil_Backend/`.

---

## 0. Source-of-truth files

| File | Role |
|---|---|
| `src/pipeline/agent_schemas.py` | Per-agent Pydantic output models, strict-mode mapping, `validate_agent_output()` |
| `src/shared/case_state.py` | `CaseState`, sub-models (`FairnessCheck`, `HearingAnalysis`, `EvidenceAnalysis`, `ExtractedFacts`, `Witnesses`, `AuditEntry`), enums (`CaseStatusEnum`, `CaseDomainEnum`) |
| `src/shared/validation.py` | `FIELD_OWNERSHIP`, `normalize_agent_output()` (the complexity-routing auto-repair), `validate_field_ownership()` |
| `src/pipeline/graph/prompts.py` | `AGENT_ORDER`, `GATE_AGENTS`, `GATE2_PARALLEL_AGENTS`, `AGENT_MODEL_TIER` |
| `src/pipeline/graph/nodes/*.py` | Thin wrappers (~12 LOC each) that just call `_run_agent_node("<name>", state)` from `common.py` |
| `src/pipeline/graph/nodes/common.py` | The shared LLM+tool loop. **All** structured-output behaviour lives here, NOT in `create_agent`/`response_format` calls — the project uses raw `ChatOpenAI.bind_tools(...)` + a `---STATE---` JSON marker contract (see lines 124-135). |

### Important architectural note (verified)

The codebase **does not** use LangChain `create_agent(..., response_format=...)`. Structured output is enforced via:
1. A system-prompt contract (narration text + `---STATE---` marker + JSON object), set in `common.py:124-135`.
2. A post-parse Pydantic round-trip via `validate_agent_output()` (`agent_schemas.py:144-159`) — *log-only*, never raises.
3. `normalize_agent_output()` (`validation.py:52-74`) — auto-repair of complexity-routing's stray top-level keys.
4. `validate_field_ownership()` (`validation.py:77-95`) — strips off any field outside `FIELD_OWNERSHIP[agent]`.
5. OpenAI strict JSON-schema mode is enabled **only for `hearing-governance`** (`agent_schemas.py:103-105`); every other agent is `json_object` mode with `dict[str, Any]` escape hatches.

This means the "retry-inducing field" risk surface is the LLM JSON happy-path only — there is no automatic retry on validation failure today. That makes the inventory below the input list for Sprint 0.4's hardening proposal.

---

## 1. Per-agent inventory (current 9 agents)

Agents are listed in `AGENT_ORDER` (`prompts.py:20-30`). For each agent: node file, output schema, fields, retry/validation flags.

### 1.1 case-processing (Gate 1)

- **Node:** `src/pipeline/graph/nodes/case_processing.py:11` — wrapper for `_run_agent_node("case-processing", ...)`.
- **Output schema:** `CaseProcessingOutput` — `agent_schemas.py:40-47`.
- **Field ownership:** `{case_id, run_id, domain, status, parties, case_metadata, raw_documents}` (`validation.py:19-27`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `case_id` | `str` | yes | No format constraint. Should be UUID4 (`CaseState.case_id` uses `default_factory=uuid.uuid4`). |
| `run_id` | `str` | yes | Same — should be UUID4. |
| `domain` | `str \| None` | optional | **Mismatch:** `CaseState.domain` is `CaseDomainEnum` (`case_state.py:25-27`: only `small_claims` / `traffic_violation`). Schema accepts any string — coercion happens in CaseState validation, but invalid values silently land here. |
| `status` | `str = "pending"` | optional | **Mismatch:** `CaseState.status` is `CaseStatusEnum`. The schema accepts free-form strings; `common.py:344-353` coerces invalid values to `failed` post-hoc. |
| `parties` | `list[dict[str, Any]]` | optional | Bare dict — no `Party` sub-model. |
| `case_metadata` | `dict[str, Any]` | optional | Bare dict. |
| `raw_documents` | `list[dict[str, Any]]` | optional | Bare dict — no `RawDocument` sub-model despite known shape (id, type, content, …). |

**Retry-inducing flags:**
- `domain` accepts any string but downstream consumers expect the enum → silent narrowing.
- `status` overlaps with `CaseStatusEnum` but not enforced → invalid values trigger post-hoc coercion in `common.py`.
- `raw_documents`/`parties` are bare dicts — no schema, no required keys.

**Duplicate-model flags:**
- Owns `status` together with `complexity-routing` and `hearing-governance` (3-way write).

---

### 1.2 complexity-routing (Gate 1)

- **Node:** `src/pipeline/graph/nodes/complexity_routing.py:11`.
- **Output schema:** `ComplexityRoutingOutput` — `agent_schemas.py:50-52`.
- **Field ownership:** `{status, case_metadata}` (`validation.py:28`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `status` | `str = "processing"` | optional | Same enum mismatch as 1.1. |
| `case_metadata` | `dict[str, Any]` | optional | Bare dict. The agent is *expected* to nest `complexity`, `complexity_score`, `route`, `routing_factors`, `vulnerability_assessment`, `escalation_reason`, `pipeline_halt` inside it. |

**Retry-inducing flags (HIGH):**
- The schema gives **no structure** for the routing decision. `validation.py:5-15` (`_COMPLEXITY_ROUTING_METADATA_FIELDS`) hard-codes the seven keys the LLM is supposed to nest, and `normalize_agent_output()` (`validation.py:52-74`) hoists them back into `case_metadata` when the LLM emits them at the top level. **This is a workaround for a missing nested schema.**
- No constraints on `complexity_score` (likely 0-100), no `Literal` for `route` (likely `gate2|escalate|halt`), no enum for `complexity` (likely `simple|moderate|complex`).

**Duplicate-model flags:**
- Owns `status`. Writes `case_metadata` with no isolation between routing-specific and case-processing-set keys → silent overwrite risk.

---

### 1.3 evidence-analysis (Gate 2 — parallel)

- **Node:** `src/pipeline/graph/nodes/evidence_analysis.py:11`.
- **Output schema:** `EvidenceAnalysisOutput` — `agent_schemas.py:64-65`.
- **Field ownership:** `{evidence_analysis}` (`validation.py:29`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `evidence_analysis` | `dict[str, Any]` | yes | Bare dict. **`EvidenceItem` exists in the same file (lines 55-62) but is never referenced** — defined and orphaned. |

**`EvidenceItem` (orphaned, lines 55-62):**
- `evidence_type: str`, `strength: str`, `description: str`, `source_ref: str | None`, `admissibility_flags: dict[str, Any] | None`, `linked_claims: list[str]`.
- Should become the element type of `evidence_analysis.evidence_items` and replace the bare list in `EvidenceAnalysis` (`case_state.py:48-54`, `evidence_items: list[Any]`).

**Retry-inducing flags (HIGH):**
- Bare `dict[str, Any]` means any LLM JSON parses; no constraints on item shape, no required `evidence_items` key.
- `strength` is unconstrained string — needs `Literal["weak","moderate","strong"]` or similar.
- `evidence_type` unconstrained — likely a small enum.
- Mirror `CaseState.EvidenceAnalysis` carries both `evidence_items` and `exhibits` (SAM legacy) → naming drift.

---

### 1.4 fact-reconstruction (Gate 2 — parallel)

- **Node:** `src/pipeline/graph/nodes/fact_reconstruction.py:11`.
- **Output schema:** `FactReconstructionOutput` — `agent_schemas.py:77-78`.
- **Field ownership:** `{extracted_facts}` (`validation.py:30`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `extracted_facts` | `dict[str, Any]` | yes | Bare dict. **`ExtractedFactItem` defined (lines 68-74) but never referenced.** |

**`ExtractedFactItem` (orphaned, lines 68-74):**
- `description: str`, `date: str | None`, `confidence: str = "medium"`, `status: str = "agreed"`, `source_refs: list[str]`, `corroboration: dict[str, Any] | None`.
- `confidence: str` here vs `HearingAnalysis.confidence_score: int | None` (`case_state.py:43`) — **type mismatch confirmed**.
- `date: str` — no ISO-8601 validator.
- `status: str = "agreed"` — overloaded keyword; case-level `status` is `CaseStatusEnum`, but here it's per-fact (likely `agreed|disputed|contradicted`).

**Retry-inducing flags (HIGH):**
- Bare top-level dict.
- `confidence` as freeform string is the canonical example for the unification work in 0.4.

---

### 1.5 witness-analysis (Gate 2 — parallel)

- **Node:** `src/pipeline/graph/nodes/witness_analysis.py:11`.
- **Output schema:** `WitnessAnalysisOutput` — `agent_schemas.py:81-82`.
- **Field ownership:** `{witnesses}` (`validation.py:31`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `witnesses` | `dict[str, Any]` | yes | Bare dict. No `Witness`/`Statement` sub-model. |

`CaseState.Witnesses` (`case_state.py:64-70`) carries `witnesses`, `statements` (SAM legacy), `credibility` — none typed.

**Retry-inducing flags (HIGH):**
- Same pattern: open dict, no element schema, no credibility scale enum/range.

---

### 1.6 legal-knowledge (Gate 2 — parallel)

- **Node:** `src/pipeline/graph/nodes/legal_knowledge.py:11`.
- **Output schema:** `LegalKnowledgeOutput` — `agent_schemas.py:85-87`.
- **Field ownership:** `{legal_rules, precedents, precedent_source_metadata, legal_elements_checklist, suppressed_citations}` (`validation.py:32-38`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `legal_rules` | `list[dict[str, Any]]` | optional | Bare. No `LegalRule` sub-model. |
| `precedents` | `list[dict[str, Any]]` | optional | Bare. No `Precedent` sub-model. |

**Schema-vs-ownership delta:** `FIELD_OWNERSHIP["legal-knowledge"]` lists 5 fields, but `LegalKnowledgeOutput` only validates 2. The other three (`precedent_source_metadata`, `legal_elements_checklist`, `suppressed_citations`) are written **outside the schema**, two routes:

1. **`precedent_source_metadata`:** injected by `common.py:355-357` — pulled out of `precedent_meta.metadata` (a side-channel returned by `make_tools()`), bypassing the LLM altogether. **Confirmed prior finding** — but the side-channel is in `common.py`, not `nodes/common.py` only; root cause is `tools.py::make_tools()` returning the meta out-of-band.
2. **`legal_elements_checklist` / `suppressed_citations`:** allowed by the ownership map but absent from the Pydantic schema → if the LLM writes them, `validate_agent_output()` doesn't see them but `validate_field_ownership()` permits them. Silent under-validation.

**Retry-inducing flags (HIGH):**
- Both list fields are bare `list[dict[str, Any]]`.
- No citation-format validator (`Bluebook`/jurisdiction prefix), no `precedent.holding` required field.

---

### 1.7 argument-construction (Gate 3)

- **Node:** `src/pipeline/graph/nodes/argument_construction.py:11`.
- **Output schema:** `ArgumentConstructionOutput` — `agent_schemas.py:90-91`.
- **Field ownership:** `{arguments}` (`validation.py:39`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `arguments` | `dict[str, Any]` | yes | Bare dict. |

**Retry-inducing flags (HIGH):**
- Single open dict for the entire argument structure (claimant/respondent positions, supporting evidence refs, counter-arguments). No discoverable shape.

---

### 1.8 hearing-analysis (Gate 3)

- **Node:** `src/pipeline/graph/nodes/hearing_analysis.py:11`.
- **Output schema:** `HearingAnalysisOutput` — `agent_schemas.py:94-95`.
- **Field ownership:** `{hearing_analysis}` (`validation.py:40`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `hearing_analysis` | `dict[str, Any]` | yes | Bare dict. |

`CaseState.HearingAnalysis` sub-model (`case_state.py:39-45`) is the only typed surface here:
- `preliminary_conclusion: str | None`
- `confidence_score: int | None` — no `ge=/le=` constraint; conflicts with `ExtractedFactItem.confidence: str` (1.4).
- `reasoning_chain: list[dict[str, Any]]` — bare.
- `uncertainty_flags: list[dict[str, Any]]` — bare.
- `model_config = ConfigDict(extra="allow")` — extra keys silently accepted.

**Retry-inducing flags (HIGH):**
- The output schema doesn't enforce the typed sub-model; it's bare `dict[str, Any]`. The CaseState sub-model enforcement only fires when the merged dict is fed back into `CaseState(**merged_dict)` (`common.py:359`).
- `confidence_score` int with no bounds.

**Duplicate-model flags:**
- `confidence_score: int | None` vs `ExtractedFactItem.confidence: str` — **needs unification**.

---

### 1.9 hearing-governance / Auditor (Gate 4)

- **Node:** `src/pipeline/graph/nodes/hearing_governance.py:11`.
- **Output schema:** `HearingGovernanceOutput` — `agent_schemas.py:27-31`.
- **Field ownership:** `{fairness_check, status}` (`validation.py:41`).
- **Strict mode:** YES (only agent in `_STRICT_MODE_SCHEMAS`, `agent_schemas.py:103-105`).

| Field | Type | Required | Notes |
|---|---|---|---|
| `fairness_check` | `FairnessCheck` | yes | Strict — `extra="forbid"`. Sub-fields: `critical_issues_found: bool`, `audit_passed: bool`, `issues: list[str]`, `recommendations: list[str]`. |
| `status` | `str` | yes | **Same enum mismatch** — should be `CaseStatusEnum`. |

**Retry-inducing flags (LOW):**
- Best-validated agent in the system thanks to strict mode + `extra="forbid"` on `FairnessCheck`.
- Only weakness: `status: str` instead of the enum (the strict JSON schema doesn't enforce the enum either).

**Duplicate-model flags:**
- Owns `status` together with `case-processing` and `complexity-routing` → 3 writers (confirmed prior finding).

---

## 2. Cross-cutting findings (re-verifying the prior pass)

| # | Prior finding | Verified? | Citation | Correction / nuance |
|---|---|---|---|---|
| 1 | `status` written by 3 agents (case-processing, complexity-routing, hearing-governance) | **YES** | `validation.py:19-42` (FIELD_OWNERSHIP) | All three list `status` in their ownership set; all three schemas declare it as `str`, none as `CaseStatusEnum`. Consolidation candidate. |
| 2 | 6 schemas use bare `dict[str, Any]` where strict sub-schemas should exist | **YES, with extension** | `agent_schemas.py:64-95` | Confirmed: evidence-analysis, fact-reconstruction, witness-analysis, legal-knowledge (×2 lists), argument-construction, hearing-analysis. **Correction:** `EvidenceItem` and `ExtractedFactItem` already exist as Pydantic models in the same file (lines 55-62 and 68-74) but are **orphaned** — never referenced from the output schemas. The fix is plumbing, not modeling, for those two. |
| 3 | Confidence inconsistency: `fact-reconstruction.confidence: str` vs `hearing-analysis.confidence_score: int \| None` | **YES** | `agent_schemas.py:71` and `case_state.py:43` | Confirmed. Also note `confidence_score: int` has no `ge=0, le=100` bound. |
| 4 | `legal-knowledge.precedent_source_metadata` written outside the schema | **YES** | `common.py:355-357` | Confirmed. Also confirmed two more legal-knowledge fields (`legal_elements_checklist`, `suppressed_citations`) are in `FIELD_OWNERSHIP` but absent from `LegalKnowledgeOutput` — same class of leak, broader than the prior finding. |
| 5 | `complexity-routing` auto-repair via `normalize_agent_output()` → use nested `routing_decision` from the start | **YES** | `validation.py:5-15, 52-74` | Confirmed. The 7 stray fields are documented in the frozenset. Target: a typed `routing_decision: RoutingDecision` nested model. |

### Additional findings discovered during this pass

- **F6 — No automatic retry on schema failure.** `validate_agent_output()` (`agent_schemas.py:144-159`) only logs a warning. There is no retry loop for malformed output today; `extra_instructions` (`state.py:96`) is the retry channel but is driven by gate-review router nodes, not by Pydantic. Sprint 0.4 must decide whether to add a structured-output retry middleware or to lean on stricter prompts.
- **F7 — `CaseState.HearingAnalysis.model_config = extra="allow"`** (`case_state.py:40`) — inverse of `FairnessCheck`'s `extra="forbid"`. Inconsistent strictness across sub-models in the same file.
- **F8 — `precedent_source_metadata` is set after `validate_field_ownership` runs** (`common.py:355-357`) but before `CaseState(**merged_dict)`. It bypasses the ownership check entirely — fine because `legal-knowledge` already owns the field, but architecturally the side-channel + post-hoc injection muddies provenance.
- **F9 — Three agents (`hearing-governance` excluded) declare `case_id`/`run_id` either implicitly or via `case-processing` only.** Re-checking: only `case-processing` declares them in its schema (`agent_schemas.py:41-42`). All other agents inherit them via the merged `CaseState`. Not a bug, but worth noting for the phase mapping.
- **F10 — SAM-legacy field duplication in `CaseState`:** `EvidenceAnalysis.exhibits` (`case_state.py:53`), `Witnesses.statements` (`case_state.py:69`). These exist alongside the active `evidence_items` / `witnesses` fields and are unwritten by any agent. Drop in 0.5 unless retrieval pipeline still depends on them.

---

## 3. Field-to-phase mapping (current 9 → target 6)

Target topology:
- **Intake** (merges `case-processing` + `complexity-routing`)
- **Research / fan-out** of 4 subagents: `evidence`, `facts`, `witnesses`, `law` (replace the 4 Gate-2 peers)
- **Synthesis** (merges `argument-construction` + `hearing-analysis`)
- **Audit** (= `hearing-governance`)

> Every field declared in any output schema appears below. "DROPPED" = not carried forward; rationale given.

| Source agent | Source field | Target phase | Target field (proposed) | Notes |
|---|---|---|---|---|
| case-processing | `case_id` | (envelope) | `CaseEnvelope.case_id` | UUID4. Lift to a top-level envelope, not a phase output. |
| case-processing | `run_id` | (envelope) | `CaseEnvelope.run_id` | UUID4. Same. |
| case-processing | `domain` | Intake | `IntakeOutput.domain` | Type as `CaseDomainEnum` directly. |
| case-processing | `status` | (envelope) | `CaseEnvelope.status` | Single writer model: phases set status via a `transition()` helper, not a freeform field. |
| case-processing | `parties` | Intake | `IntakeOutput.parties: list[Party]` | Introduce `Party` sub-model. |
| case-processing | `case_metadata` | Intake | `IntakeOutput.case_metadata` | Becomes the strictly-typed `CaseMetadata` sub-model. |
| case-processing | `raw_documents` | Intake | `IntakeOutput.raw_documents: list[RawDocument]` | Introduce `RawDocument` sub-model. |
| complexity-routing | `status` | DROPPED | — | Folded into `CaseEnvelope.status`; only auditor + intake-final transitions write it. |
| complexity-routing | `case_metadata.complexity` | Intake | `IntakeOutput.routing_decision.complexity: ComplexityEnum` | Promote out of `case_metadata`. |
| complexity-routing | `case_metadata.complexity_score` | Intake | `IntakeOutput.routing_decision.complexity_score: int (ge=0, le=100)` | |
| complexity-routing | `case_metadata.route` | Intake | `IntakeOutput.routing_decision.route: RouteEnum` | |
| complexity-routing | `case_metadata.routing_factors` | Intake | `IntakeOutput.routing_decision.routing_factors: list[RoutingFactor]` | |
| complexity-routing | `case_metadata.vulnerability_assessment` | Intake | `IntakeOutput.routing_decision.vulnerability_assessment: VulnerabilityAssessment` | |
| complexity-routing | `case_metadata.escalation_reason` | Intake | `IntakeOutput.routing_decision.escalation_reason: str \| None` | |
| complexity-routing | `case_metadata.pipeline_halt` | Intake | `IntakeOutput.routing_decision.pipeline_halt: bool` | |
| evidence-analysis | `evidence_analysis.evidence_items` | Research/Evidence | `EvidenceResearch.evidence_items: list[EvidenceItem]` | Wire up the orphaned `EvidenceItem` model. |
| evidence-analysis | `evidence_analysis.credibility_scores` | Research/Evidence | `EvidenceResearch.credibility_scores: dict[str, CredibilityScore]` | Type the values. |
| evidence-analysis | `evidence_analysis.exhibits` (SAM legacy) | DROPPED | — | Unwritten by any current agent; kept only for SAM compatibility. |
| fact-reconstruction | `extracted_facts.facts` | Research/Facts | `FactsResearch.facts: list[ExtractedFactItem]` | Wire up the orphaned `ExtractedFactItem`; promote `confidence` to `Confidence` enum (see §4 confidence unification). |
| fact-reconstruction | `extracted_facts.timeline` | Research/Facts | `FactsResearch.timeline: list[TimelineEvent]` | Introduce `TimelineEvent` sub-model. |
| witness-analysis | `witnesses.witnesses` | Research/Witnesses | `WitnessesResearch.witnesses: list[Witness]` | Introduce `Witness` sub-model. |
| witness-analysis | `witnesses.credibility` | Research/Witnesses | `WitnessesResearch.credibility: dict[str, CredibilityScore]` | Use shared `CredibilityScore` (see §4). |
| witness-analysis | `witnesses.statements` (SAM legacy) | DROPPED | — | Same as `exhibits` — SAM compatibility only. |
| legal-knowledge | `legal_rules` | Research/Law | `LawResearch.legal_rules: list[LegalRule]` | Introduce `LegalRule` sub-model. |
| legal-knowledge | `precedents` | Research/Law | `LawResearch.precedents: list[Precedent]` | Introduce `Precedent` sub-model. |
| legal-knowledge | `precedent_source_metadata` | Research/Law | `LawResearch.precedent_source_metadata: PrecedentProvenance` | Move out of `common.py` side-channel into the schema; populate in the node post-tool-call. |
| legal-knowledge | `legal_elements_checklist` | Research/Law | `LawResearch.legal_elements_checklist: list[LegalElement]` | Add to schema (currently in `FIELD_OWNERSHIP` only). |
| legal-knowledge | `suppressed_citations` | Research/Law | `LawResearch.suppressed_citations: list[SuppressedCitation]` | Same — schema gap closure. |
| argument-construction | `arguments` | Synthesis | `SynthesisOutput.arguments: ArgumentSet` | Replace bare dict with `ArgumentSet` (claimant_position, respondent_position, contested_points, supporting_refs, counter_arguments). |
| hearing-analysis | `hearing_analysis.preliminary_conclusion` | Synthesis | `SynthesisOutput.preliminary_conclusion: str` | |
| hearing-analysis | `hearing_analysis.confidence_score` | Synthesis | `SynthesisOutput.confidence: Confidence` | Unify on `Confidence` enum (see §4). |
| hearing-analysis | `hearing_analysis.reasoning_chain` | Synthesis | `SynthesisOutput.reasoning_chain: list[ReasoningStep]` | |
| hearing-analysis | `hearing_analysis.uncertainty_flags` | Synthesis | `SynthesisOutput.uncertainty_flags: list[UncertaintyFlag]` | |
| hearing-governance | `fairness_check` | Audit | `AuditOutput.fairness_check: FairnessCheck` | Keep as-is — already strict. |
| hearing-governance | `status` | (envelope) | `CaseEnvelope.status` | Folded — auditor is the only post-synthesis status writer. |
| (envelope) | `audit_log` | All phases (append-only) | `CaseEnvelope.audit_log: list[AuditEntry]` | Already append-only via the reducer in `state.py:73-77`. |
| (envelope) | `schema_version` | (envelope) | `CaseEnvelope.schema_version: int` | Bump to 3 when 0.5 lands. |

---

## 4. Proposed target phase output models (high-level shape)

> **These are proposals for Sprint 0.4 to ratify, not final.** Each phase output is a `BaseModel` with `extra="forbid"`. Sub-models defined once and reused.

### Shared sub-models (used by multiple phases)

```text
Confidence(enum):     low | medium | high
CredibilityScore:     value: float (ge=0, le=1), rationale: str
SourceRef:            doc_id: str, span: tuple[int,int] | None, exhibit_id: str | None
RouteEnum:            gate2 | escalate | halt
ComplexityEnum:       simple | moderate | complex
```

### IntakeOutput (replaces case-processing + complexity-routing)

```text
domain:           CaseDomainEnum
parties:          list[Party]
case_metadata:    CaseMetadata           # typed: jurisdiction, claim_amount, filed_at, …
raw_documents:    list[RawDocument]      # typed: id, type, text, ingested_at
routing_decision: RoutingDecision        # complexity, complexity_score, route, factors,
                                         # vulnerability_assessment, escalation_reason,
                                         # pipeline_halt
```

### EvidenceResearch (replaces evidence-analysis output)

```text
evidence_items:     list[EvidenceItem]    # wire up orphaned model; tighten strength/type to Literal
credibility_scores: dict[str, CredibilityScore]
```

### FactsResearch (replaces fact-reconstruction output)

```text
facts:    list[ExtractedFactItem]   # wire up orphan; confidence → Confidence enum;
                                    # status → FactStatus(agreed|disputed|contradicted)
timeline: list[TimelineEvent]
```

### WitnessesResearch (replaces witness-analysis output)

```text
witnesses:   list[Witness]          # name, role, statements: list[Statement], credibility: CredibilityScore
credibility: dict[str, CredibilityScore]
```

### LawResearch (replaces legal-knowledge output)

```text
legal_rules:               list[LegalRule]
precedents:                list[Precedent]
precedent_source_metadata: PrecedentProvenance       # folded in from common.py side-channel
legal_elements_checklist:  list[LegalElement]
suppressed_citations:      list[SuppressedCitation]
```

### ResearchOutput (the join target — produced by the gate2_join node)

```text
evidence:  EvidenceResearch
facts:     FactsResearch
witnesses: WitnessesResearch
law:       LawResearch
```

### SynthesisOutput (replaces argument-construction + hearing-analysis)

```text
arguments:               ArgumentSet
preliminary_conclusion:  str
confidence:              Confidence       # unified scale
reasoning_chain:         list[ReasoningStep]
uncertainty_flags:       list[UncertaintyFlag]
```

### AuditOutput (= hearing-governance, lightly tightened)

```text
fairness_check: FairnessCheck   # already strict
status:         CaseStatusEnum  # promote str → enum (currently the only weakness)
```

---

## 5. Per-schema verdicts (one-line each)

| Current schema | Verdict | Reason |
|---|---|---|
| `HearingGovernanceOutput` (`agent_schemas.py:27-31`) | **Keep as-is, minor tightening** | Strict mode already; only `status: str → CaseStatusEnum`. |
| `FairnessCheck` (`case_state.py:30-36`) | **Keep as-is** | `extra="forbid"`, strict. |
| `CaseProcessingOutput` (`agent_schemas.py:40-47`) | **Replace entirely** | Split into `CaseEnvelope` (id/run_id/status) + `IntakeOutput` (domain/parties/metadata/documents); add `Party`/`RawDocument`/`CaseMetadata` sub-models. |
| `ComplexityRoutingOutput` (`agent_schemas.py:50-52`) | **Replace entirely** | Fold into `IntakeOutput.routing_decision: RoutingDecision`; deletes the `normalize_agent_output()` workaround. |
| `EvidenceItem` (`agent_schemas.py:55-62`) | **Keep, plumb in** | Already-good orphan; reference from `EvidenceResearch.evidence_items`; tighten `strength`/`evidence_type` to `Literal`. |
| `EvidenceAnalysisOutput` (`agent_schemas.py:64-65`) | **Replace entirely** | `dict[str, Any]` → `EvidenceResearch` with typed `evidence_items` and `credibility_scores`. |
| `ExtractedFactItem` (`agent_schemas.py:68-74`) | **Simplify first, then plumb in** | Reuse, but `confidence: str → Confidence` enum; `date: str` → `date | None` with ISO validator; `status: str` → `FactStatus` enum. |
| `FactReconstructionOutput` (`agent_schemas.py:77-78`) | **Replace entirely** | `dict[str, Any]` → `FactsResearch` referencing the simplified `ExtractedFactItem`. |
| `WitnessAnalysisOutput` (`agent_schemas.py:81-82`) | **Replace entirely** | `dict[str, Any]` → `WitnessesResearch` with new `Witness`/`Statement` sub-models; drop SAM-legacy `statements` from `CaseState.Witnesses`. |
| `LegalKnowledgeOutput` (`agent_schemas.py:85-87`) | **Replace entirely** | Add 3 fields currently leaked through ownership-only path; introduce `LegalRule`, `Precedent`, `PrecedentProvenance`, `LegalElement`, `SuppressedCitation`. |
| `ArgumentConstructionOutput` (`agent_schemas.py:90-91`) | **Replace entirely** | Bare `dict` → `ArgumentSet` inside `SynthesisOutput.arguments`. |
| `HearingAnalysisOutput` (`agent_schemas.py:94-95`) | **Replace entirely** | Bare `dict` → fields surfaced directly on `SynthesisOutput`; drop `extra="allow"` from the underlying `HearingAnalysis` sub-model. |
| `CaseState.HearingAnalysis` (`case_state.py:39-45`) | **Simplify first** | Tighten `confidence_score: int` → `Confidence` enum (with `ge/le` bound if numeric retained); flip `extra="allow"` → `extra="forbid"`. |
| `CaseState.EvidenceAnalysis` (`case_state.py:48-54`) | **Simplify first** | Drop `exhibits` SAM-legacy; type `evidence_items: list[EvidenceItem]`; type `credibility_scores: dict[str, CredibilityScore]`. |
| `CaseState.ExtractedFacts` (`case_state.py:57-61`) | **Simplify first** | Type `facts: list[ExtractedFactItem]`, `timeline: list[TimelineEvent]`. |
| `CaseState.Witnesses` (`case_state.py:64-70`) | **Simplify first** | Drop `statements` SAM-legacy; type `witnesses: list[Witness]`. |
| `AuditEntry` (`case_state.py:73-83`) | **Keep as-is** | Already adequately typed; only nit is `tool_calls: list[dict[str, Any]]` could be `list[ToolCall]`. |
| `CaseState` (`case_state.py:86-134`) | **Simplify first** | Bump `schema_version: int = 2 → 3`; replace `arguments: dict[str, Any] | None` with `ArgumentSet | None`; replace `legal_rules`/`precedents` bare-list defaults with their typed lists; collapse the two SAM-legacy sub-fields. |

---

## 6. Open questions for Sprint 0.4

1. **Strict mode rollout:** can we move every phase output to OpenAI strict JSON-schema mode once `dict[str, Any]` is gone? `_STRICT_MODE_SCHEMAS` (`agent_schemas.py:103`) becomes the default, not the exception.
2. **Retry contract:** today there is no retry on parse / validation failure. Do we add a Pydantic-driven retry middleware, or rely on stricter prompts + `extra_instructions` from the reviewer router?
3. **Confidence scale:** enum (`low/medium/high`) vs bounded int (`0..100`) vs float (`0..1`) — pick once, apply everywhere (`Confidence`, `CredibilityScore`, `confidence_score`).
4. **Status writer model:** with phases collapsing 9→6, `status` becomes a single-writer-per-transition field. Should `CaseStatusEnum` itself shrink (drop the `awaiting_review_gate1..4` variants, replaced by phase-level gates)?
5. **`audit_log` granularity:** should `AuditEntry.tool_calls` get its own `ToolCall` sub-model now that we're tightening everything else?

---

## 7. Quick stats

- 9 source agents → 6 target phases (4 of which are the parallel research fan-out).
- 9 output Pydantic models today — 7 use bare `dict[str, Any]` at the top level of at least one field.
- 2 orphan sub-models (`EvidenceItem`, `ExtractedFactItem`) — defined, never wired.
- 1 strict-mode agent today (`hearing-governance`); target is "all phases strict".
- 3 status-writing agents (`case-processing`, `complexity-routing`, `hearing-governance`); target is single-writer-per-transition.
- 2 confidence representations today (`str` and `int | None`); target is one `Confidence` enum (or one bounded numeric).
- 5 fields in `FIELD_OWNERSHIP["legal-knowledge"]` vs 2 fields in `LegalKnowledgeOutput` → 3-field schema gap.
- 1 LLM auto-repair pathway (`normalize_agent_output()` for complexity-routing) — eliminated by the nested `routing_decision` model.
