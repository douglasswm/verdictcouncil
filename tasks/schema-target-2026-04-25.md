# Target Schema Doc — Sprint 0 Task 0.5

**Date:** 2026-04-25
**Status:** Draft for 0.6 / 0.12 approval gate
**Canonical for Sprints 1–4.** Supersedes individual audits 0.1/0.2/0.3/0.4 where they conflict with the decisions pinned in §5 (Decisions Ledger).
**Scope:** final DDL (new tables + ALTER columns only), final Pydantic phase output models, final tool roster, final state-schema delta, migration sequence numbered 0025+.

Inputs:
- `/Users/douglasswm/Project/AAS/VER/tasks/schema-audit-2026-04-25.md` (0.1)
- `/Users/douglasswm/Project/AAS/VER/tasks/output-model-audit-2026-04-25.md` (0.2)
- `/Users/douglasswm/Project/AAS/VER/tasks/tool-audit-2026-04-25.md` (0.3)
- `/Users/douglasswm/Project/AAS/VER/tasks/architecture-2026-04-25.md` (0.4)
- `/Users/douglasswm/Project/AAS/VER/tasks/source-audit-2026-04-25-sprint-0-1.md` (SA)
- `/Users/douglasswm/Project/AAS/VER/tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md` (Task 4.C4.1 DDL)

---

## 1. Migration sequence (canonical reference)

> **Convention:** HEAD at Sprint 0 freeze is `alembic/versions/0024_pipeline_events_replay.py` (0.1 §3). All new migrations live in `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/alembic/versions/`. Every migration below has both `upgrade()` and `downgrade()` and must pass `alembic upgrade head && alembic downgrade -1 && alembic upgrade head`.

| Migration | Sprint | Brief | Reversible |
|---|---|---|---|
| `0024_pipeline_events_replay.py` | (existing) | `pipeline_events` table with `(case_id, ts)` + GIN index. | (existing) |
| `0025_audit_schema_upgrade.py` | Sprint 4 | `audit_logs` columns (`trace_id`, `span_id`, `retrieved_source_ids`, `cost_usd`, `redaction_applied`, `judge_correction_id`) + new tables `judge_corrections` and `suppressed_citation`, both phase-keyed, UUID FK → `cases.id`, `ON DELETE CASCADE`, with `correction_source` discriminator. | yes |
| `0026_drop_legacy_domain_and_calibration.py` | Sprint 2 | Drop `calibration_records`; drop `cases.domain` enum column + the `casedomain` Postgres ENUM type; make `cases.domain_id` NOT NULL; add FK index `ix_cases_domain_id`. Coordinated with Sprint 2 checkpointer cutover (2.A2.7, 2.A2.10). | yes |

No other DDL is in scope for Sprints 1–4. Indexes flagged in 0.1 §summary 5 (`audit_logs.agent_name`, `audit_logs.created_at`, `domain_documents(domain_id, status)`, `domains.provisioning_*` drop, unversioned JSONB backfills, `pipeline_checkpoints` PK change, `audit_logs` UUID PK) are **deferred** — not required for the 6-agent cutover. The 0.4 §9 long list (0027–0037) is descoped to future sprints.

Cross-ref: 0.4 §9 (source enumeration), 0.1 §summary 1, 0.1 §6, Task 4.C4.1.

### 1.1 Migration 0025 — `0025_audit_schema_upgrade.py` (Sprint 4)

Source DDL: Task 4.C4.1 (lines ~2171-2208 of breakdown). Deviations from the breakdown block are flagged **[0.5 tweak]**.

```sql
-- judge_corrections: phase-keyed, not agent-keyed (matches 6-agent topology).
-- [0.5 tweak] adds `correction_source` column to discriminate judge vs auditor-origin corrections
-- (user decision — auditor "send back to phase" is post-hoc via the same rerun endpoint).
CREATE TABLE judge_corrections (
    id                  BIGSERIAL PRIMARY KEY,
    case_id             UUID        NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    run_id              TEXT        NOT NULL,
    phase               TEXT        NOT NULL CHECK (phase IN ('intake','research','synthesis','audit')),
    subagent            TEXT        CHECK (subagent IS NULL OR subagent IN ('evidence','facts','witnesses','law')),
    CHECK (subagent IS NULL OR phase = 'research'),
    correction_text     TEXT        NOT NULL,
    correction_source   TEXT        NOT NULL CHECK (correction_source IN ('judge','auditor')),   -- [0.5 tweak]
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX judge_corrections_case_idx    ON judge_corrections (case_id);
CREATE INDEX judge_corrections_run_idx     ON judge_corrections (run_id);
CREATE INDEX judge_corrections_source_idx  ON judge_corrections (correction_source);  -- [0.5 tweak]

-- suppressed_citation: unchanged from breakdown.
CREATE TABLE suppressed_citation (
    id           BIGSERIAL PRIMARY KEY,
    case_id      UUID        NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    run_id       TEXT        NOT NULL,
    phase        TEXT        NOT NULL CHECK (phase IN ('intake','research','synthesis','audit')),
    subagent     TEXT        CHECK (subagent IS NULL OR subagent IN ('evidence','facts','witnesses','law')),
    CHECK (subagent IS NULL OR phase = 'research'),
    citation_text TEXT       NOT NULL,
    reason       TEXT        NOT NULL CHECK (reason IN ('no_source_match','low_score','expired_statute','out_of_jurisdiction')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX suppressed_citation_case_idx ON suppressed_citation (case_id);
CREATE INDEX suppressed_citation_run_idx  ON suppressed_citation (run_id);

-- audit_logs additions: Sprint-2 cost-tracking surface lives here (cost_usd), which is why
-- the Sprint-2 `system_config` cost_config reader (see §5 ledger) depends on 0025.
-- NOTE: Task 4.C4.1 in the breakdown writes `audit_log` (singular); the actual table is
-- `audit_logs` (plural) per 0.1 §1. This spec uses the correct plural form; Sprint 4
-- implementation must follow this DDL, not the breakdown.
ALTER TABLE audit_logs
    ADD COLUMN trace_id              TEXT,
    ADD COLUMN span_id               TEXT,
    ADD COLUMN retrieved_source_ids  JSONB,
    ADD COLUMN cost_usd              NUMERIC(10, 6),
    ADD COLUMN redaction_applied     BOOLEAN DEFAULT FALSE,
    ADD COLUMN judge_correction_id   BIGINT REFERENCES judge_corrections(id) ON DELETE SET NULL;
CREATE INDEX audit_logs_trace_idx ON audit_logs (trace_id);
```

Downgrade order: drop `audit_logs` indexes+columns (reverse order), drop `suppressed_citation`, drop `judge_corrections`, drop all indexes on both.

Cross-ref: Task 4.C4.1 body, 0.4 §9 row 0025, user decision in §5 D-4.

### 1.2 Migration 0026 — `0026_drop_legacy_domain_and_calibration.py` (Sprint 2)

Precondition (must be satisfied by separate PRs before this migration lands): every `cases.domain` reader listed in 0.1 §5 must be moved to `cases.domain_id`/`domain_ref`. Readers to migrate: `cases.py:169, :212, :622, :638, :905, :1329`; `dashboard.py:37`; `hearing_pack.py:220`; `workers/tasks.py:164`; `services/case_report_data.py:113`. This is coordinated with the Sprint 2 checkpointer cutover (2.A2.7, 2.A2.10) so the code flag-flip and the DDL land together.

```sql
-- 1. Drop the fully-dead table.
DROP TABLE IF EXISTS calibration_records;

-- 2. Make domain_id NOT NULL (all rows should already be populated — see precondition).
UPDATE cases SET domain_id = (
    SELECT id FROM domains WHERE code = cases.domain::text
) WHERE domain_id IS NULL;
ALTER TABLE cases ALTER COLUMN domain_id SET NOT NULL;

-- 3. Add FK index (0.1 §5 / summary 5 — no index today).
CREATE INDEX ix_cases_domain_id ON cases (domain_id);

-- 4. Drop the legacy enum column + the Postgres ENUM type itself.
ALTER TABLE cases DROP COLUMN domain;
DROP TYPE IF EXISTS casedomain;
```

Downgrade: recreate `casedomain` ENUM (`small_claims`, `traffic_violation`), add `domain` column nullable, backfill from `domain_ref.code`, drop `ix_cases_domain_id`, relax `domain_id` to NULLABLE, recreate `calibration_records` with its 0001-era DDL (preserved in the alembic downgrade body for reversibility).

Cross-ref: 0.1 §summary 1, 0.1 §6, user decision §5 D-1 and D-2.

---

## 2. Final Pydantic phase output models

> **File target:** `VerdictCouncil_Backend/src/pipeline/agent_schemas.py` (rewritten in Sprint 1 task 1.A1.5). Sub-model definitions (`EvidenceItem`, `ExtractedFactItem`, etc.) live in the same module. `ConfidenceLevel` lives in `VerdictCouncil_Backend/src/shared/confidence.py` so it can be imported by utilities (`src/utils/confidence_calc.py`) without creating a cycle.

### 2.1 Shared enums and helpers

```python
# src/shared/confidence.py
from enum import Enum


class ConfidenceLevel(str, Enum):
    """Canonical confidence scale — used everywhere a subjective confidence is recorded.

    Decision §5 D-3: replaces `confidence: str` (fact-reconstruction) and
    `confidence_score: int | None` (hearing-analysis) uniformly.
    """
    LOW = "low"
    MED = "med"
    HIGH = "high"
```

```python
# src/pipeline/agent_schemas.py — prelude
from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, conlist

from src.shared.confidence import ConfidenceLevel


# --- enums used across multiple phase schemas ---

CaseDomain = Literal["small_claims", "traffic_violation"]
ComplexityLevel = Literal["simple", "moderate", "complex"]
RouteDecision = Literal["gate2", "escalate", "halt"]
FactStatus = Literal["agreed", "disputed", "contradicted"]
EvidenceStrength = Literal["weak", "moderate", "strong"]
EvidenceType = Literal["document", "testimony", "physical", "digital", "other"]
SuppressionReason = Literal["no_source_match", "low_score", "expired_statute", "out_of_jurisdiction"]
RerunTargetPhase = Literal["intake", "research", "synthesis"]
CaseStatus = Literal[
    "draft", "extracting", "awaiting_intake_confirmation", "pending", "processing",
    "ready_for_review", "escalated", "closed", "failed", "failed_retryable",
    "awaiting_review_gate1", "awaiting_review_gate2", "awaiting_review_gate3", "awaiting_review_gate4",
]
```

### 2.2 Shared sub-models

```python
class CredibilityScore(BaseModel):
    model_config = ConfigDict(extra="forbid")
    value: float = Field(ge=0.0, le=1.0)
    rationale: str = Field(min_length=1)


class SourceRef(BaseModel):
    model_config = ConfigDict(extra="forbid")
    doc_id: str = Field(min_length=1)
    span: Optional[tuple[int, int]] = None
    exhibit_id: Optional[str] = None


class Party(BaseModel):
    model_config = ConfigDict(extra="forbid")
    party_id: str
    role: Literal["claimant", "respondent", "witness", "counsel", "other"]
    name: str
    contact: Optional[str] = None


class RawDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")
    doc_id: str
    doc_type: Literal["complaint", "evidence", "pleading", "correspondence", "other"]
    filename: str
    content_hash: str          # SHA-256 of source bytes; powers deterministic parse_document cache (§5 D-5)
    ingested_at: datetime


class CaseMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")
    jurisdiction: str
    claim_amount: Optional[float] = Field(default=None, ge=0.0)
    filed_at: Optional[date] = None
    offence_code: Optional[str] = None


class RoutingFactor(BaseModel):
    model_config = ConfigDict(extra="forbid")
    factor: str
    weight: float = Field(ge=0.0, le=1.0)
    rationale: str


class VulnerabilityAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")
    vulnerable_party_flagged: bool
    concerns: list[str] = Field(default_factory=list)


class RoutingDecision(BaseModel):
    """Replaces the `_COMPLEXITY_ROUTING_METADATA_FIELDS` workaround from
    `validation.py:5-15` (0.2 §1.2 F-5)."""
    model_config = ConfigDict(extra="forbid")
    complexity: ComplexityLevel
    complexity_score: int = Field(ge=0, le=100)
    route: RouteDecision
    routing_factors: conlist(RoutingFactor, min_length=0)
    vulnerability_assessment: VulnerabilityAssessment
    escalation_reason: Optional[str] = None
    pipeline_halt: bool = False
```

### 2.3 IntakeOutput (merges old `case-processing` + `complexity-routing`)

```python
class IntakeOutput(BaseModel):
    """Single lightweight-model phase — replaces two cascading agents (0.4 §2.1).

    Cross-ref: 0.2 §3 mapping, 0.4 §2.1.
    """
    model_config = ConfigDict(extra="forbid")

    domain: CaseDomain                                  # was `str` — 0.2 F#1
    parties: conlist(Party, min_length=0)
    case_metadata: CaseMetadata
    raw_documents: conlist(RawDocument, min_length=0)
    routing_decision: RoutingDecision
```

### 2.4 Research phase — four typed sub-outputs

```python
class EvidenceItem(BaseModel):
    """Wires up the orphan at `agent_schemas.py:55-62` (0.2 F2)."""
    model_config = ConfigDict(extra="forbid")
    evidence_id: str
    evidence_type: EvidenceType
    strength: EvidenceStrength
    description: str
    source_ref: Optional[SourceRef] = None
    admissibility_flags: dict[str, bool] = Field(default_factory=dict)
    linked_claims: list[str] = Field(default_factory=list)


class EvidenceResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    evidence_items: conlist(EvidenceItem, min_length=0)
    credibility_scores: dict[str, CredibilityScore] = Field(default_factory=dict)


class ExtractedFactItem(BaseModel):
    """Wires up the orphan at `agent_schemas.py:68-74` (0.2 F2).

    §5 D-3: `confidence` is the `ConfidenceLevel` enum.
    """
    model_config = ConfigDict(extra="forbid")
    fact_id: str
    description: str
    date: Optional[date] = None          # ISO-8601, parsed at validation time
    confidence: ConfidenceLevel
    status: FactStatus
    source_refs: list[SourceRef] = Field(default_factory=list)
    corroboration: dict[str, str] = Field(default_factory=dict)


class TimelineEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")
    event_date: date
    description: str
    source_refs: list[SourceRef] = Field(default_factory=list)


class FactsResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    facts: conlist(ExtractedFactItem, min_length=0)
    timeline: conlist(TimelineEvent, min_length=0)


class Statement(BaseModel):
    model_config = ConfigDict(extra="forbid")
    statement_id: str
    text: str
    made_at: Optional[datetime] = None
    source_ref: Optional[SourceRef] = None


class Witness(BaseModel):
    model_config = ConfigDict(extra="forbid")
    witness_id: str
    name: str
    role: Literal["eyewitness", "expert", "character", "other"]
    statements: conlist(Statement, min_length=0)
    credibility: CredibilityScore


class WitnessesResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    witnesses: conlist(Witness, min_length=0)
    credibility: dict[str, CredibilityScore] = Field(default_factory=dict)


class LegalRule(BaseModel):
    model_config = ConfigDict(extra="forbid")
    rule_id: str
    jurisdiction: str
    citation: str
    text: str
    applicability: str


class Precedent(BaseModel):
    model_config = ConfigDict(extra="forbid")
    case_name: str
    citation: str
    jurisdiction: str
    holding: str
    relevance_rationale: str


class PrecedentProvenance(BaseModel):
    """Moves the `common.py:355-357` side-channel into the schema (0.2 F4 / F8)."""
    model_config = ConfigDict(extra="forbid")
    source: Literal["pair", "vector_store", "degraded"]
    query: str
    retrieved_at: datetime
    degraded_reason: Optional[str] = None


class LegalElement(BaseModel):
    model_config = ConfigDict(extra="forbid")
    element: str
    satisfied: bool
    rationale: str


class SuppressedCitation(BaseModel):
    """Mirrors the `suppressed_citation` DDL (migration 0025)."""
    model_config = ConfigDict(extra="forbid")
    citation_text: str
    reason: SuppressionReason


class LawResearch(BaseModel):
    """Closes the 3-field schema gap from 0.2 §1.6 (ownership lists 5, old
    schema declared 2)."""
    model_config = ConfigDict(extra="forbid")
    legal_rules: conlist(LegalRule, min_length=0)
    precedents: conlist(Precedent, min_length=0)
    precedent_source_metadata: PrecedentProvenance
    legal_elements_checklist: conlist(LegalElement, min_length=0)
    suppressed_citations: conlist(SuppressedCitation, min_length=0)
```

### 2.5 ResearchOutput (merged join result)

```python
class ResearchPart(BaseModel):
    """Discriminated wrapper emitted by each research subagent — written into
    `research_parts: Annotated[dict[str, ResearchPart], merge_dict]` keyed by scope.

    SA F-2 (option 2 — dict-keyed accumulator). `merge_dict` reducer lives in
    `src/pipeline/graph/state.py` (0.4 §4.2).
    """
    model_config = ConfigDict(extra="forbid")
    scope: Literal["evidence", "facts", "witnesses", "law"]
    evidence: Optional[EvidenceResearch] = None
    facts: Optional[FactsResearch] = None
    witnesses: Optional[WitnessesResearch] = None
    law: Optional[LawResearch] = None


class ResearchOutput(BaseModel):
    """Produced by `research_join_node` (0.4 §4.3).

    `partial=True` is set by `from_parts` when any scope is missing; the gate2
    UI surfaces this to the judge.
    """
    model_config = ConfigDict(extra="forbid")
    evidence: Optional[EvidenceResearch] = None
    facts: Optional[FactsResearch] = None
    witnesses: Optional[WitnessesResearch] = None
    law: Optional[LawResearch] = None
    partial: bool = False

    @classmethod
    def from_parts(cls, parts: dict[str, "ResearchPart"]) -> "ResearchOutput":
        expected = {"evidence", "facts", "witnesses", "law"}
        present = set(parts.keys())
        return cls(
            evidence=parts["evidence"].evidence if "evidence" in parts else None,
            facts=parts["facts"].facts if "facts" in parts else None,
            witnesses=parts["witnesses"].witnesses if "witnesses" in parts else None,
            law=parts["law"].law if "law" in parts else None,
            partial=bool(expected - present),
        )
```

### 2.6 SynthesisOutput

```python
class ArgumentPosition(BaseModel):
    model_config = ConfigDict(extra="forbid")
    party: Literal["claimant", "respondent"]
    position: str
    supporting_refs: list[SourceRef] = Field(default_factory=list)


class ContestedPoint(BaseModel):
    model_config = ConfigDict(extra="forbid")
    description: str
    claimant_view: str
    respondent_view: str


class ArgumentSet(BaseModel):
    model_config = ConfigDict(extra="forbid")
    claimant_position: ArgumentPosition
    respondent_position: ArgumentPosition
    contested_points: conlist(ContestedPoint, min_length=0)
    counter_arguments: list[str] = Field(default_factory=list)


class ReasoningStep(BaseModel):
    model_config = ConfigDict(extra="forbid")
    step_no: int = Field(ge=1)
    description: str
    supports: list[str] = Field(default_factory=list)


class UncertaintyFlag(BaseModel):
    model_config = ConfigDict(extra="forbid")
    topic: str
    rationale: str
    severity: ConfidenceLevel


class SynthesisOutput(BaseModel):
    """Replaces `argument-construction` + `hearing-analysis` (0.4 §2.6).

    `confidence` uses the unified `ConfidenceLevel` enum (§5 D-3). `confidence_calc`
    is NOT a tool — the synthesis node may call the `src/utils/confidence_calc.py`
    utility directly post-LLM and overwrite this field if the user enables that
    path (§5 D-7; 0.3 §5).
    """
    model_config = ConfigDict(extra="forbid")

    arguments: ArgumentSet
    preliminary_conclusion: str = Field(min_length=1)
    confidence: ConfidenceLevel
    reasoning_chain: conlist(ReasoningStep, min_length=1)
    uncertainty_flags: list[UncertaintyFlag] = Field(default_factory=list)
```

### 2.7 AuditOutput (strict mode, only phase using OpenAI strict JSON schema)

```python
class FairnessCheck(BaseModel):
    """Kept verbatim from `src/shared/case_state.py:30-36` — already `extra="forbid"`."""
    model_config = ConfigDict(extra="forbid")
    critical_issues_found: bool
    audit_passed: bool
    issues: list[str] = Field(default_factory=list)
    recommendations: list[str] = Field(default_factory=list)


class AuditOutput(BaseModel):
    """§5 D-9 post-hoc "send back to phase" mechanic: the auditor sets
    `should_rerun` + `target_phase` + `reason`; the worker reads these and calls
    the same rerun endpoint judges use (`/cases/{id}/rerun?phase=...`).

    `correction_source='auditor'` is written on the resulting `judge_corrections`
    row (migration 0025 DDL tweak).

    Strict mode only — per §5 D-4, this is the one phase using OpenAI strict
    JSON schema. Other phases use `ToolStrategy(Schema)` with `extra="forbid"`
    (SA F-8).
    """
    model_config = ConfigDict(extra="forbid", strict=True)

    fairness_check: FairnessCheck
    status: CaseStatus
    should_rerun: bool = False
    target_phase: Optional[RerunTargetPhase] = None     # required when should_rerun is True
    reason: Optional[str] = None                        # required when should_rerun is True
```

Cross-ref: 0.2 §1.9, 0.4 §2.7, user decision §5 D-9.

---

## 3. Final tool roster

Three real tools registered in `src/pipeline/graph/tools.py` (Sprint 1 rewrite). Per 0.3 §"Proposed final roster" and 0.4 §5.

| Tool | Signature | Callers (phase list) | Import path |
|---|---|---|---|
| `parse_document` | `(file_id: str, extract_tables: bool = True, ocr_enabled: bool = False, run_classifier: bool = False) -> dict` | `intake`, `research-evidence`, `research-facts`, `research-witnesses` (per 0.4 §5 + breakdown 1.A1.4 `PHASE_TOOLS`) | `src.tools.parse_document.parse_document` |
| `search_precedents` | `(query: str, domain: str = "small_claims", max_results: int = 5) -> list[dict]` (`vector_store_id` injected via closure) | `research-law`, `synthesis` | `src.tools.search_precedents.search_precedents` |
| `search_legal_rules` | `(query: str, vector_store_id: str, max_results: int = 5) -> list[dict]` | `research-law` | `src.tools.search_legal_rules.search_legal_rules` (renamed from `search_domain_guidance` — 0.3 §7) |

**Demoted to internal utility (no `@tool` wrapper):**
- `confidence_calc` — Python source stays at `VerdictCouncil_Backend/src/tools/confidence_calc.py` or moves to `VerdictCouncil_Backend/src/utils/confidence_calc.py` during Sprint 1. Invoked directly from the synthesis phase node post-LLM. Decision §5 D-7 / 0.3 §5.

**Dropped entirely:** `cross_reference`, `timeline_construct`, `generate_questions`. See 0.3 §"Drop list" for rationale per tool.

**`parse_document` internals — Sprint scope:** current OpenAI Responses-API extraction is kept through Sprint 1 (the `@tool` surface does not change). Deterministic-loader rewrite (PyMuPDF + `RecursiveCharacterTextSplitter` + content-hash cache key via `RawDocument.content_hash`) lands in Sprint 2. Decision §5 D-5.

---

## 4. State schema delta (`CaseState` / `GraphState`)

Diff vs current `src/shared/case_state.py` and `src/pipeline/graph/state.py`. Cross-ref: 0.4 §7.

### 4.1 Added

| Field | Type | Owner | Notes |
|---|---|---|---|
| `research_parts` | `Annotated[dict[str, ResearchPart], merge_dict]` | 4 research subagents | SA F-2 option 2 — dict-keyed accumulator replaces list+`operator.add` from the earlier draft. Reset via `research_dispatch_node` returning `{"research_parts": {}}` (first entry) or `graph.update_state(cfg, {"research_parts": Overwrite({})})` from outside (SA V-3). |
| `case.intake` | `IntakeOutput` | `intake` phase node | Replaces ad-hoc writes to `case.domain`, `case.case_metadata`, `case.parties`, `case.raw_documents`. |
| `case.research_output` | `ResearchOutput` | `research_join` node | Produced by `ResearchOutput.from_parts(state["research_parts"])`. |
| `case.synthesis` | `SynthesisOutput` | `synthesis` phase node | — |
| `case.audit` | `AuditOutput` | `auditor` phase node | Includes the `should_rerun`/`target_phase`/`reason` tuple (§5 D-9). |
| `_pending_action` | `dict \| None` | gate pause/apply nodes | Carries `interrupt()` decision between pause and apply (breakdown 1.A1.7 stub). |

### 4.2 Removed

| Field | Reason |
|---|---|
| `EvidenceAnalysis.exhibits` | SAM-legacy duplicate of `evidence_items`; no current writer. 0.2 F10. |
| `Witnesses.statements` (peer field) | SAM-legacy; overlaps `witnesses[*].statements`. 0.2 F10. |
| `case.domain` (enum) | Dropped in migration 0026 (§1.2). 0.1 §summary 1. |
| `FIELD_OWNERSHIP` (allowlist logic) | Replaced by Pydantic `extra="forbid"` enforcement (breakdown 1.A1.SEC3). 0.4 §7.2. |
| `calibration_records` table (not a state field) | Dropped in migration 0026. 0.1 §6. |

### 4.3 Re-typed

| Field | Old type | New type |
|---|---|---|
| `domain` (in phase outputs) | `str` | `CaseDomain` (`Literal`) |
| `status` (in 3 old schemas) | `str` | `CaseStatus` (`Literal`) — writer collapses to `auditor` only (§4.4). |
| `confidence` (facts) | `str` | `ConfidenceLevel` |
| `confidence_score` (hearing-analysis, now synthesis) | `int \| None` (no bound) | `ConfidenceLevel` (§5 D-3) |
| `evidence_items` | `list[Any]` / `list[dict[str, Any]]` | `list[EvidenceItem]` |
| `facts` | `list[dict[str, Any]]` | `list[ExtractedFactItem]` |
| `legal_rules`, `precedents` | `list[dict[str, Any]]` | `list[LegalRule]`, `list[Precedent]` |

### 4.4 Re-owned (single writer per phase)

Per 0.4 §7.3:

| Field | Old writers | New writer |
|---|---|---|
| `case.status` | `case-processing`, `complexity-routing`, `hearing-governance` (3-way write, 0.2 §§1.1/1.2/1.9) | `auditor` (final terminal write) + gate apply nodes `upsert_case_status()` for HITL queueing (`awaiting_review_gate*`). |
| `case.case_metadata` | `case-processing`, `complexity-routing` (overlap) | `intake` only. |

### 4.5 Unchanged

- `pipeline_events.schema_version = Literal[1]` — the current `Literal[1] = 1` convention in `src/api/schemas/pipeline_events.py:40, :88, :105, :117, :125` is **documented only**; no bump-infrastructure migration in Sprints 1–4. Decision §5 D-8. Cross-ref 0.1 §summary 2.
- `pipeline_checkpoints` PK and `audit_logs` FK integrity — deferred past Sprint 4.

---

## 5. Decisions ledger (all decisions pinned by 0.5)

Each line: decision, rationale, source.

- **D-1. `calibration_records` is dropped in migration 0026 (Sprint 2).** Zero writers, zero readers (0.1 §6). User decision (prompt).
- **D-2. `cases.domain` enum column is dropped in migration 0026 (Sprint 2); `cases.domain_id` becomes NOT NULL; FK index added.** Coordinated with checkpointer cutover (2.A2.7, 2.A2.10). Precondition: every reader in 0.1 §5 must first be migrated off `cases.domain`. User decision + 0.4 §9 row 0030.
- **D-3. Confidence uses the `ConfidenceLevel` enum (`low | med | high`) everywhere.** Replaces `confidence: str` (fact-reconstruction, 0.2 §1.4) and `confidence_score: int | None` (hearing-analysis, 0.2 §1.8). Enum chosen over 0-100 int / 0-1 float for human-readable judge UX. User decision; 0.2 §6 q3; 0.4 §10 q1.
- **D-4. Only `AuditOutput` runs OpenAI strict-mode JSON schema.** All other phases use `ToolStrategy(Schema)` with `extra="forbid"` (SA F-8). Preserves the existing `hearing-governance` strict-mode path (0.2 §1.9) and caps strict-mode rollout cost. User decision.
- **D-5. `parse_document` keeps the current OpenAI Responses-API internals through Sprint 1.** Deterministic-loader rewrite (PyMuPDF + `RecursiveCharacterTextSplitter` + content-hash cache key derived from `RawDocument.content_hash`) lands in Sprint 2. `@tool` surface unchanged. User decision; 0.3 open question 2; 0.4 §10 q5.
- **D-6. The three tools `cross_reference`, `timeline_construct`, `generate_questions` are dropped in Sprint 1.** 0.3 §"Drop list". `search_domain_guidance` is renamed to `search_legal_rules`.
- **D-7. `confidence_calc` is demoted to an internal Python utility.** The `@tool` registration is dropped; source moves/stays under `src/utils/`. The synthesis phase node calls it directly if enabled; the LLM does not see it. User decision; 0.3 §5; 0.4 §10 q4.
- **D-8. `pipeline_events.schema_version` stays at `Literal[1]`; no migration for bump infrastructure.** The current convention is documented in `src/api/schemas/pipeline_events.py` headers during Sprint 1. User decision; 0.1 §summary 2 deferred.
- **D-9. Auditor "send back to phase" is post-hoc via `AuditOutput.should_rerun` + `target_phase` + `reason`.** Worker reads these fields and calls the same `/cases/{id}/rerun?phase=...` endpoint judges use (0.4 §8). `judge_corrections` gains `correction_source TEXT NOT NULL CHECK (correction_source IN ('judge','auditor'))` in migration 0025. User decision; tweak to Task 4.C4.1 DDL.
- **D-10. Model tiers (OpenAI-only, no cost ceiling).** Lightweight (`intake`) = `gpt-5-mini`; frontier (`research-*`, `synthesis`) = `gpt-5`; strong-reasoning (`auditor`, strict mode) = `gpt-5` with reasoning settings. **GPT-4 family is deprecated; do not use as fallback.** User decision; supersedes 0.4 §2 `gpt-5.4-*` placeholders.
- **D-11. `admin_events` gets a reader endpoint `GET /admin/events` in Sprint 4.** API change only — not in the migration sequence. 0.1 §10; user decision.
- **D-12. `system_config` reader wired in Sprint 2** alongside the checkpointer cutover, as the cost-config consumer. API change, not DDL — but depends on Sprint 2's `audit_logs.cost_usd` surface (migration 0025 column). User decision; 0.1 §12.
- **D-13. Golden eval cases (Sprint 0 task 0.11b): 15 cases total.** 5 simple / 5 medium / 5 complex, domain mix of `small_claims` + `traffic_violation`, including 3 edge cases (ambiguous facts / conflicting witnesses / jurisdiction issue). 0.5 enumerates; 0.11b authors. User decision; breakdown 0.11b.
- **D-14. LangSmith workspace exists; credentials TBD.** Required env vars documented: `LANGSMITH_API_KEY`, `LANGSMITH_PROJECT=verdictcouncil`, `LANGSMITH_TRACING=true`, and (optionally, if the key is org-scoped per SA F-6) `LANGSMITH_WORKSPACE_ID`. Actual values collected by setup doc 0.11c. User decision.
- **D-15. Migration sequence for Sprints 1–4 is exactly `{0025, 0026}`.** Every other DDL item from 0.4 §9 (0027–0037) is deferred past Sprint 4. Rationale: Sprint 1 is a pure code topology change; Sprint 2 is the checkpointer+domain cutover; Sprint 4 is the audit upgrade. Index/JSONB hygiene is not on the critical path.

---

## 6. Open questions remaining for 0.12 approval gate

- **OQ-1 (informational). `langgraph dev` Studio port.** SA F-9 could not pin the default port from docs. Verify during `1.DEP1.2`; no schema impact.

All other items from 0.4 §10 are resolved in the Decisions Ledger (§5).

---

## 7. Cross-reference table (traceability)

Every architectural claim in this document traces back through one or more source audits. Sprint 1 work plans cite `schema-target-2026-04-25.md §N` which in turn cites the row below.

| 0.5 section | Claim | Source citation |
|---|---|---|
| §1 table | Migration head is `0024_pipeline_events_replay.py` | 0.1 §3 |
| §1 table | Only `{0025, 0026}` ship in Sprints 1–4 | User decision + 0.4 §9 (scope subset) |
| §1.1 | `judge_corrections` / `suppressed_citation` DDL | Task 4.C4.1 body |
| §1.1 | `correction_source` column added | User decision §5 D-9 |
| §1.1 | `audit_logs.cost_usd` feeds Sprint 2 `system_config` reader | User decision §5 D-12 |
| §1.2 | Drop `calibration_records` | 0.1 §6 + §5 D-1 |
| §1.2 | Drop `cases.domain` enum, NOT NULL `domain_id`, `ix_cases_domain_id` | 0.1 §5 / §summary 5 / §summary 1 + 0.4 §9 row 0030 + §5 D-2 |
| §2.1 | `ConfidenceLevel` enum | §5 D-3 / 0.2 §6 q3 / 0.4 §10 q1 |
| §2.2 | `CaseMetadata`, `RawDocument`, `Party`, `RoutingDecision` sub-models | 0.2 §3 + 0.2 §4 + 0.4 §2.1 |
| §2.2 | `RawDocument.content_hash` SHA-256 | §5 D-5 (Sprint 2 deterministic loader cache key) |
| §2.3 | `IntakeOutput` merges `case-processing` + `complexity-routing` | 0.2 §3 + 0.4 §2.1 |
| §2.4 | `EvidenceItem` / `ExtractedFactItem` wired up | 0.2 F2 / 0.2 §5 verdicts |
| §2.4 | `LawResearch` includes `precedent_source_metadata`, `legal_elements_checklist`, `suppressed_citations` | 0.2 §1.6 + 0.2 F4/F8 + 0.4 §2.5 |
| §2.5 | `research_parts` is dict-keyed with `merge_dict` reducer | SA F-2 option 2 + 0.4 §4.2 |
| §2.6 | `SynthesisOutput` unifies `argument-construction` + `hearing-analysis` | 0.2 §3 + 0.4 §2.6 |
| §2.6 | `ConfigDict(extra="forbid")` flip on synthesis | 0.2 F7 + 0.4 §2.6 |
| §2.7 | `AuditOutput.strict=True` (OpenAI strict mode) | 0.2 §1.9 + §5 D-4 |
| §2.7 | `should_rerun`/`target_phase`/`reason` fields | §5 D-9 (user decision) |
| §3 table | 3-tool roster | 0.3 §"Proposed final roster" + 0.4 §5 |
| §3 table | `search_domain_guidance` → `search_legal_rules` rename | 0.3 §7 |
| §3 | `confidence_calc` demoted | 0.3 §5 + §5 D-7 |
| §3 | `parse_document` internals kept in Sprint 1 | §5 D-5 + 0.3 §1 |
| §4.1 | `research_parts` typed as `dict[str, ResearchPart]` | SA F-2 + 0.4 §7.1 |
| §4.2 | Drop `EvidenceAnalysis.exhibits`, `Witnesses.statements` | 0.2 F10 + 0.4 §7.2 |
| §4.2 | Drop `FIELD_OWNERSHIP` | 0.4 §7.2 (replaced by `extra="forbid"`) |
| §4.4 | `status` single-writer (auditor) | 0.2 finding 1 + 0.4 §7.3 |
| §4.5 | `pipeline_events.schema_version` stays at `Literal[1]` | §5 D-8 + 0.1 §summary 2 |
| §5 D-10 | Model tiers | User decision (supersedes 0.4 §2 placeholders) |
| §5 D-11 | `GET /admin/events` reader in Sprint 4 | 0.1 §10 + user decision |
| §5 D-12 | `system_config` reader in Sprint 2 | 0.1 §12 + user decision |
| §5 D-14 | LangSmith env vars | SA F-6 + breakdown 0.11c |

---

**End of target schema doc.** Next gate: 0.6 (informal review) → 0.12 (user approval) → Sprint 1 kickoff.
