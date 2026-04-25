# Per-Agent Design Doc — Sprint 0 Task 0.11a

**Date:** 2026-04-25
**Status:** Draft for 0.12 approval gate
**Feeds:** Sprint 1 tasks 1.A1.4 (agent factory), 1.A1.5 (schemas), 1.A1.6 (nodes), 1.A1.7 (gates), 1.C3a.2-4 (prompt registry).
**Canonical upstream:** `schema-target-2026-04-25.md` (schemas copied verbatim §§2.1-2.7), `architecture-2026-04-25.md` (topology §1, per-agent rationale §2), `tool-audit-2026-04-25.md` (roster), `source-audit-2026-04-25-sprint-0-1.md` (SA F-2/F-5/F-7/F-8/V-1/V-2).

---

## 0. Intro

### 0.1 6-agent topology recap

```
START → intake → gate1 → research_dispatch ─┬─► research_evidence   ─┐
                                            ├─► research_facts      ─┤
                                            ├─► research_witnesses  ─┤──► research_join
                                            └─► research_law        ─┘
        → gate2 → synthesis → gate3 → auditor → gate4 → END
```

Six agents = 1 intake + 4 research subagents + 1 synthesis + 1 auditor. **7 LangSmith prompts** (no orchestrator LLM — `research_dispatch` and `research_join` are plain Python nodes). Full diagram and edges: `architecture-2026-04-25.md` §1.

### 0.2 LangSmith prompt registry convention

- **Namespace:** `verdict-council/<phase>` where `<phase>` ∈ {`intake`, `research-evidence`, `research-facts`, `research-witnesses`, `research-law`, `synthesis`, `audit`}.
- **Push:** `client.push_prompt(name, object=template, description=..., tags=["v1","sprint1"])` returns the hub URL (SA V-13).
- **Pull:** `get_prompt(name) -> tuple[str, str]` wraps `client.pull_prompt(name)` and returns `(template, commit_hash)` (SA F-5).
- **Wiring into `create_agent`:** unpack at the call site — the tuple is not a valid `system_prompt`:
  ```python
  system_prompt, prompt_commit = get_prompt(f"verdict-council/{phase}")
  config = RunnableConfig(metadata={"prompt_commit": prompt_commit, "env": env})
  agent = create_agent(model=..., tools=..., system_prompt=system_prompt,
                       response_format=ToolStrategy(Schema), middleware=[...], checkpointer=saver)
  ```
  `prompt_commit` flows into every LangSmith run's metadata (SA F-5, 1.C3a.4).

### 0.3 `ToolStrategy(Schema)` decision

Per SA F-8 + `schema-target-2026-04-25.md` §5 D-4: **all 7 phases use explicit `ToolStrategy(Schema)`** from `langchain.agents.structured_output`. Rationale: `handle_errors=True` is the default in Form B (one deterministic corrective retry on `ValidationError`). Form A (`response_format=Schema`) auto-picks `ProviderStrategy` on native-structured-output models, which has different retry semantics and would break the `1.A1.SEC3` regression assertion that `extra="forbid"` raises `ValidationError`. The auditor additionally sets `strict=True` on its `model_config` (OpenAI strict-mode JSON schema) — no other phase does.

### 0.4 `HumanInTheLoopMiddleware` — informational only

Per SA F-7: the canonical middleware for **tool-call approval** is `HumanInTheLoopMiddleware(interrupt_on={...})`. Sprint 1 uses raw `interrupt({...})` + `Command(resume=...)` at node-level **inter-phase** gates only (SA V-6, V-7) — this is correct. Flag for future work: if a tool-call gate is ever added (e.g. "judge approves before `search_precedents` runs"), use `HumanInTheLoopMiddleware` — do not reinvent the pattern with raw `interrupt()` inside a tool wrapper.

### 0.5 Research subagent wrapping convention

Each research subagent's `response_format` is the **inner** model (`EvidenceResearch`, `FactsResearch`, etc.). The agent factory wraps the validated output into a `ResearchPart(scope=<name>, <field>=<inner>)` before writing `{"research_parts": {<scope>: part}}` to state (architecture §4.2). This keeps the LLM contract minimal (one flat schema) and localises the scope-discriminator to Python.

---

## 1. `verdict-council/intake`

**Purpose.** First-pass triage on a freshly submitted case. Reads raw documents + admin pre-fill, produces canonical parties / metadata / domain classification, scores complexity on 7 weighted dimensions (parties, evidence volume, legal complexity, vulnerability, time sensitivity, jurisdiction clarity, completeness), and decides route (`gate2` / `escalate` / `halt`). Separate from research because ~70% of cases halt or escalate here — spending frontier-tier tokens on every case at this stage is waste. Replaces the old `case-processing` + `complexity-routing` cascade (0.2 §3, which carried a 7-field `_COMPLEXITY_ROUTING_METADATA_FIELDS` workaround that disappears with the merge).

**Reasoning pattern.** Extract canonical fields from `parse_document` output → apply 9 hard-coded escalation rules (missing party, ambiguous jurisdiction, unverifiable identity, etc.) → if no trigger, score complexity across 7 weighted dimensions → pick route → emit structured output.

**Tools.** `[parse_document]`.

**`response_format`.** `IntakeOutput` — copied verbatim from `schema-target-2026-04-25.md` §2.3:

```python
class IntakeOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    domain: CaseDomain                                  # Literal["small_claims","traffic_violation"]
    parties: conlist(Party, min_length=0)
    case_metadata: CaseMetadata
    raw_documents: conlist(RawDocument, min_length=0)
    routing_decision: RoutingDecision
```

See §2.2 for `Party`, `CaseMetadata`, `RawDocument`, `RoutingDecision` (all `extra="forbid"`, with `RoutingDecision.complexity_score: int = Field(ge=0, le=100)` and `routing_factors[*].weight: float = Field(ge=0.0, le=1.0)`).

**Model tier.** `gpt-5-mini` (lightweight; §5 D-10).

**GraphState reads.** `case.case_id`, `case.run_id`, `case.raw_documents` (uploaded), `case.parties` (admin pre-fill), `case.case_metadata` (filed_at, jurisdiction, claim_amount, offence_code).

**GraphState writes.** `case.intake: IntakeOutput`. Single writer for `case.case_metadata` and `case.parties` (replaces 3-way writer contention — §7.4).

**Coordination protocol.** Output feeds directly into `gate1_pause`. On advance, `research_dispatch_node` reads `state["case"]["intake"]` and produces a `list[Send]` to the 4 research subagents (architecture §4.1, SA V-4).

**HITL gate 1.** Judge sees `IntakeOutput.domain`, `parties`, `case_metadata`, and the full `routing_decision` (complexity, route, routing_factors, vulnerability_assessment, escalation_reason). Decision: `advance | rerun | halt`. Rerun can attach `extra_instructions` for a second intake pass.

---

## 2. `verdict-council/research-evidence`

**Purpose.** Forensic evidence analysis: classify each evidence item on 5 dimensions (classification / strength / admissibility / probative-vs-prejudicial / claim-linkage), produce per-item credibility scores. Separate from facts/witnesses/law because admissibility judgment is evidence-specific (chain of custody, exhibit metadata) and the four scopes run in parallel under one `Send` dispatch. Drops the `cross_reference` LLM-wrapper tool (tool-audit §2) — the frontier model emits contradictions/corroborations natively.

**Reasoning pattern.** Per-item 5-dimensional assessment → cross-evidence weight synthesis → emit `evidence_items` + `credibility_scores` dict keyed by `evidence_id`.

**Tools.** `[parse_document]` (re-reads case docs independently for parallelism).

**`response_format`.** `EvidenceResearch` — copied verbatim from §2.4:

```python
class EvidenceResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    evidence_items: conlist(EvidenceItem, min_length=0)
    credibility_scores: dict[str, CredibilityScore] = Field(default_factory=dict)
```

`EvidenceItem` carries `evidence_type: EvidenceType` (Literal), `strength: EvidenceStrength` (Literal), `source_ref: Optional[SourceRef]`, `admissibility_flags: dict[str, bool]`, `linked_claims: list[str]`. Wires up the orphan model at `agent_schemas.py:55-62` (0.2 F2).

**Model tier.** `gpt-5` (frontier; §5 D-10).

**GraphState reads.** `case.raw_documents`, `case.case_metadata`, `case.intake.routing_decision` (read-only, for context on escalated vs standard triage).

**GraphState writes.** `research_parts["evidence"] = ResearchPart(scope="evidence", evidence=EvidenceResearch(...))`. The dict-keyed `merge_dict` reducer (SA F-2 option 2, state.py) overwrites on scope key collision.

**Coordination protocol.** Dispatched via `Send("research_evidence", payload)` from the router returned by `add_conditional_edges("research_dispatch", route_to_research_subagents, [...])` (SA V-4). Runs in parallel with the 3 sibling research subagents. `research_join_node` merges via `ResearchOutput.from_parts(state["research_parts"])`.

**HITL gate 2.** Gate 2 gates the **merged** `ResearchOutput`, not individual subagents — see §5 gate2 below.

---

## 3. `verdict-council/research-facts`

**Purpose.** Build the fact ledger — extract propositions, assign confidence, map agreed/disputed/contradicted status, construct the timeline. Separate from evidence because facts are propositions and evidence is proof (distinct tribunal concepts). Drops `timeline_construct` (tool-audit §3) — frontier models emit chronologically ordered `timeline` directly.

**Reasoning pattern.** Sequential fact-by-fact extraction → confidence assignment (`ConfidenceLevel`: low / med / high, §5 D-3) → dispute mapping → ISO-8601 date parsing → temporal ordering.

**Tools.** `[parse_document]`.

**`response_format`.** `FactsResearch` — copied verbatim from §2.4:

```python
class FactsResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    facts: conlist(ExtractedFactItem, min_length=0)
    timeline: conlist(TimelineEvent, min_length=0)
```

`ExtractedFactItem` carries `confidence: ConfidenceLevel` (the unified enum — replaces `confidence: str`, 0.2 F3), `status: FactStatus` (Literal), `date: Optional[date]` (ISO-8601 validated), `source_refs: list[SourceRef]`. Wires up the orphan model at `agent_schemas.py:68-74` (0.2 F2).

**Model tier.** `gpt-5` (frontier).

**GraphState reads.** `case.raw_documents`, `case.case_metadata`, `case.intake.routing_decision`.

**GraphState writes.** `research_parts["facts"] = ResearchPart(scope="facts", facts=FactsResearch(...))`.

**Coordination protocol.** Identical to research-evidence — `Send` fan-out, `merge_dict` reducer, `research_join_node` merge.

---

## 4. `verdict-council/research-witnesses`

**Purpose.** PEAR-framework witness credibility (Prior consistency / Evidence consistency / specificity / reliability) + statement extraction + contradiction flagging. Separate because witness credibility is the most legally-sensitive research workload. Drops `generate_questions` (tool-audit §4) — the agent itself is an LLM whose job is to interrogate credibility; a sibling LLM call is round-trip waste.

**Reasoning pattern.** Per-witness PEAR scoring → per-statement text extraction → cross-statement contradiction detection → emit `witnesses[*]` with nested `statements[*]` and `credibility: CredibilityScore`.

**Tools.** `[parse_document]`.

**`response_format`.** `WitnessesResearch` — copied verbatim from §2.4:

```python
class WitnessesResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    witnesses: conlist(Witness, min_length=0)
    credibility: dict[str, CredibilityScore] = Field(default_factory=dict)
```

`Witness` carries `role: Literal["eyewitness","expert","character","other"]`, nested `statements: conlist(Statement, min_length=0)`, `credibility: CredibilityScore` (rationale-bearing). Drops SAM-legacy `Witnesses.statements` peer field (0.2 F10).

**Model tier.** `gpt-5` (frontier).

**GraphState reads.** `case.raw_documents`, `case.parties`, `case.intake.routing_decision`.

**GraphState writes.** `research_parts["witnesses"] = ResearchPart(scope="witnesses", witnesses=WitnessesResearch(...))`.

**Coordination protocol.** Identical to research-evidence.

---

## 5. `verdict-council/research-law`

**Purpose.** Retrieve applicable statutes + case-law precedents + produce per-citation provenance + build the legal elements checklist + record suppressed citations (off-jurisdiction / expired / unmatched). Only research subagent that retrieves content from **outside** the case file. Tool scope is least-privilege — search tools live nowhere else in the graph (0.3 §6, §7; `search_domain_guidance` renamed to `search_legal_rules` per §5 D-6).

**Reasoning pattern.** Authority hierarchy (constitution > statute > regulation > case-law) → jurisdiction-scoped statute retrieval via `search_legal_rules` → two-tier precedent search via `search_precedents` (PAIR → vector-store fallback) → citation grounding (every citation references a `source_id` from the retrieval artifact; unmatched citations go to `suppressed_citations`) → legal elements checklist.

**Tools.** `[search_legal_rules, search_precedents]`.

**`response_format`.** `LawResearch` — copied verbatim from §2.4:

```python
class LawResearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    legal_rules: conlist(LegalRule, min_length=0)
    precedents: conlist(Precedent, min_length=0)
    precedent_source_metadata: PrecedentProvenance
    legal_elements_checklist: conlist(LegalElement, min_length=0)
    suppressed_citations: conlist(SuppressedCitation, min_length=0)
```

`PrecedentProvenance` moves the `common.py:355-357` side-channel into the schema (0.2 F4/F8) — `source: Literal["pair","vector_store","degraded"]`, `query`, `retrieved_at`, `degraded_reason`. `SuppressedCitation.reason: SuppressionReason` mirrors the migration-0025 `suppressed_citation` DDL.

**Model tier.** `gpt-5` (frontier).

**GraphState reads.** `case.case_metadata` (jurisdiction drives the search scope), `case.intake.routing_decision`, `case.intake.domain` (picks the per-domain `vector_store_id` closure — tool-audit §7).

**GraphState writes.** `research_parts["law"] = ResearchPart(scope="law", law=LawResearch(...))`. The `precedent_source_metadata` field replaces the old post-validation side-channel in `common.py`.

**Coordination protocol.** Identical to research-evidence. Note: `output_validator.py` (Sprint 3.B.5) re-reads `LawResearch.legal_rules[*].citation` and `precedents[*].citation` to enforce the `supporting_sources` → `source_id` chain post-hoc (anti-hallucination guard).

---

## 6. `verdict-council/synthesis`

**Purpose.** IRAC arguments (Issue → Rule → Application → Conclusion) for both sides, preliminary conclusion, reasoning chain, uncertainty flags. Merges the old `argument-construction` + `hearing-analysis` agents (0.2 §3 mapping) — they wrote disjoint fields but both fed the auditor and judge; sequencing them added latency without gating value. One frontier-tier call produces IRAC + conclusion + reasoning chain in a single round-trip.

**Reasoning pattern.** Draft (IRAC both sides + contested points) → critique (uncertainty_flags, counter_arguments) → emit `preliminary_conclusion` with `confidence: ConfidenceLevel` and a `reasoning_chain` of numbered steps.

**Tools.** `[search_precedents]` (occasional targeted follow-up if research missed a citation; no `parse_document` — documents have been extracted upstream).

**`response_format`.** `SynthesisOutput` — copied verbatim from §2.6:

```python
class SynthesisOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")            # flips the inherited extra="allow" (0.2 F7)
    arguments: ArgumentSet
    preliminary_conclusion: str = Field(min_length=1)
    confidence: ConfidenceLevel
    reasoning_chain: conlist(ReasoningStep, min_length=1)
    uncertainty_flags: list[UncertaintyFlag] = Field(default_factory=list)
```

`ArgumentSet` nests `claimant_position: ArgumentPosition`, `respondent_position: ArgumentPosition`, `contested_points: list[ContestedPoint]`, `counter_arguments: list[str]`. Replaces the bare `arguments: dict[str, Any]` at 0.2 §1.7. `confidence_calc` is **not** a tool here (§5 D-7 / tool-audit §5) — the synthesis node may invoke `src/utils/confidence_calc.py` directly post-LLM and overwrite the field if the user enables that path.

**Model tier.** `gpt-5` (frontier).

**GraphState reads.** `case.intake` (full `IntakeOutput`), `case.research_output` (full merged `ResearchOutput` from `research_join_node`).

**GraphState writes.** `case.synthesis: SynthesisOutput`.

**Coordination protocol.** Sequential — runs after `gate2_apply`, feeds `gate3_pause`. Output is fully downstream-consumed (auditor reads it, judge reviews it).

---

## 7. `verdict-council/audit`

**Purpose.** Independent fairness + integrity audit on the completed case. Runs last, reads everything (intake + research_output + synthesis), writes nothing but its own `AuditOutput`. Kept as a **separate agent** because structural independence is load-bearing (0.4 / §5 D-1) — the auditor must not be able to retrieve new evidence that could rationalise an unfair verdict. This is also the only agent with zero tools (architecture §2.7, tool-audit acceptance 1.A1.4 P2).

**Reasoning pattern.** Independent reviewer stance (assume no upstream agent is correct) → 5-phase audit: (1) impartiality cross-check, (2) citation verification against `LawResearch.precedent_source_metadata`, (3) completeness, (4) fairness (both-sides balance), (5) integrity (guardrails + disclaimers) → aggressive false-positive tolerance — prefer escalation to biased verdict.

**Tools.** `[]` — **zero tools**. Enforced in `PHASE_TOOLS["audit"] = []` (breakdown 1.A1.4 P2).

**`response_format`.** `AuditOutput` — copied verbatim from §2.7. Only phase with `strict=True` (OpenAI strict JSON schema; §5 D-4):

```python
class AuditOutput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    fairness_check: FairnessCheck
    status: CaseStatus
    should_rerun: bool = False
    target_phase: Optional[RerunTargetPhase] = None      # required when should_rerun is True
    reason: Optional[str] = None                         # required when should_rerun is True
```

`FairnessCheck` (already `extra="forbid"`, kept verbatim from `case_state.py:30-36`) carries `critical_issues_found`, `audit_passed`, `issues`, `recommendations`. `status: CaseStatus` is the single terminal writer of `case.status` (replaces the 3-way writer pattern — §7.4 / 0.2 finding 1).

**Model tier.** `gpt-5` with strong-reasoning settings (§5 D-10). Strict-mode JSON schema ON. Reasoning settings (e.g. `reasoning={"effort": "high"}`) flow via `model_settings` on `create_agent` / `ToolStrategy`.

**GraphState reads.** Entire `case` (intake + research_output + synthesis). Read-only.

**GraphState writes.** `case.audit: AuditOutput`. `case.status` is updated via the audit's `status` field (single terminal writer). HITL queueing states (`awaiting_review_gate*`) are written by gate apply nodes, not the auditor (§7.4).

**Coordination protocol (post-hoc rerun).** If the auditor sets `should_rerun=True`, it **must** also populate `target_phase ∈ {intake, research, synthesis}` and `reason`. The worker reads these fields after the graph terminates and calls the same `/cases/{id}/rerun?phase=<target_phase>` endpoint judges use (§5 D-9, architecture §8). The `judge_corrections` row created by this path carries `correction_source='auditor'` (migration 0025 DDL tweak). This is post-hoc rather than in-graph because the 4-gate HITL contract says every phase change passes under a human's eye — gate4 gives the judge a chance to override the auditor's `should_rerun` recommendation.

**HITL gate 4.** Judge sees `AuditOutput.fairness_check` (`critical_issues_found`, `audit_passed`, `issues[]`, `recommendations[]`), the auditor's recommended `target_phase` + `reason` (if `should_rerun=True`), and final `status`. Decision: `approve (finalize) | send-back | halt`. `send-back` invokes the same rerun endpoint; the judge can override the auditor's recommended phase.

---

## 8. HITL gate summary (4 inter-phase gates)

Gates pause via raw `interrupt({...})` (SA V-6); idempotent UPSERT of `case.status = 'awaiting_review_gateN'` happens **before** the `interrupt()` call (SA V-7). Resume via `Command(resume={...})` only.

| Gate | After phase | Judge sees | Decisions |
|---|---|---|---|
| gate1 | intake | `IntakeOutput.{domain, parties, case_metadata, routing_decision}` including complexity, route, escalation_reason | advance / rerun (+ `extra_instructions`) / halt |
| gate2 | research_join | `ResearchOutput` with 4 tabs (evidence, facts, witnesses, law) + `partial: bool` flag when a scope is missing | advance / rerun-all / rerun-scope(s) / halt |
| gate3 | synthesis | `SynthesisOutput.{arguments, preliminary_conclusion, confidence, reasoning_chain, uncertainty_flags}` | advance / rerun (+ `extra_instructions`) / halt |
| gate4 | auditor | `AuditOutput.fairness_check`, `status`, auditor's `should_rerun` + `target_phase` + `reason` recommendations | approve (finalize) / send-back-to-phase / halt |

`HumanInTheLoopMiddleware` is **not** used at any of these four gates — they are inter-phase (node-level), not tool-call-level (SA F-7). Reserved for future use.

---

## 9. Cross-reference

| This doc | Upstream source |
|---|---|
| §0.2 prompt registry convention | SA V-13, SA F-5, architecture §3 |
| §0.3 `ToolStrategy(Schema)` for all 7 phases | SA F-8, schema-target §5 D-4, architecture §6 |
| §0.4 HITL middleware note | SA F-7 |
| §0.5 `ResearchPart` wrapping | architecture §4.2 |
| §§1-7 schema blocks | schema-target §§2.3-2.7 (copied verbatim) |
| §§1-7 tool lists | tool-audit §6, architecture §5, schema-target §3 |
| §§1-7 model tiers | schema-target §5 D-10 (user decision; supersedes architecture §2 `gpt-5.4-*` placeholders) |
| §7 auditor zero-tool + strict-mode + post-hoc rerun | architecture §2.7, schema-target §5 D-1 + D-4 + D-9 |
| §8 gate semantics | architecture §1 + §8, SA V-6/V-7 |

---

**End of per-agent design doc.** Next gate: 0.12 user approval → Sprint 1 task 1.A1.5 (lift schemas into `agent_schemas.py`), 1.A1.4 (wire `PHASE_TOOLS` + `create_agent` factory), 1.A1.6 (nodes), 1.C3a.2-4 (push prompts to LangSmith).
